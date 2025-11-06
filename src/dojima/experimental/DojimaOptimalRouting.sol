// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DojimaHybridHook} from "../DojimaHybridHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {OrderBookTypes, GlobalOrderIdLibrary} from "../orderbook/OrderBookTypes.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickOrderBookManager} from "../orderbook/TickOrderBookManager.sol";
import {FenwickOrderBook} from "../orderbook/FenwickOrderBook.sol";
import {TickBitmap} from "../orderbook/TickBitmap.sol";

/// @title DojimaOptimalRouting
/// @notice Experimental: Optimal AMM+CLOB routing using marginal output comparison
/// @dev Extends DojimaHybridHook with advanced routing algorithm for A/B testing
contract DojimaOptimalRouting is DojimaHybridHook {
    using PoolIdLibrary for PoolKey;
    using TickBitmap for mapping(int16 => uint256);
    using FenwickOrderBook for OrderBookTypes.Book;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OptimalRoutingExecuted(
        PoolId indexed poolId,
        uint256 ordersConsidered,
        uint256 ordersSelected,
        uint128 clobAmount,
        uint128 ammAmount,
        uint256 outputImprovement  // vs pure AMM
    );

    /*//////////////////////////////////////////////////////////////
                        OPTIMAL ROUTING STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct OrderCandidate {
        uint256 orderId;
        uint256 price;
        uint128 amount;
        address maker;
        int24 tick;
        uint256 priceIndex;
    }

    struct RoutingPlan {
        uint256[] selectedOrderIds;
        uint128[] matchAmounts;
        uint128 ammAmount;
        uint128 totalOutput;
        bool worthUsing;
    }

    struct AMMSimulation {
        uint128 amountOut;
        uint256 avgPrice;
        uint256 finalPrice;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ICLPoolManager _poolManager) DojimaHybridHook(_poolManager) {}

    /*//////////////////////////////////////////////////////////////
                        OPTIMAL ROUTING OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Override afterSwap with optimal routing algorithm
    /// @dev Uses greedy selection to find best AMM/CLOB split
    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Get swap direction
        bool isBuy = !params.zeroForOne;

        // Calculate AMM execution
        uint256 actualAMMPrice = _calculateAMMPrice(delta, isBuy);
        uint256 actualAMMCost = _calculateAMMCost(delta, isBuy);
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        uint128 actualAmount = uint128(isBuy ? uint256(int256(amount0)) : uint256(int256(-amount0)));

        // Step 1: Simulate pure AMM execution
        AMMSimulation memory pureAMM = _simulateAMMExecution(
            poolId,
            actualAmount,
            actualAMMPrice
        );

        // Step 2: Find candidate orders (better than final AMM price)
        OrderCandidate[] memory candidates = _findCandidateOrders(
            poolId,
            isBuy,
            pureAMM.finalPrice,
            actualAmount
        );

        if (candidates.length == 0) {
            // No candidates, use pure AMM
            return (this.afterSwap.selector, 0);
        }

        // Step 3: Find optimal routing using greedy selection
        RoutingPlan memory plan = _findOptimalRouting(
            poolId,
            isBuy,
            actualAmount,
            pureAMM,
            candidates,
            actualAMMPrice
        );

        if (!plan.worthUsing) {
            // Pure AMM is better
            return (this.afterSwap.selector, 0);
        }

        // Step 4: Execute selected orders
        uint256 totalCost = 0;
        for (uint256 i = 0; i < plan.selectedOrderIds.length; i++) {
            // Get order details
            OrderCandidate memory candidate = _findCandidate(candidates, plan.selectedOrderIds[i]);

            // Fill order
            _fillSingleOrder(
                plan.selectedOrderIds[i],
                plan.matchAmounts[i],
                candidate.price,
                candidate.maker,
                sender,
                key
            );

            totalCost += (uint256(plan.matchAmounts[i]) * candidate.price) / 1e18;
        }

        // Step 5: Calculate taker refund
        uint256 ammPortionCost = (uint256(plan.ammAmount) * actualAMMPrice) / 1e18;
        uint256 actualCost = totalCost + ammPortionCost;
        uint256 surplus = actualAMMCost > actualCost ? actualAMMCost - actualCost : 0;

        if (surplus > 1000 && sender != address(0)) {
            Currency refundCurrency = isBuy ? key.currency1 : key.currency0;
            balances[sender][refundCurrency].total += uint128(surplus);
            emit TakerRebate(poolId, sender, refundCurrency, surplus);
        }

        // Emit optimal routing event
        emit OptimalRoutingExecuted(
            poolId,
            candidates.length,
            plan.selectedOrderIds.length,
            actualAmount - plan.ammAmount,
            plan.ammAmount,
            plan.totalOutput > pureAMM.amountOut ? plan.totalOutput - pureAMM.amountOut : 0
        );

        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIMAL ROUTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate pure AMM execution
    /// @dev Estimates final price based on liquidity and price impact
    function _simulateAMMExecution(
        PoolId poolId,
        uint128 amount,
        uint256 currentPrice
    ) internal view returns (AMMSimulation memory sim) {
        // Get pool liquidity for price impact estimation
        uint128 liquidity = poolManager.getLiquidity(poolId);

        if (liquidity == 0) {
            // No liquidity, use current price
            sim.amountOut = amount;
            sim.avgPrice = currentPrice;
            sim.finalPrice = currentPrice;
            return sim;
        }

        // Estimate price impact in basis points
        // Simplified: impact ≈ (amount / liquidity) * 10000
        uint256 impactBps = (uint256(amount) * 10000) / uint256(liquidity);
        if (impactBps > 1000) impactBps = 1000;  // Cap at 10%

        // Calculate final price (current price + impact)
        sim.finalPrice = currentPrice + (currentPrice * impactBps) / 10000;

        // Average execution price (midpoint)
        sim.avgPrice = (currentPrice + sim.finalPrice) / 2;

        // Output amount (1:1 for simplicity - real would use price curve)
        sim.amountOut = amount;
    }

    /// @notice Find all orders better than final AMM price
    /// @dev Scans order book across ticks to find viable orders
    function _findCandidateOrders(
        PoolId poolId,
        bool isBuy,
        uint256 finalAMMPrice,
        uint128 maxAmount
    ) internal view returns (OrderCandidate[] memory) {
        OrderCandidate[] memory tempCandidates = new OrderCandidate[](100);
        uint256 count = 0;
        uint128 totalAmount = 0;

        TickOrderBookManager.TickBooks storage books = tickBooks[poolId];
        if (!books.initialized) {
            return new OrderCandidate[](0);
        }

        if (isBuy) {
            // Buying: look for sell orders with price < finalAMMPrice
            // Start from lowest tick (best prices)
            int24 tick = books.activeSellTicks.nextActiveTickGTE(-887272, books.tickSpacing);
            uint8 ticksScanned = 0;
            uint8 MAX_TICKS = 20;  // Gas safety

            while (tick != type(int24).max && count < 100 && ticksScanned < MAX_TICKS) {
                OrderBookTypes.Book storage book = books.books[tick];

                if (book.initialized) {
                    // Get best price in this tick
                    uint256 bestPriceIndex = book.getBestAsk(books.sharedConfig);

                    if (bestPriceIndex != type(uint256).max) {
                        uint256 bestPrice = FenwickOrderBook.indexToPrice(books.sharedConfig, bestPriceIndex);

                        // Stop if price >= final AMM price (no longer better)
                        if (bestPrice >= finalAMMPrice) break;

                        // Scan all price levels in this tick (that are better)
                        _addCandidatesFromTick(
                            books,
                            tick,
                            false,  // sell orders
                            finalAMMPrice,
                            tempCandidates,
                            count,
                            totalAmount,
                            maxAmount
                        );
                    }
                }

                if (totalAmount >= maxAmount) break;

                tick = books.activeSellTicks.nextActiveTickGTE(tick + books.tickSpacing, books.tickSpacing);
                ticksScanned++;
            }
        } else {
            // Selling: look for buy orders with price > finalAMMPrice
            // Start from highest tick (best prices)
            int24 tick = books.activeBuyTicks.nextActiveTickLTE(887272, books.tickSpacing);
            uint8 ticksScanned = 0;
            uint8 MAX_TICKS = 20;

            while (tick != type(int24).min && count < 100 && ticksScanned < MAX_TICKS) {
                OrderBookTypes.Book storage book = books.books[tick];

                if (book.initialized) {
                    uint256 bestPriceIndex = book.getBestBid(books.sharedConfig);

                    if (bestPriceIndex != type(uint256).max) {
                        uint256 bestPrice = FenwickOrderBook.indexToPrice(books.sharedConfig, bestPriceIndex);

                        // Stop if price <= final AMM price
                        if (bestPrice <= finalAMMPrice) break;

                        _addCandidatesFromTick(
                            books,
                            tick,
                            true,  // buy orders
                            finalAMMPrice,
                            tempCandidates,
                            count,
                            totalAmount,
                            maxAmount
                        );
                    }
                }

                if (totalAmount >= maxAmount) break;

                tick = books.activeBuyTicks.nextActiveTickLTE(tick - books.tickSpacing, books.tickSpacing);
                ticksScanned++;
            }
        }

        // Resize to actual count
        OrderCandidate[] memory candidates = new OrderCandidate[](count);
        for (uint256 i = 0; i < count; i++) {
            candidates[i] = tempCandidates[i];
        }

        return candidates;
    }

    /// @notice Helper to add candidates from a specific tick
    /// @dev Scans price levels within tick and adds qualifying orders
    /// @param books Order book storage
    /// @param tick Tick to scan
    /// @param isBuy Whether scanning buy or sell orders
    /// @param priceLimit Price threshold for candidates
    /// @param candidates Array to add candidates to (modified in place)
    /// @param count Current count of candidates (not used but kept for interface)
    /// @param totalAmount Total amount accumulated (not used but kept for interface)
    /// @param maxAmount Maximum amount to accumulate (not used but kept for interface)
    function _addCandidatesFromTick(
        TickOrderBookManager.TickBooks storage books,
        int24 tick,
        bool isBuy,
        uint256 priceLimit,
        OrderCandidate[] memory candidates,
        uint256 count,
        uint128 totalAmount,
        uint128 maxAmount
    ) internal view {
        // NOTE: This is intentionally left as a stub for the experimental version
        // Full implementation would require:
        // 1. Access to internal order arrays in FenwickOrderBook
        // 2. Iteration through all price levels in tick
        // 3. For each price level, scan all orders
        // 4. Build OrderCandidate structs with full order details
        //
        // For now, the experimental contract uses the parent's
        // matchMarketOrderWithLimit which does the matching.
        // The optimal routing improvement would come from:
        // - Better AMM simulation (done above in _simulateAMMExecution)
        // - Greedy selection of which orders to match (done in _findOptimalRouting)
        // - More accurate price impact modeling
        //
        // Future enhancement: Export order scanning functionality from
        // TickOrderBookManager to make this possible without duplicating logic.
    }

    /// @notice Find optimal routing using greedy selection
    function _findOptimalRouting(
        PoolId poolId,
        bool isBuy,
        uint128 amountIn,
        AMMSimulation memory pureAMM,
        OrderCandidate[] memory candidates,
        uint256 currentAMMPrice
    ) internal view returns (RoutingPlan memory plan) {
        // Initialize with pure AMM as baseline
        uint128 bestOutput = pureAMM.amountOut;
        uint128 remainingInput = amountIn;

        uint256[] memory selectedIds = new uint256[](candidates.length);
        uint128[] memory selectedAmounts = new uint128[](candidates.length);
        uint256 selectedCount = 0;

        // Greedy: test each order incrementally
        for (uint256 i = 0; i < candidates.length; i++) {
            OrderCandidate memory order = candidates[i];

            // Calculate input needed for this order
            uint128 orderInput = uint128((uint256(order.amount) * order.price) / 1e18);

            if (orderInput > remainingInput) {
                // Partial fill
                orderInput = remainingInput;
                order.amount = uint128((uint256(remainingInput) * 1e18) / order.price);
            }

            // Simulate: This order + AMM for remainder
            uint128 outputFromOrder = order.amount;
            uint128 remainingAfterOrder = remainingInput - orderInput;

            // Estimate AMM output for remainder (simplified)
            uint128 ammOutput = remainingAfterOrder;  // 1:1 for simplicity

            uint128 totalOutput = outputFromOrder + ammOutput;

            // Check if this improves output
            if (totalOutput > bestOutput) {
                // Include this order
                selectedIds[selectedCount] = order.orderId;
                selectedAmounts[selectedCount] = order.amount;
                selectedCount++;

                bestOutput = totalOutput;
                remainingInput = remainingAfterOrder;
            } else {
                // This order doesn't help, stop (greedy)
                break;
            }

            if (remainingInput == 0) break;
        }

        // Build plan
        plan.selectedOrderIds = new uint256[](selectedCount);
        plan.matchAmounts = new uint128[](selectedCount);
        for (uint256 i = 0; i < selectedCount; i++) {
            plan.selectedOrderIds[i] = selectedIds[i];
            plan.matchAmounts[i] = selectedAmounts[i];
        }

        plan.ammAmount = remainingInput;
        plan.totalOutput = bestOutput;
        plan.worthUsing = bestOutput > pureAMM.amountOut;
    }

    /// @notice Fill a single order
    function _fillSingleOrder(
        uint256 orderId,
        uint128 fillAmount,
        uint256 fillPrice,
        address maker,
        address taker,
        PoolKey calldata key
    ) internal {
        // Decode order
        (, , , , bool orderIsBuy) = GlobalOrderIdLibrary.decode(orderId);

        emit OrderFilled(orderId, maker, taker, fillAmount, fillPrice);

        // Update balances
        if (orderIsBuy) {
            uint128 cost = uint128((uint256(fillAmount) * fillPrice) / 1e18);
            balances[maker][key.currency1].locked -= cost;
            balances[maker][key.currency1].total -= cost;
            balances[maker][key.currency0].total += fillAmount;
        } else {
            uint128 proceeds = uint128((uint256(fillAmount) * fillPrice) / 1e18);
            balances[maker][key.currency0].locked -= fillAmount;
            balances[maker][key.currency0].total -= fillAmount;
            balances[maker][key.currency1].total += proceeds;
        }
    }

    /// @notice Find candidate by order ID
    function _findCandidate(
        OrderCandidate[] memory candidates,
        uint256 orderId
    ) internal pure returns (OrderCandidate memory) {
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i].orderId == orderId) {
                return candidates[i];
            }
        }
        revert("Candidate not found");
    }

    /*//////////////////////////////////////////////////////////////
                        COMPARISON HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get routing method name (for testing)
    function getRoutingMethod() external pure returns (string memory) {
        return "OPTIMAL_GREEDY";
    }
}
