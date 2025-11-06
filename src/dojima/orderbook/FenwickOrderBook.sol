// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderBookTypes} from "./OrderBookTypes.sol";
import {GlobalOrderIdLibrary} from "./OrderBookTypes.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title FenwickOrderBook
/// @notice High-precision order book using Fenwick tree and bitmap for O(log n) operations
/// @dev Uses bitmap to track which price levels have orders, Fenwick tree for fast best price lookup
library FenwickOrderBook {
    using OrderBookTypes for OrderBookTypes.Book;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize order book (minimal initialization)
    /// @dev Config is now stored in TickBooks.sharedConfig
    /// @param self The order book storage
    /// @param marketPriceIndex Initial market price index
    function initialize(
        OrderBookTypes.Book storage self,
        uint256 marketPriceIndex
    ) internal {
        self.marketPriceIndex = marketPriceIndex;
        self.initialized = true;
    }

    /*//////////////////////////////////////////////////////////////
                        CORE ORDER OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a limit order at precise price
    /// @param self The order book storage
    /// @param config The price range configuration (from TickBooks.sharedConfig)
    /// @param price Exact price in 18 decimals
    /// @param amount Order amount
    /// @param isBuy True for buy order, false for sell order
    /// @param maker Address of order creator
    /// @return priceIndex The price level index
    /// @return localOrderId The local order ID within the price level
    function placeOrder(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        uint256 price,
        uint128 amount,
        bool isBuy,
        address maker
    ) internal returns (uint256 priceIndex, uint32 localOrderId) {
        if (amount == 0) revert OrderBookTypes.InvalidAmount();

        // Convert price to index
        priceIndex = priceToIndex(config, price);

        // Get storage references
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = isBuy ? self.buyOrders : self.sellOrders;

        // Create order with local ID
        localOrderId = uint32(orders[priceIndex].length);

        OrderBookTypes.Order memory order = OrderBookTypes.Order({
            maker: maker,
            orderId: localOrderId,
            reserved: 0,
            amount: amount,
            filled: 0
        });

        // Add to price level
        orders[priceIndex].push(order);

        // Mark price level as dirty (lazy bitmap update - saves ~128k gas!)
        _markDirty(self, priceIndex, isBuy);

        // Note: OrderPlaced event emitted by caller with derived global order ID
    }

    /// @notice Temporary state for market order matching
    struct MatchState {
        uint128 remaining;
        uint256 totalCost;
        uint256 ordersMatched;
        uint256 fillIndex;
        uint256[] tempOrderIds;
        uint128[] tempAmounts;
        uint256[] tempPrices;
        address[] tempMakers;
    }

    /// @notice Match a market order against the order book
    /// @param self The order book storage
    /// @param config The price range configuration (from TickBooks.sharedConfig)
    /// @param poolId The pool ID (for deriving global order IDs)
    /// @param tick The tick containing the order book (for deriving global order IDs)
    /// @param isBuy True if buying (match against sell orders), false if selling
    /// @param amountIn Amount to trade
    /// @return result Match result with details of execution
    function matchMarketOrder(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        PoolId poolId,
        int24 tick,
        bool isBuy,
        uint128 amountIn
    ) internal returns (OrderBookTypes.MatchResult memory result) {
        // Flush dirty bits before matching (update Fenwick tree with any new orders)
        // If buying, we match against sells, so flush sell side
        // If selling, we match against buys, so flush buy side
        flushDirtyBits(self, !isBuy);

        // Initialize state
        MatchState memory state = MatchState({
            remaining: amountIn,
            totalCost: 0,
            ordersMatched: 0,
            fillIndex: 0,
            tempOrderIds: new uint256[](100),
            tempAmounts: new uint128[](100),
            tempPrices: new uint256[](100),
            tempMakers: new address[](100)
        });

        // Match orders
        _matchLoop(self, config, poolId, tick, isBuy, state);

        // Build final result
        return _buildMatchResult(amountIn, state);
    }

    /// @notice Match market order with price limit
    /// @dev Only matches orders better than or equal to priceLimit
    function matchMarketOrderWithLimit(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        PoolId poolId,
        int24 tick,
        bool isBuy,
        uint128 amountIn,
        uint256 priceLimit
    ) internal returns (OrderBookTypes.MatchResult memory result) {
        // Flush dirty bits before matching
        flushDirtyBits(self, !isBuy);

        // Initialize state
        MatchState memory state = MatchState({
            remaining: amountIn,
            totalCost: 0,
            ordersMatched: 0,
            fillIndex: 0,
            tempOrderIds: new uint256[](100),
            tempAmounts: new uint128[](100),
            tempPrices: new uint256[](100),
            tempMakers: new address[](100)
        });

        // Match orders with price limit
        _matchLoopWithLimit(self, config, poolId, tick, isBuy, state, priceLimit);

        // Build final result
        return _buildMatchResult(amountIn, state);
    }

    /// @notice Main matching loop (separated to reduce stack depth)
    function _matchLoop(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        PoolId poolId,
        int24 tick,
        bool isBuy,
        MatchState memory state
    ) private {
        uint256[100] storage bitmap = isBuy ? self.sellBitmap : self.buyBitmap;
        uint256[100] storage fenwick = isBuy ? self.sellFenwick : self.buyFenwick;
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = isBuy ? self.sellOrders : self.buyOrders;

        while (state.remaining > 0) {
            // Find best price
            uint256 priceIndex = isBuy
                ? _findFirstSetBit(bitmap, 0, config.numPricePoints)
                : _findLastSetBit(bitmap, config.numPricePoints - 1);

            if (priceIndex == type(uint256).max) break;

            uint256 price = indexToPrice(config, priceIndex);

            // Fill price level
            (uint128 filled, uint256 count, FillDetail[] memory fills) = _fillPriceLevel(
                orders[priceIndex],
                poolId,
                tick,
                priceIndex,
                !isBuy, // If we're buying, we're filling sell orders (and vice versa)
                state.remaining,
                price
            );

            state.remaining -= filled;
            state.totalCost += uint256(filled) * price / 1e18;
            state.ordersMatched += count;

            // Collect fills
            for (uint256 i = 0; i < fills.length && state.fillIndex < 100; i++) {
                state.tempOrderIds[state.fillIndex] = fills[i].globalOrderId;
                state.tempAmounts[state.fillIndex] = fills[i].fillAmount;
                state.tempPrices[state.fillIndex] = price;
                state.tempMakers[state.fillIndex] = fills[i].maker;
                state.fillIndex++;
            }

            // Cleanup empty level
            if (_isPriceLevelEmpty(orders[priceIndex])) {
                _clearBit(bitmap, fenwick, priceIndex);
                emit OrderBookTypes.PriceLevelCleared(priceIndex, !isBuy);
            }
        }
    }

    /// @notice Matching loop with price limit check (separated to reduce stack depth)
    function _matchLoopWithLimit(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        PoolId poolId,
        int24 tick,
        bool isBuy,
        MatchState memory state,
        uint256 priceLimit
    ) private {
        uint256[100] storage bitmap = isBuy ? self.sellBitmap : self.buyBitmap;
        uint256[100] storage fenwick = isBuy ? self.sellFenwick : self.buyFenwick;
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = isBuy ? self.sellOrders : self.buyOrders;

        while (state.remaining > 0) {
            // Find best price
            uint256 priceIndex = isBuy
                ? _findFirstSetBit(bitmap, 0, config.numPricePoints)
                : _findLastSetBit(bitmap, config.numPricePoints - 1);

            if (priceIndex == type(uint256).max) break;

            uint256 price = indexToPrice(config, priceIndex);

            // Price limit check: stop if order price is worse than AMM price
            if (isBuy && price > priceLimit) {
                // For buys, if sell order price > AMM price, stop matching
                break;
            }
            if (!isBuy && price < priceLimit) {
                // For sells, if buy order price < AMM price, stop matching
                break;
            }

            // Fill price level
            (uint128 filled, uint256 count, FillDetail[] memory fills) = _fillPriceLevel(
                orders[priceIndex],
                poolId,
                tick,
                priceIndex,
                !isBuy,
                state.remaining,
                price
            );

            state.remaining -= filled;
            state.totalCost += uint256(filled) * price / 1e18;
            state.ordersMatched += count;

            // Collect fills
            for (uint256 i = 0; i < fills.length && state.fillIndex < 100; i++) {
                state.tempOrderIds[state.fillIndex] = fills[i].globalOrderId;
                state.tempAmounts[state.fillIndex] = fills[i].fillAmount;
                state.tempPrices[state.fillIndex] = price;
                state.tempMakers[state.fillIndex] = fills[i].maker;
                state.fillIndex++;
            }

            // Cleanup empty level
            if (_isPriceLevelEmpty(orders[priceIndex])) {
                _clearBit(bitmap, fenwick, priceIndex);
                emit OrderBookTypes.PriceLevelCleared(priceIndex, !isBuy);
            }
        }
    }

    /// @notice Build final match result from state
    function _buildMatchResult(
        uint128 amountIn,
        MatchState memory state
    ) private pure returns (OrderBookTypes.MatchResult memory) {
        // Resize arrays
        uint256[] memory filledOrderIds = new uint256[](state.fillIndex);
        uint128[] memory filledAmounts = new uint128[](state.fillIndex);
        uint256[] memory fillPrices = new uint256[](state.fillIndex);
        address[] memory makers = new address[](state.fillIndex);

        for (uint256 i = 0; i < state.fillIndex; i++) {
            filledOrderIds[i] = state.tempOrderIds[i];
            filledAmounts[i] = state.tempAmounts[i];
            fillPrices[i] = state.tempPrices[i];
            makers[i] = state.tempMakers[i];
        }

        uint128 amountFilled = amountIn - state.remaining;

        return OrderBookTypes.MatchResult({
            amountFilled: amountFilled,
            amountRemaining: state.remaining,
            totalCost: state.totalCost,
            avgPrice: amountFilled > 0 ? (state.totalCost * 1e18) / amountFilled : 0,
            ordersMatched: state.ordersMatched,
            filledOrderIds: filledOrderIds,
            filledAmounts: filledAmounts,
            fillPrices: fillPrices,
            makers: makers
        });
    }

    /// @notice Cancel an order
    /// @param self The order book storage
    /// @param priceIndex Price level index
    /// @param localOrderId Order ID within the price level
    /// @param isBuy True if buy order, false if sell order
    /// @param maker Expected maker address (for validation)
    function cancelOrder(
        OrderBookTypes.Book storage self,
        uint256 priceIndex,
        uint32 localOrderId,
        bool isBuy,
        address maker
    ) internal {
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = isBuy ? self.buyOrders : self.sellOrders;

        OrderBookTypes.Order[] storage levelOrders = orders[priceIndex];
        if (localOrderId >= levelOrders.length) revert OrderBookTypes.OrderNotFound();

        OrderBookTypes.Order storage order = levelOrders[localOrderId];
        if (order.maker != maker) revert OrderBookTypes.NotOrderMaker();
        if (order.filled >= order.amount) revert OrderBookTypes.OrderAlreadyFilled();

        uint128 amountRemaining = order.amount - order.filled;

        // Mark as fully filled to effectively cancel
        order.filled = order.amount;

        emit OrderBookTypes.OrderCancelled(
            uint256(priceIndex) << 32 | localOrderId,
            maker,
            amountRemaining
        );

        // Clean up if price level is now empty
        if (_isPriceLevelEmpty(levelOrders)) {
            uint256[100] storage bitmap = isBuy ? self.buyBitmap : self.sellBitmap;
            uint256[100] storage fenwick = isBuy ? self.buyFenwick : self.sellFenwick;
            _clearBit(bitmap, fenwick, priceIndex);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get best ask price (lowest sell order)
    /// @param self The order book storage
    /// @param config The price range configuration
    /// @return priceIndex Index of best ask, or type(uint256).max if no asks
    function getBestAsk(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config
    ) internal view returns (uint256) {
        // Search entire range for lowest sell price
        return _findFirstSetBit(
            self.sellBitmap,
            0,
            config.numPricePoints
        );
    }

    /// @notice Get best bid price (highest buy order)
    /// @param self The order book storage
    /// @param config The price range configuration
    /// @return priceIndex Index of best bid, or type(uint256).max if no bids
    function getBestBid(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config
    ) internal view returns (uint256) {
        // Search entire range for highest buy price
        if (config.numPricePoints == 0) return type(uint256).max;
        return _findLastSetBit(
            self.buyBitmap,
            config.numPricePoints - 1
        );
    }

    /// @notice Get order book depth at a price level
    /// @param self The order book storage
    /// @param priceIndex Price level index
    /// @param isBuy True for buy side, false for sell side
    /// @return totalAmount Total unfilled amount at this price
    /// @return orderCount Number of orders at this price
    function getDepthAtPrice(
        OrderBookTypes.Book storage self,
        uint256 priceIndex,
        bool isBuy
    ) internal view returns (uint128 totalAmount, uint256 orderCount) {
        OrderBookTypes.Order[] storage orders = isBuy
            ? self.buyOrders[priceIndex]
            : self.sellOrders[priceIndex];

        for (uint256 i = 0; i < orders.length; i++) {
            OrderBookTypes.Order storage order = orders[i];
            if (order.filled < order.amount) {
                totalAmount += (order.amount - order.filled);
                orderCount++;
            }
        }

        return (totalAmount, orderCount);
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert price to index
    /// @param config The price range configuration
    /// @param price Price in 18 decimals
    /// @return index Price index in bitmap
    function priceToIndex(
        OrderBookTypes.Config storage config,
        uint256 price
    ) internal view returns (uint256) {
        if (price < config.minPrice || price > config.maxPrice) {
            revert OrderBookTypes.PriceOutOfRange(price);
        }

        // Note: Price validation removed - we trust that DojimaHybridHook has already
        // rounded the price using TickMath.roundPriceToValidIncrement() with proper
        // directional rounding (buy orders round down, sell orders round up)

        return (price - config.minPrice) / config.priceIncrement;
    }

    /// @notice Convert index to price
    /// @param config The price range configuration
    /// @param index Price index in bitmap
    /// @return price Price in 18 decimals
    function indexToPrice(
        OrderBookTypes.Config storage config,
        uint256 index
    ) internal view returns (uint256) {
        return config.minPrice + (index * config.priceIncrement);
    }

    /*//////////////////////////////////////////////////////////////
                        BITMAP OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set bit in bitmap at index
    /// @dev Also updates Fenwick tree for fast queries
    function _setBit(
        uint256[100] storage bitmap,
        uint256[100] storage fenwick,
        uint256 index
    ) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;

        // Check if bit already set
        uint256 mask = uint256(1) << bitIndex;
        if ((bitmap[wordIndex] & mask) != 0) {
            return; // Already set
        }

        // Set bit
        bitmap[wordIndex] |= mask;

        // Update Fenwick tree (simple increment for now)
        fenwick[wordIndex]++;
    }

    /// @notice Mark price level as dirty (lazy bitmap update optimization)
    /// @dev Sets bitmap bit but defers Fenwick update until flush
    /// @param self The order book storage
    /// @param index Price index to mark dirty
    /// @param isBuy True for buy side, false for sell side
    function _markDirty(
        OrderBookTypes.Book storage self,
        uint256 index,
        bool isBuy
    ) private {
        // Get appropriate bitmap and dirty tracking
        uint256[100] storage bitmap = isBuy ? self.buyBitmap : self.sellBitmap;
        mapping(uint256 => bool) storage dirtyMap = isBuy ? self.buyDirty : self.sellDirty;
        uint256[] storage dirtyList = isBuy ? self.buyDirtyList : self.sellDirtyList;

        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;

        // Check if bit already set
        uint256 mask = uint256(1) << bitIndex;
        if ((bitmap[wordIndex] & mask) != 0) {
            return; // Already set, no need to mark dirty
        }

        // Set bit in bitmap (but don't update Fenwick yet)
        bitmap[wordIndex] |= mask;

        // Mark as dirty if not already dirty
        if (!dirtyMap[index]) {
            dirtyMap[index] = true;
            dirtyList.push(index);
        }
    }

    /// @notice Flush all dirty price levels by updating Fenwick tree
    /// @dev Call this before matching to ensure Fenwick is up-to-date
    /// @param self The order book storage
    /// @param isBuy True for buy side, false for sell side
    function flushDirtyBits(
        OrderBookTypes.Book storage self,
        bool isBuy
    ) internal {
        mapping(uint256 => bool) storage dirtyMap = isBuy ? self.buyDirty : self.sellDirty;
        uint256[] storage dirtyList = isBuy ? self.buyDirtyList : self.sellDirtyList;
        uint256[100] storage fenwick = isBuy ? self.buyFenwick : self.sellFenwick;

        uint256 count = dirtyList.length;
        if (count == 0) return; // No dirty bits to flush

        // Track which words we've updated to avoid double-counting
        bool[100] memory wordsUpdated;

        // Process all dirty price levels
        for (uint256 i = 0; i < count; i++) {
            uint256 index = dirtyList[i];
            uint256 wordIndex = index / 256;

            // Update Fenwick tree only once per word
            if (!wordsUpdated[wordIndex]) {
                fenwick[wordIndex]++;
                wordsUpdated[wordIndex] = true;
            }

            // Clear dirty flag
            dirtyMap[index] = false;
        }

        // Clear dirty list (reset array length to 0)
        // Note: This doesn't free storage, but resets length for next batch
        if (isBuy) {
            delete self.buyDirtyList;
        } else {
            delete self.sellDirtyList;
        }
    }

    /// @notice Clear bit in bitmap at index
    /// @dev Also updates Fenwick tree
    function _clearBit(
        uint256[100] storage bitmap,
        uint256[100] storage fenwick,
        uint256 index
    ) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;

        // Clear bit
        uint256 mask = ~(uint256(1) << bitIndex);
        bitmap[wordIndex] &= mask;

        // Update Fenwick tree
        if (fenwick[wordIndex] > 0) {
            fenwick[wordIndex]--;
        }
    }

    /// @notice Find first set bit starting from index (forward search)
    /// @param bitmap The bitmap to search
    /// @param startIndex Index to start search from
    /// @param endIndex Index to end search at
    /// @return index Index of first set bit, or type(uint256).max if not found
    function _findFirstSetBit(
        uint256[100] storage bitmap,
        uint256 startIndex,
        uint256 endIndex
    ) private view returns (uint256) {
        uint256 startWord = startIndex / 256;
        uint256 endWord = endIndex / 256;

        // Search first word (may be partial)
        uint256 firstWordMask = type(uint256).max << (startIndex % 256);
        uint256 word = bitmap[startWord] & firstWordMask;

        if (word != 0) {
            // Find lowest set bit in word
            uint256 bitIndex = _findLowestSetBit(word);
            uint256 index = startWord * 256 + bitIndex;
            if (index < endIndex) {
                return index;
            }
        }

        // Search remaining words
        for (uint256 w = startWord + 1; w <= endWord && w < OrderBookTypes.MAX_BITMAP_WORDS; w++) {
            word = bitmap[w];
            if (word != 0) {
                uint256 bitIndex = _findLowestSetBit(word);
                uint256 index = w * 256 + bitIndex;
                if (index < endIndex) {
                    return index;
                }
            }
        }

        return type(uint256).max; // Not found
    }

    /// @notice Find last set bit searching backward from index
    /// @param bitmap The bitmap to search
    /// @param startIndex Index to start search from
    /// @return index Index of last set bit, or type(uint256).max if not found
    function _findLastSetBit(
        uint256[100] storage bitmap,
        uint256 startIndex
    ) private view returns (uint256) {
        uint256 wordIndex = startIndex / 256;

        // Search first word (may be partial)
        uint256 bitIndex = startIndex % 256;

        // Handle edge case: if bitIndex == 255, we want all bits, not a shift overflow
        uint256 mask;
        if (bitIndex == 255) {
            mask = type(uint256).max; // All bits set
        } else {
            mask = (uint256(1) << (bitIndex + 1)) - 1; // Mask bits 0..bitIndex
        }

        uint256 word = bitmap[wordIndex] & mask;

        if (word != 0) {
            // Find highest set bit in word
            uint256 bit = _findHighestSetBit(word);
            return wordIndex * 256 + bit;
        }

        // Search remaining words backward
        if (wordIndex == 0) {
            return type(uint256).max; // Not found
        }

        for (uint256 w = wordIndex - 1; ; w--) {
            word = bitmap[w];
            if (word != 0) {
                uint256 bit = _findHighestSetBit(word);
                return w * 256 + bit;
            }

            if (w == 0) break; // Prevent underflow
        }

        return type(uint256).max; // Not found
    }

    /// @notice Find lowest set bit in a uint256
    /// @param x The value to search
    /// @return index Index of lowest set bit (0-255)
    function _findLowestSetBit(uint256 x) private pure returns (uint256) {
        require(x != 0, "No set bits");

        // Brian Kernighan's algorithm + De Bruijn sequence
        uint256 index = 0;

        if ((x & type(uint128).max) == 0) {
            index += 128;
            x >>= 128;
        }
        if ((x & type(uint64).max) == 0) {
            index += 64;
            x >>= 64;
        }
        if ((x & type(uint32).max) == 0) {
            index += 32;
            x >>= 32;
        }
        if ((x & type(uint16).max) == 0) {
            index += 16;
            x >>= 16;
        }
        if ((x & type(uint8).max) == 0) {
            index += 8;
            x >>= 8;
        }
        if ((x & 0xf) == 0) {
            index += 4;
            x >>= 4;
        }
        if ((x & 0x3) == 0) {
            index += 2;
            x >>= 2;
        }
        if ((x & 0x1) == 0) {
            index += 1;
        }

        return index;
    }

    /// @notice Find highest set bit in a uint256
    /// @param x The value to search
    /// @return index Index of highest set bit (0-255)
    function _findHighestSetBit(uint256 x) private pure returns (uint256) {
        require(x != 0, "No set bits");

        uint256 index = 0;

        if (x >= 2**128) {
            x >>= 128;
            index += 128;
        }
        if (x >= 2**64) {
            x >>= 64;
            index += 64;
        }
        if (x >= 2**32) {
            x >>= 32;
            index += 32;
        }
        if (x >= 2**16) {
            x >>= 16;
            index += 16;
        }
        if (x >= 2**8) {
            x >>= 8;
            index += 8;
        }
        if (x >= 2**4) {
            x >>= 4;
            index += 4;
        }
        if (x >= 2**2) {
            x >>= 2;
            index += 2;
        }
        if (x >= 2**1) {
            index += 1;
        }

        return index;
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fill orders at a specific price level
    /// @param orders Array of orders at this price
    /// @param maxAmount Maximum amount to fill
    /// @param price Price for event emission
    /// @return filled Total amount filled
    /// @notice Internal struct to track fill details within a price level
    struct FillDetail {
        uint256 globalOrderId;
        address maker;
        uint128 fillAmount;
    }

    function _fillPriceLevel(
        OrderBookTypes.Order[] storage orders,
        PoolId poolId,
        int24 tick,
        uint256 priceIndex,
        bool isBuy,
        uint128 maxAmount,
        uint256 price
    ) private returns (
        uint128 filled,
        uint256 ordersMatched,
        FillDetail[] memory fills
    ) {
        uint128 remaining = maxAmount;

        // First pass: count how many orders we'll fill (for array sizing)
        uint256 fillCount = 0;
        for (uint256 i = 0; i < orders.length && remaining > 0; i++) {
            OrderBookTypes.Order storage order = orders[i];
            if (order.filled < order.amount) {
                fillCount++;
                uint128 available = order.amount - order.filled;
                uint128 fillAmount = remaining < available ? remaining : available;
                remaining -= fillAmount;
            }
        }

        // Allocate array
        fills = new FillDetail[](fillCount);

        // Second pass: actually fill orders and collect details
        remaining = maxAmount;
        uint256 fillIndex = 0;

        for (uint256 i = 0; i < orders.length && remaining > 0; i++) {
            OrderBookTypes.Order storage order = orders[i];

            if (order.filled < order.amount) {
                uint128 available = order.amount - order.filled;
                uint128 fillAmount = remaining < available ? remaining : available;

                order.filled += fillAmount;
                filled += fillAmount;
                remaining -= fillAmount;
                ordersMatched++;

                // Derive global order ID (no storage lookup needed!)
                uint256 globalOrderId = GlobalOrderIdLibrary.encode(
                    poolId,
                    tick,
                    priceIndex,
                    uint32(i), // localOrderId is the array index
                    isBuy
                );

                // Store fill details
                fills[fillIndex] = FillDetail({
                    globalOrderId: globalOrderId,
                    maker: order.maker,
                    fillAmount: fillAmount
                });
                fillIndex++;

                emit OrderBookTypes.OrderFilled(
                    globalOrderId,
                    order.maker,
                    address(0), // Taker address not tracked in this context
                    fillAmount,
                    price
                );
            }
        }

        return (filled, ordersMatched, fills);
    }

    /// @notice Check if a price level is empty (all orders filled)
    /// @param orders Array of orders at this price
    /// @return empty True if all orders are filled
    function _isPriceLevelEmpty(
        OrderBookTypes.Order[] storage orders
    ) private view returns (bool) {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].filled < orders[i].amount) {
                return false;
            }
        }
        return true;
    }

    /// @notice Update market price index based on pool price
    /// @param self The order book storage
    /// @param config The price range configuration
    /// @param poolPrice Current pool price in 18 decimals
    function updateMarketPrice(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        uint256 poolPrice
    ) internal {
        // Clamp to min/max range
        if (poolPrice < config.minPrice) {
            poolPrice = config.minPrice;
        } else if (poolPrice > config.maxPrice) {
            poolPrice = config.maxPrice;
        }

        self.marketPriceIndex = (poolPrice - config.minPrice) / config.priceIncrement;
    }

    /// @notice Get total depth (liquidity) for a side
    /// @dev Returns approximate total of all orders on buy or sell side
    /// @param self The order book storage
    /// @param config The price range configuration
    /// @param isBuy True for buy side, false for sell side
    /// @return totalDepth Total amount available
    function getTotalDepth(
        OrderBookTypes.Book storage self,
        OrderBookTypes.Config storage config,
        bool isBuy
    ) internal view returns (uint128 totalDepth) {
        // This is an approximation - iterate through all price levels
        // In production, would maintain running totals for O(1) lookup
        uint256 numPricePoints = config.numPricePoints;

        // Get appropriate bitmap and orders mapping
        uint256[100] storage bitmap = isBuy ? self.buyBitmap : self.sellBitmap;
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = isBuy ? self.buyOrders : self.sellOrders;

        for (uint256 i = 0; i < numPricePoints; i++) {
            // Check if this price level has orders (inline bitmap check)
            uint256 wordIndex = i / 256;
            uint256 bitIndex = i % 256;
            uint256 mask = uint256(1) << bitIndex;

            if ((bitmap[wordIndex] & mask) != 0) {
                // Sum all orders at this price level
                OrderBookTypes.Order[] storage orderArray = orders[i];
                for (uint256 j = 0; j < orderArray.length; j++) {
                    OrderBookTypes.Order storage order = orderArray[j];
                    // Only count unfilled portion (guard against underflow)
                    if (order.amount > order.filled) {
                        totalDepth += order.amount - order.filled;
                    }
                }
            }
        }
    }
}
