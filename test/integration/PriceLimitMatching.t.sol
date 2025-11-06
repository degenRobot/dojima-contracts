// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FenwickOrderBook} from "src/dojima/orderbook/FenwickOrderBook.sol";
import {OrderBookTypes} from "src/dojima/orderbook/OrderBookTypes.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

contract PriceLimitMatchingTest is Test {
    using FenwickOrderBook for OrderBookTypes.Book;

    OrderBookTypes.Book book;
    OrderBookTypes.Config config;
    PoolId poolId;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC);

    function setUp() public {
        // Setup config with price range
        config = OrderBookTypes.Config({
            minPrice: 2500e18,
            maxPrice: 2600e18,
            priceIncrement: 0.01e18,
            numPricePoints: 10000
        });

        // Initialize book
        uint256 marketPriceIndex = config.numPricePoints / 2;
        book.initialize(marketPriceIndex);

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    /// @notice Test: Skip expensive tail orders
    /// @dev This is the core value proposition of price-limit matching
    function test_PriceLimitMatching_SkipExpensiveTail() public {
        // Place 3 sell orders at different prices
        // Order 1: Good price (will match)
        book.placeOrder(config, 2530e18, 50 ether, false, alice);

        // Order 2: Good price (will match)
        book.placeOrder(config, 2540e18, 30 ether, false, bob);

        // Order 3: Expensive (should skip!)
        book.placeOrder(config, 2560e18, 20 ether, false, charlie);

        // AMM price is 2550 (between order 2 and order 3)
        uint256 ammPrice = 2550e18;

        // Match with price limit
        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0, // tick (doesn't matter for unit test)
            true, // buy
            100 ether, // want to buy 100 ETH
            ammPrice // only match if price <= 2550
        );

        // Should match only first 2 orders (80 ETH total)
        assertEq(result.amountFilled, 80 ether, "Should match 80 ETH (skip expensive tail)");
        assertEq(result.amountRemaining, 20 ether, "Should leave 20 ETH unmatched");
        assertEq(result.ordersMatched, 2, "Should match 2 orders (skip 3rd)");

        // Calculate expected cost
        uint256 expectedCost = (50 ether * 2530e18) / 1e18 + (30 ether * 2540e18) / 1e18;
        assertEq(result.totalCost, expectedCost, "Total cost should exclude expensive order");

        // Average price should be better than AMM
        assertTrue(result.avgPrice < ammPrice, "Avg CLOB price should be better than AMM");
    }

    /// @notice Test: Match all when all orders better than AMM
    function test_PriceLimitMatching_AllBetterThanAMM() public {
        // Place 3 orders, all better than AMM
        book.placeOrder(config, 2530e18, 30 ether, false, alice);
        book.placeOrder(config, 2540e18, 30 ether, false, bob);
        book.placeOrder(config, 2550e18, 40 ether, false, charlie);

        // AMM price is higher
        uint256 ammPrice = 2560e18;

        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            true,
            100 ether,
            ammPrice
        );

        // Should match all orders
        assertEq(result.amountFilled, 100 ether, "Should match all 100 ETH");
        assertEq(result.amountRemaining, 0, "Should have no remaining");
        assertEq(result.ordersMatched, 3, "Should match all 3 orders");
    }

    /// @notice Test: Skip all when all orders worse than AMM
    function test_PriceLimitMatching_AllWorseThanAMM() public {
        // Place 3 orders, all worse than AMM
        book.placeOrder(config, 2560e18, 30 ether, false, alice);
        book.placeOrder(config, 2570e18, 30 ether, false, bob);
        book.placeOrder(config, 2580e18, 40 ether, false, charlie);

        // AMM price is lower (better)
        uint256 ammPrice = 2550e18;

        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            true,
            100 ether,
            ammPrice
        );

        // Should match nothing
        assertEq(result.amountFilled, 0, "Should match 0 ETH");
        assertEq(result.amountRemaining, 100 ether, "All should remain unmatched");
        assertEq(result.ordersMatched, 0, "Should match 0 orders");
    }

    /// @notice Test: Price exactly at limit (should still match)
    function test_PriceLimitMatching_ExactlyAtLimit() public {
        // Place order exactly at AMM price
        book.placeOrder(config, 2550e18, 50 ether, false, alice);

        uint256 ammPrice = 2550e18;

        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            true,
            50 ether,
            ammPrice
        );

        // Should match (price <= limit, not price < limit)
        assertEq(result.amountFilled, 50 ether, "Should match order at exact AMM price");
        assertEq(result.ordersMatched, 1, "Should match the order");
    }

    /// @notice Test: Sell orders (opposite direction)
    function test_PriceLimitMatching_SellOrders() public {
        // Place 3 buy orders
        book.placeOrder(config, 2570e18, 30 ether, true, alice); // High (good for seller)
        book.placeOrder(config, 2560e18, 30 ether, true, bob);   // Medium (good for seller)
        book.placeOrder(config, 2540e18, 40 ether, true, charlie); // Low (bad for seller)

        // AMM price is 2550 (seller would get 2550 from AMM)
        uint256 ammPrice = 2550e18;

        // User selling (matching against buy orders)
        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            false, // sell
            100 ether,
            ammPrice // only match if price >= 2550
        );

        // Should match only first 2 orders (60 ETH total)
        // Skip charlie's order at 2540 (worse than AMM 2550)
        assertEq(result.amountFilled, 60 ether, "Should match 60 ETH (skip low bid)");
        assertEq(result.ordersMatched, 2, "Should match 2 orders");
    }

    /// @notice Test: Partial order fill at price limit
    function test_PriceLimitMatching_PartialFillAtLimit() public {
        // Place 2 orders
        book.placeOrder(config, 2530e18, 40 ether, false, alice); // Good
        book.placeOrder(config, 2540e18, 40 ether, false, bob);   // Good
        book.placeOrder(config, 2560e18, 40 ether, false, charlie); // Bad

        uint256 ammPrice = 2550e18;

        // Only want 50 ETH (will fill order 1 completely + part of order 2)
        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            true,
            50 ether,
            ammPrice
        );

        // Should match 50 ETH from first 2 orders
        assertEq(result.amountFilled, 50 ether, "Should match exactly 50 ETH");
        assertEq(result.ordersMatched, 2, "Should match 2 orders (partial fill of 2nd)");

        // Verify order 3 was never touched (still has full amount)
        // This would require tracking order state, which is tested in integration tests
    }

    /// @notice Test: Empty order book
    function test_PriceLimitMatching_EmptyBook() public {
        uint256 ammPrice = 2550e18;

        OrderBookTypes.MatchResult memory result = book.matchMarketOrderWithLimit(
            config,
            poolId,
            0,
            true,
            100 ether,
            ammPrice
        );

        assertEq(result.amountFilled, 0, "Should match nothing");
        assertEq(result.amountRemaining, 100 ether, "All should remain");
        assertEq(result.ordersMatched, 0, "Should match 0 orders");
    }

    /// @notice Test: Regular matching matches expensive orders
    function test_RegularMatching_MatchesExpensiveOrders() public {
        // Setup: 3 orders with mixed pricing
        book.placeOrder(config, 2530e18, 50 ether, false, alice);
        book.placeOrder(config, 2540e18, 30 ether, false, bob);
        book.placeOrder(config, 2560e18, 20 ether, false, charlie);

        // Test: Regular matching (old behavior) - matches ALL orders
        OrderBookTypes.MatchResult memory regularResult = book.matchMarketOrder(
            config,
            poolId,
            0,
            true,
            100 ether
        );

        // Should match ALL 3 orders (including expensive one)
        assertEq(regularResult.amountFilled, 100 ether, "Regular: matches all 100 ETH");
        assertEq(regularResult.ordersMatched, 3, "Regular: matches all 3 orders");

        // Calculate expected cost including expensive order
        uint256 expectedCost = (50 ether * 2530e18) / 1e18
                             + (30 ether * 2540e18) / 1e18
                             + (20 ether * 2560e18) / 1e18;
        assertEq(regularResult.totalCost, expectedCost, "Should include expensive order cost");

        emit log_named_uint("Regular matching cost", regularResult.totalCost);
        emit log_named_uint("Regular avg price", regularResult.avgPrice);
    }
}
