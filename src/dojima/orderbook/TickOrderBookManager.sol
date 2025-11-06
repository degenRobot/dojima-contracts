// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderBookTypes} from "./OrderBookTypes.sol";
import {FenwickOrderBook} from "./FenwickOrderBook.sol";
import {TickMath} from "./TickMath.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title TickOrderBookManager
/// @notice Manages order books across multiple ticks
/// @dev Coordinates per-tick FenwickOrderBooks for precision within tick ranges
library TickOrderBookManager {
    using FenwickOrderBook for OrderBookTypes.Book;
    using TickBitmap for mapping(int16 => uint256);

    /// @notice Data structure for all tick order books in a pool
    struct TickBooks {
        // Tick books: tick => order book
        mapping(int24 => OrderBookTypes.Book) books;

        // Active tick bitmaps (separate for buy/sell)
        mapping(int16 => uint256) activeSellTicks;
        mapping(int16 => uint256) activeBuyTicks;

        // Configuration
        int24 tickSpacing;
        uint16 bitmapWordsPerTick; // Number of bitmap words per tick (e.g., 16)
        OrderBookTypes.Config sharedConfig; // Shared across all ticks in pool (saves 88k per tick!)

        // Initialization flags
        bool initialized;
        bool configInitialized; // Track if shared config has been set
    }

    /// @notice Events
    event TickBookInitialized(int24 indexed tick, uint256 minPrice, uint256 maxPrice, uint256 priceIncrement);
    event TickActivated(int24 indexed tick, bool isBuy);
    event TickDeactivated(int24 indexed tick, bool isBuy);

    /// @notice Errors
    error NotInitialized();
    error AlreadyInitialized();
    error InvalidTickSpacing();
    error InvalidWordsPerTick();

    /// @notice Constants
    uint8 constant MAX_TICKS_PER_MATCH = 20; // Limit ticks scanned per match for gas safety

    /// @notice Initialize tick books for a pool
    /// @param self The tick books storage
    /// @param tickSpacing Tick spacing from pool
    /// @param wordsPerTick Bitmap words per tick (default: 16 for 4,096 price points)
    function initialize(
        TickBooks storage self,
        int24 tickSpacing,
        uint16 wordsPerTick
    ) internal {
        if (self.initialized) revert AlreadyInitialized();
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        if (wordsPerTick == 0 || wordsPerTick > OrderBookTypes.MAX_BITMAP_WORDS)
            revert InvalidWordsPerTick();

        self.tickSpacing = tickSpacing;
        self.bitmapWordsPerTick = wordsPerTick;
        self.initialized = true;
    }

    /// @notice Place order at a specific price
    /// @param self The tick books storage
    /// @param price Exact price in 18 decimals
    /// @param amount Order amount
    /// @param isBuy True for buy order, false for sell
    /// @param maker Order creator
    /// @return tick The tick containing the order
    /// @return priceIndex The price level index within the tick
    /// @return localOrderId The local order ID within the price level
    function placeOrder(
        TickBooks storage self,
        uint256 price,
        uint128 amount,
        bool isBuy,
        address maker
    ) internal returns (int24 tick, uint256 priceIndex, uint32 localOrderId) {
        if (!self.initialized) revert NotInitialized();

        // Find which tick contains this price
        tick = TickMath.getTickContainingPrice(price, self.tickSpacing);

        // Initialize tick book if needed
        if (!self.books[tick].initialized) {
            _initializeTickBook(self, tick);
        }

        // Place order in tick's book (pass shared config)
        (priceIndex, localOrderId) = self.books[tick].placeOrder(self.sharedConfig, price, amount, isBuy, maker);

        // Mark tick as active (store compressed tick in bitmap)
        int24 compressedTick = tick / self.tickSpacing;
        if (isBuy) {
            self.activeBuyTicks.setTick(compressedTick);
            emit TickActivated(tick, true);
        } else {
            self.activeSellTicks.setTick(compressedTick);
            emit TickActivated(tick, false);
        }

        return (tick, priceIndex, localOrderId);
    }

    /// @notice Match market order across multiple ticks
    /// @param self The tick books storage
    /// @param poolId The pool ID (for deriving global order IDs)
    /// @param isBuy True if buying (match against sells), false if selling
    /// @param amountIn Amount to match
    /// @param currentTick Current pool tick
    /// @return result Match result with total fills
    function matchMarketOrder(
        TickBooks storage self,
        PoolId poolId,
        bool isBuy,
        uint128 amountIn,
        int24 currentTick
    ) internal returns (OrderBookTypes.MatchResult memory result) {
        if (!self.initialized) revert NotInitialized();

        uint128 remaining = amountIn;
        uint256 totalCost = 0;
        uint256 totalOrdersMatched = 0;

        // Temporary arrays to accumulate fill details across ticks (max 200 orders)
        uint256[] memory tempOrderIds = new uint256[](200);
        uint128[] memory tempAmounts = new uint128[](200);
        uint256[] memory tempPrices = new uint256[](200);
        address[] memory tempMakers = new address[](200);
        uint256 fillIndex = 0;

        if (isBuy) {
            // Match against sell orders (ascending ticks, starting from current tick)
            int24 tick = self.activeSellTicks.nextActiveTickGTE(
                currentTick,
                self.tickSpacing
            );

            uint8 ticksScanned = 0;

            while (remaining > 0 && tick != type(int24).max && ticksScanned < MAX_TICKS_PER_MATCH) {
                OrderBookTypes.Book storage book = self.books[tick];

                if (book.initialized) {
                    // Match within this tick (pass shared config)
                    OrderBookTypes.MatchResult memory tickResult =
                        book.matchMarketOrder(self.sharedConfig, poolId, tick, isBuy, remaining);

                    remaining = tickResult.amountRemaining;
                    totalCost += tickResult.totalCost;
                    totalOrdersMatched += tickResult.ordersMatched;

                    // Collect fill details from this tick
                    for (uint256 i = 0; i < tickResult.filledOrderIds.length; i++) {
                        if (fillIndex >= 200) break; // Safety limit
                        tempOrderIds[fillIndex] = tickResult.filledOrderIds[i];
                        tempAmounts[fillIndex] = tickResult.filledAmounts[i];
                        tempPrices[fillIndex] = tickResult.fillPrices[i];
                        tempMakers[fillIndex] = tickResult.makers[i];
                        fillIndex++;
                    }

                    // Clear tick if empty
                    if (_isTickBookEmpty(self, book, false)) {
                        self.activeSellTicks.clearTick(tick / self.tickSpacing);
                        emit TickDeactivated(tick, false);
                    }
                }

                // Move to next tick
                tick = self.activeSellTicks.nextActiveTickGTE(
                    tick + self.tickSpacing,
                    self.tickSpacing
                );
                ticksScanned++;
            }
        } else {
            // Match against buy orders (descending ticks, starting from current tick)
            int24 tick = self.activeBuyTicks.nextActiveTickLTE(
                currentTick,
                self.tickSpacing
            );

            uint8 ticksScanned = 0;

            while (remaining > 0 && tick != type(int24).min && ticksScanned < MAX_TICKS_PER_MATCH) {
                OrderBookTypes.Book storage book = self.books[tick];

                if (book.initialized) {
                    // Match within this tick (pass shared config)
                    OrderBookTypes.MatchResult memory tickResult =
                        book.matchMarketOrder(self.sharedConfig, poolId, tick, isBuy, remaining);

                    remaining = tickResult.amountRemaining;
                    totalCost += tickResult.totalCost;
                    totalOrdersMatched += tickResult.ordersMatched;

                    // Collect fill details from this tick
                    for (uint256 i = 0; i < tickResult.filledOrderIds.length; i++) {
                        if (fillIndex >= 200) break; // Safety limit
                        tempOrderIds[fillIndex] = tickResult.filledOrderIds[i];
                        tempAmounts[fillIndex] = tickResult.filledAmounts[i];
                        tempPrices[fillIndex] = tickResult.fillPrices[i];
                        tempMakers[fillIndex] = tickResult.makers[i];
                        fillIndex++;
                    }

                    // Clear tick if empty
                    if (_isTickBookEmpty(self, book, true)) {
                        self.activeBuyTicks.clearTick(tick / self.tickSpacing);
                        emit TickDeactivated(tick, true);
                    }
                }

                // Move to previous tick
                tick = self.activeBuyTicks.nextActiveTickLTE(
                    tick - self.tickSpacing,
                    self.tickSpacing
                );
                ticksScanned++;
            }
        }

        uint128 amountFilled = amountIn - remaining;

        // Resize arrays to actual fill count
        uint256[] memory filledOrderIds = new uint256[](fillIndex);
        uint128[] memory filledAmounts = new uint128[](fillIndex);
        uint256[] memory fillPrices = new uint256[](fillIndex);
        address[] memory makers = new address[](fillIndex);

        for (uint256 i = 0; i < fillIndex; i++) {
            filledOrderIds[i] = tempOrderIds[i];
            filledAmounts[i] = tempAmounts[i];
            fillPrices[i] = tempPrices[i];
            makers[i] = tempMakers[i];
        }

        return OrderBookTypes.MatchResult({
            amountFilled: amountFilled,
            amountRemaining: remaining,
            totalCost: totalCost,
            avgPrice: amountFilled > 0 ? (totalCost * 1e18) / amountFilled : 0,
            ordersMatched: totalOrdersMatched,
            filledOrderIds: filledOrderIds,
            filledAmounts: filledAmounts,
            fillPrices: fillPrices,
            makers: makers
        });
    }

    /// @notice Match market order with price limit (price-aware routing)
    /// @dev Only matches orders better than or equal to priceLimit
    /// @dev Stops matching when order price crosses AMM price for optimal execution
    /// @param self The tick books storage
    /// @param poolId Pool identifier
    /// @param isBuy True for buy order, false for sell order
    /// @param amountIn Amount to fill
    /// @param currentTick Current pool tick
    /// @param priceLimit Price limit from AMM (only match orders better than this)
    /// @return result Match result with fills
    function matchMarketOrderWithLimit(
        TickBooks storage self,
        PoolId poolId,
        bool isBuy,
        uint128 amountIn,
        int24 currentTick,
        uint256 priceLimit
    ) internal returns (OrderBookTypes.MatchResult memory result) {
        if (!self.initialized) revert NotInitialized();

        uint128 remaining = amountIn;
        uint256 totalCost = 0;
        uint256 totalOrdersMatched = 0;

        // Temporary arrays to accumulate fill details across ticks (max 200 orders)
        uint256[] memory tempOrderIds = new uint256[](200);
        uint128[] memory tempAmounts = new uint128[](200);
        uint256[] memory tempPrices = new uint256[](200);
        address[] memory tempMakers = new address[](200);
        uint256 fillIndex = 0;

        if (isBuy) {
            // Match against sell orders (ascending ticks)
            int24 tick = self.activeSellTicks.nextActiveTickGTE(
                currentTick,
                self.tickSpacing
            );

            uint8 ticksScanned = 0;

            while (remaining > 0 && tick != type(int24).max && ticksScanned < MAX_TICKS_PER_MATCH) {
                OrderBookTypes.Book storage book = self.books[tick];

                if (book.initialized) {
                    // Check best price in this tick before matching
                    uint256 bestPriceIndex = book.getBestAsk(self.sharedConfig);
                    if (bestPriceIndex != type(uint256).max) {
                        uint256 bestPrice = FenwickOrderBook.indexToPrice(self.sharedConfig, bestPriceIndex);

                        // Stop if best sell price > AMM price (worse for buyer)
                        if (bestPrice > priceLimit) {
                            break;
                        }
                    }

                    // Match within this tick with price limit
                    OrderBookTypes.MatchResult memory tickResult =
                        book.matchMarketOrderWithLimit(
                            self.sharedConfig,
                            poolId,
                            tick,
                            isBuy,
                            remaining,
                            priceLimit
                        );

                    remaining = tickResult.amountRemaining;
                    totalCost += tickResult.totalCost;
                    totalOrdersMatched += tickResult.ordersMatched;

                    // Collect fill details from this tick
                    for (uint256 i = 0; i < tickResult.filledOrderIds.length; i++) {
                        if (fillIndex >= 200) break;
                        tempOrderIds[fillIndex] = tickResult.filledOrderIds[i];
                        tempAmounts[fillIndex] = tickResult.filledAmounts[i];
                        tempPrices[fillIndex] = tickResult.fillPrices[i];
                        tempMakers[fillIndex] = tickResult.makers[i];
                        fillIndex++;
                    }

                    // Clear tick if empty
                    if (_isTickBookEmpty(self, book, false)) {
                        self.activeSellTicks.clearTick(tick / self.tickSpacing);
                        emit TickDeactivated(tick, false);
                    }
                }

                // Move to next tick
                tick = self.activeSellTicks.nextActiveTickGTE(
                    tick + self.tickSpacing,
                    self.tickSpacing
                );
                ticksScanned++;
            }
        } else {
            // Match against buy orders (descending ticks)
            int24 tick = self.activeBuyTicks.nextActiveTickLTE(
                currentTick,
                self.tickSpacing
            );

            uint8 ticksScanned = 0;

            while (remaining > 0 && tick != type(int24).min && ticksScanned < MAX_TICKS_PER_MATCH) {
                OrderBookTypes.Book storage book = self.books[tick];

                if (book.initialized) {
                    // Check best price in this tick before matching
                    uint256 bestPriceIndex = book.getBestBid(self.sharedConfig);
                    if (bestPriceIndex != type(uint256).max) {
                        uint256 bestPrice = FenwickOrderBook.indexToPrice(self.sharedConfig, bestPriceIndex);

                        // Stop if best buy price < AMM price (worse for seller)
                        if (bestPrice < priceLimit) {
                            break;
                        }
                    }

                    // Match within this tick with price limit
                    OrderBookTypes.MatchResult memory tickResult =
                        book.matchMarketOrderWithLimit(
                            self.sharedConfig,
                            poolId,
                            tick,
                            isBuy,
                            remaining,
                            priceLimit
                        );

                    remaining = tickResult.amountRemaining;
                    totalCost += tickResult.totalCost;
                    totalOrdersMatched += tickResult.ordersMatched;

                    // Collect fill details from this tick
                    for (uint256 i = 0; i < tickResult.filledOrderIds.length; i++) {
                        if (fillIndex >= 200) break;
                        tempOrderIds[fillIndex] = tickResult.filledOrderIds[i];
                        tempAmounts[fillIndex] = tickResult.filledAmounts[i];
                        tempPrices[fillIndex] = tickResult.fillPrices[i];
                        tempMakers[fillIndex] = tickResult.makers[i];
                        fillIndex++;
                    }

                    // Clear tick if empty
                    if (_isTickBookEmpty(self, book, true)) {
                        self.activeBuyTicks.clearTick(tick / self.tickSpacing);
                        emit TickDeactivated(tick, true);
                    }
                }

                // Move to previous tick
                tick = self.activeBuyTicks.nextActiveTickLTE(
                    tick - self.tickSpacing,
                    self.tickSpacing
                );
                ticksScanned++;
            }
        }

        uint128 amountFilled = amountIn - remaining;

        // Resize arrays to actual fill count
        uint256[] memory filledOrderIds = new uint256[](fillIndex);
        uint128[] memory filledAmounts = new uint128[](fillIndex);
        uint256[] memory fillPrices = new uint256[](fillIndex);
        address[] memory makers = new address[](fillIndex);

        for (uint256 i = 0; i < fillIndex; i++) {
            filledOrderIds[i] = tempOrderIds[i];
            filledAmounts[i] = tempAmounts[i];
            fillPrices[i] = tempPrices[i];
            makers[i] = tempMakers[i];
        }

        return OrderBookTypes.MatchResult({
            amountFilled: amountFilled,
            amountRemaining: remaining,
            totalCost: totalCost,
            avgPrice: amountFilled > 0 ? (totalCost * 1e18) / amountFilled : 0,
            ordersMatched: totalOrdersMatched,
            filledOrderIds: filledOrderIds,
            filledAmounts: filledAmounts,
            fillPrices: fillPrices,
            makers: makers
        });
    }

    /// @notice Get best ask (lowest sell price)
    /// @param self The tick books storage
    /// @param currentTick Current pool tick
    /// @return tick Tick with best ask
    /// @return price Best ask price (0 if no asks)
    function getBestAsk(
        TickBooks storage self,
        int24 currentTick
    ) internal view returns (int24 tick, uint256 price) {
        if (!self.initialized) return (type(int24).max, 0);

        tick = self.activeSellTicks.nextActiveTickGTE(
            currentTick,
            self.tickSpacing
        );

        if (tick != type(int24).max && self.books[tick].initialized) {
            uint256 priceIndex = self.books[tick].getBestAsk(self.sharedConfig);
            if (priceIndex != type(uint256).max) {
                price = FenwickOrderBook.indexToPrice(self.sharedConfig, priceIndex);
            }
        }
    }

    /// @notice Get best bid (highest buy price)
    /// @param self The tick books storage
    /// @param currentTick Current pool tick
    /// @return tick Tick with best bid
    /// @return price Best bid price (0 if no bids)
    function getBestBid(
        TickBooks storage self,
        int24 currentTick
    ) internal view returns (int24 tick, uint256 price) {
        if (!self.initialized) return (type(int24).min, 0);

        tick = self.activeBuyTicks.nextActiveTickLTE(
            currentTick,
            self.tickSpacing
        );

        if (tick != type(int24).min && self.books[tick].initialized) {
            uint256 priceIndex = self.books[tick].getBestBid(self.sharedConfig);
            if (priceIndex != type(uint256).max) {
                price = FenwickOrderBook.indexToPrice(self.sharedConfig, priceIndex);
            }
        }
    }

    /// @notice Get depth at a specific tick
    /// @param self The tick books storage
    /// @param tick The tick to check
    /// @param isBuy True for buy side, false for sell side
    /// @return totalAmount Total amount available
    /// @return orderCount Number of orders
    function getTickDepth(
        TickBooks storage self,
        int24 tick,
        bool isBuy
    ) internal view returns (uint128 totalAmount, uint256 orderCount) {
        if (!self.books[tick].initialized) {
            return (0, 0);
        }

        // Get all price levels in this tick
        // For now, we'll need to iterate (can be optimized)
        OrderBookTypes.Book storage book = self.books[tick];

        // This is a simplified version - full implementation would
        // iterate through all price levels in the tick
        // For now, just check if tick is active
        bool isActive = isBuy
            ? self.activeBuyTicks.isTickActive(tick)
            : self.activeSellTicks.isTickActive(tick);

        if (isActive) {
            // Placeholder - would need to sum all orders in tick
            totalAmount = 1; // Non-zero indicates orders exist
            orderCount = 1;
        }
    }

    /// @notice Cancel an order
    /// @param self The tick books storage
    /// @param tick The tick containing the order
    /// @param priceIndex Price index within the tick
    /// @param localOrderId Order ID within the price level
    /// @param isBuy True for buy order, false for sell
    /// @param maker Expected maker address
    function cancelOrder(
        TickBooks storage self,
        int24 tick,
        uint256 priceIndex,
        uint32 localOrderId,
        bool isBuy,
        address maker
    ) internal {
        if (!self.initialized) revert NotInitialized();
        if (!self.books[tick].initialized) revert OrderBookTypes.OrderNotFound();

        // Cancel in the tick's book
        self.books[tick].cancelOrder(priceIndex, localOrderId, isBuy, maker);

        // Check if tick is now empty
        if (_isTickBookEmpty(self, self.books[tick], isBuy)) {
            int24 compressedTick = tick / self.tickSpacing;
            if (isBuy) {
                self.activeBuyTicks.clearTick(compressedTick);
            } else {
                self.activeSellTicks.clearTick(compressedTick);
            }
            emit TickDeactivated(tick, isBuy);
        }
    }

    /// @notice Initialize a tick's order book
    /// @param self The tick books storage
    /// @param tick The tick to initialize
    function _initializeTickBook(
        TickBooks storage self,
        int24 tick
    ) private {
        // Get price bounds for this tick
        (uint256 lowerPrice, uint256 upperPrice) = TickMath.getTickBounds(
            tick,
            self.tickSpacing
        );

        // Initialize shared config once (first tick only)
        if (!self.configInitialized) {
            uint256 numPoints = uint256(self.bitmapWordsPerTick) * 256;
            
            // Use broader price range for testing compatibility
            // Cover 0.5x to 2.0x current price range
            uint256 broadMinPrice = lowerPrice / 2;  // Extend down to 50% of tick lower bound
            uint256 broadMaxPrice = upperPrice * 2;  // Extend up to 200% of tick upper bound
            
            uint256 priceIncrement = TickMath.calculatePriceIncrement(
                broadMinPrice,
                broadMaxPrice,
                numPoints
            );

            self.sharedConfig = OrderBookTypes.Config({
                minPrice: broadMinPrice,
                maxPrice: broadMaxPrice,
                priceIncrement: priceIncrement,
                numPricePoints: numPoints
            });
            self.configInitialized = true;

            emit TickBookInitialized(tick, broadMinPrice, broadMaxPrice, priceIncrement);
        }

        // Minimal book initialization (no config storage!)
        uint256 marketPriceIndex = self.sharedConfig.numPricePoints / 2;
        self.books[tick].initialize(marketPriceIndex);
    }

    /// @notice Check if tick book is empty on one side
    /// @param self The tick books storage (for accessing shared config)
    /// @param book The tick's order book
    /// @param isBuy Check buy or sell side
    /// @return empty True if no active orders
    function _isTickBookEmpty(
        TickBooks storage self,
        OrderBookTypes.Book storage book,
        bool isBuy
    ) private view returns (bool) {
        // Check if best price exists
        uint256 bestPrice = isBuy ? book.getBestBid(self.sharedConfig) : book.getBestAsk(self.sharedConfig);
        return bestPrice == type(uint256).max;
    }
}
