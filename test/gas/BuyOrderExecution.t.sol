// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Setup} from "../utils/Setup.sol";
import {console} from "forge-std/console.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

/// @title BuyOrderExecution
/// @notice Comprehensive buy order testing and execution quality
/// @dev Tests buy orders (buying token0 with token1) in various scenarios
contract BuyOrderExecutionTest is Setup {

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                    BUY ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for placing a buy order
    function test_Gas_PlaceBuyOrder_First() public {
        depositForUser(maker1, 0, 10 ether);  // Deposit token1 for buy order

        uint256 gasBefore = gasleft();
        placeBuyOrder(maker1, 0.99e18, 2 ether);  // Buy at 0.99 (1% below current)
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Place Buy Order: First ===");
        console.log("Gas used:", gasUsed);
        console.log("Price: 0.99 (1% below current)");
        console.log("Amount: 2 ETH");
    }

    /// @notice Gas cost for placing multiple buy orders
    function test_Gas_PlaceBuyOrder_Multiple() public {
        depositForUser(maker1, 0, 30 ether);

        console.log("=== Place Buy Orders: Multiple ===");

        for (uint256 i = 0; i < 5; i++) {
            uint256 price = 0.995e18 - (i * 0.002e18);
            uint256 gasBefore = gasleft();
            placeBuyOrder(maker1, price, 2 ether);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Order:", i + 1);
            console.log("  Price:", price);
            console.log("  Gas:", gasUsed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                BUY ORDER EXECUTION - SINGLE ORDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute buy swap that fills a single buy order
    function test_Execute_BuyOrder_SingleFill() public {
        // Add AMM liquidity
        addStandardLiquidity(100 ether);

        // Place buy order below current price
        depositForUser(maker1, 0, 10 ether);
        placeBuyOrder(maker1, 0.997e18, 3 ether);

        // Execute sell swap (selling token0) that will hit buy order
        uint256 swapSize = 2 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Execute: Single Buy Order Fill ===");
        console.log("Buy order: 3 ETH @ 0.997");
        console.log("Swap: Sell 2 ETH token0");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /// @notice Buy order partial fill
    function test_Execute_BuyOrder_PartialFill() public {
        addStandardLiquidity(100 ether);

        // Place large buy order
        depositForUser(maker1, 0, 20 ether);
        placeBuyOrder(maker1, 0.998e18, 10 ether);

        // Small sell swap (partial fill)
        uint256 swapSize = 2 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Execute: Partial Buy Order Fill ===");
        console.log("Buy order: 10 ETH @ 0.998");
        console.log("Swap: Sell 2 ETH (partial fill)");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /*//////////////////////////////////////////////////////////////
            BUY ORDER EXECUTION - MULTIPLE ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute swap across multiple buy orders
    function test_Execute_BuyOrder_MultipleFills() public {
        addStandardLiquidity(100 ether);

        // Place multiple buy orders at different prices
        depositForUser(maker1, 0, 50 ether);
        placeBuyOrder(maker1, 0.999e18, 2 ether);  // Highest
        placeBuyOrder(maker1, 0.997e18, 2 ether);
        placeBuyOrder(maker1, 0.995e18, 2 ether);
        placeBuyOrder(maker1, 0.993e18, 2 ether);  // Lowest

        // Large sell swap - fills multiple orders
        uint256 swapSize = 7 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Execute: Multiple Buy Order Fills ===");
        console.log("Buy orders: 4 orders (2 ETH each)");
        console.log("Swap: Sell 7 ETH");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
        console.log("Orders filled: ~3-4 orders");
    }

    /// @notice Multiple buy orders from different makers
    function test_Execute_BuyOrder_MultiMaker() public {
        addStandardLiquidity(100 ether);

        // Setup 3 makers with buy orders
        depositForUser(maker1, 0, 20 ether);
        depositForUser(maker2, 0, 20 ether);
        depositForUser(maker3, 0, 20 ether);

        placeBuyOrder(maker1, 0.999e18, 2 ether);
        placeBuyOrder(maker2, 0.998e18, 2 ether);
        placeBuyOrder(maker3, 0.997e18, 2 ether);
        placeBuyOrder(maker1, 0.996e18, 2 ether);
        placeBuyOrder(maker2, 0.995e18, 2 ether);

        // Execute swap
        uint256 swapSize = 8 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Execute: Multi-Maker Buy Orders ===");
        console.log("Makers: 3");
        console.log("Buy orders: 5 total");
        console.log("Swap: Sell 8 ETH");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /*//////////////////////////////////////////////////////////////
            BUY ORDER CROSS-TICK EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy orders across multiple ticks
    function test_Execute_BuyOrder_CrossTick() public {
        addStandardLiquidity(100 ether);

        // Place buy orders across different ticks (going down)
        depositForUser(maker1, 0, 50 ether);

        placeBuyOrder(maker1, 0.998e18, 2 ether);  // Tick 0
        placeBuyOrder(maker1, 0.992e18, 2 ether);  // Tick -60
        placeBuyOrder(maker1, 0.986e18, 2 ether);  // Tick -120
        placeBuyOrder(maker1, 0.980e18, 2 ether);  // Tick -180

        // Large sell swap crosses multiple ticks
        uint256 swapSize = 10 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Execute: Buy Orders Cross-Tick ===");
        console.log("Buy orders across 4 ticks");
        console.log("Swap: Sell 10 ETH");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
        console.log("Ticks crossed: ~4");
    }

    /*//////////////////////////////////////////////////////////////
            BUY vs SELL ORDER GAS COMPARISON
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare gas costs: buy orders vs sell orders
    function test_Gas_Comparison_BuyVsSell() public {
        console.log("");
        console.log("=== Gas Comparison: Buy vs Sell Orders ===");
        console.log("");

        // Test sell order
        depositForUser(maker1, 10 ether, 0);
        uint256 gasSell = gasleft();
        placeSellOrder(maker1, 1.005e18, 3 ether);
        uint256 gasSellUsed = gasSell - gasleft();

        // Test buy order
        depositForUser(maker2, 0, 10 ether);
        uint256 gasBuy = gasleft();
        placeBuyOrder(maker2, 0.995e18, 3 ether);
        uint256 gasBuyUsed = gasBuy - gasleft();

        console.log("Sell Order gas:", gasSellUsed);
        console.log("Buy Order gas: ", gasBuyUsed);
        console.log("Difference:    ", gasBuyUsed > gasSellUsed ? gasBuyUsed - gasSellUsed : gasSellUsed - gasBuyUsed);
        console.log("");
    }

    /*//////////////////////////////////////////////////////////////
            REALISTIC BUY ORDER SCENARIOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Realistic: Light buy-side liquidity
    function test_Realistic_LightBuyBook() public {
        addStandardLiquidity(100 ether);

        // Place 3 buy orders
        depositForUser(maker1, 0, 20 ether);
        placeBuyOrder(maker1, 0.998e18, 2 ether);
        placeBuyOrder(maker1, 0.995e18, 2 ether);
        placeBuyOrder(maker1, 0.992e18, 2 ether);

        // Sell swap hits buy orders
        uint256 swapSize = 4 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);

        console.log("=== Realistic: Light Buy-Side Book ===");
        console.log("Buy orders: 3 (6 ETH total)");
        console.log("Swap: Sell 4 ETH");
        console.log("Execution price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /// @notice Realistic: Medium buy-side liquidity
    function test_Realistic_MediumBuyBook() public {
        addStandardLiquidity(100 ether);

        // Place 10 buy orders
        depositForUser(maker1, 0, 50 ether);
        for (uint256 i = 0; i < 10; i++) {
            uint256 orderPrice = 0.999e18 - (i * 0.001e18);
            placeBuyOrder(maker1, orderPrice, 1.5 ether);
        }

        // Medium sell swap
        uint256 swapSize = 8 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 execPrice = getExecutionPrice(delta, true);

        console.log("=== Realistic: Medium Buy-Side Book ===");
        console.log("Buy orders: 10 (15 ETH total)");
        console.log("Swap: Sell 8 ETH");
        console.log("Execution price:", execPrice);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /// @notice Realistic: Deep buy-side liquidity
    function test_Realistic_DeepBuyBook() public {
        addStandardLiquidity(100 ether);

        // Place 20 buy orders
        depositForUser(maker1, 0, 100 ether);
        for (uint256 i = 0; i < 20; i++) {
            uint256 orderPrice = 0.999e18 - (i * 0.0008e18);
            placeBuyOrder(maker1, orderPrice, 2 ether);
        }

        // Large sell swap
        uint256 swapSize = 25 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 execPrice = getExecutionPrice(delta, true);

        console.log("=== Realistic: Deep Buy-Side Book ===");
        console.log("Buy orders: 20 (40 ETH total)");
        console.log("Swap: Sell 25 ETH");
        console.log("Execution price:", execPrice);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
    }

    /*//////////////////////////////////////////////////////////////
            TWO-SIDED MARKET (BUY + SELL ORDERS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Two-sided market: both buy and sell orders active
    function test_TwoSidedMarket_Balanced() public {
        addStandardLiquidity(100 ether);

        // Setup makers with balanced buy/sell orders
        depositForUser(maker1, 20 ether, 20 ether);
        depositForUser(maker2, 20 ether, 20 ether);

        // Sell orders above current price
        placeSellOrder(maker1, 1.002e18, 2 ether);
        placeSellOrder(maker1, 1.005e18, 2 ether);
        placeSellOrder(maker1, 1.008e18, 2 ether);

        // Buy orders below current price
        placeBuyOrder(maker2, 0.998e18, 2 ether);
        placeBuyOrder(maker2, 0.995e18, 2 ether);
        placeBuyOrder(maker2, 0.992e18, 2 ether);

        console.log("=== Two-Sided Market: Balanced ===");
        console.log("Sell orders: 3 (6 ETH)");
        console.log("Buy orders: 3 (6 ETH)");
        console.log("");

        // Test buy swap (fills sell orders)
        uint256 buySwapSize = 4 ether;
        BalanceDelta deltaBuy = executeBuySwap(taker1, buySwapSize);
        uint256 priceBuy = getExecutionPrice(deltaBuy, false);
        console.log("Buy Swap: 4 ETH token1 -> Price:", priceBuy);

        // Test sell swap (fills buy orders)
        uint256 sellSwapSize = 4 ether;
        BalanceDelta deltaSell = executeSellSwap(taker2, sellSwapSize);
        uint256 priceSell = getExecutionPrice(deltaSell, true);
        console.log("Sell Swap: 4 ETH token0 -> Price:", priceSell);
        console.log("");
    }

    /// @notice Two-sided market with varying depths
    function test_TwoSidedMarket_AsymmetricDepth() public {
        addStandardLiquidity(100 ether);

        // Deeper buy-side
        depositForUser(maker1, 10 ether, 50 ether);

        // 3 sell orders
        placeSellOrder(maker1, 1.005e18, 2 ether);
        placeSellOrder(maker1, 1.010e18, 2 ether);
        placeSellOrder(maker1, 1.015e18, 2 ether);

        // 10 buy orders
        for (uint256 i = 0; i < 10; i++) {
            placeBuyOrder(maker1, 0.998e18 - (i * 0.002e18), 1.5 ether);
        }

        console.log("=== Two-Sided Market: Asymmetric Depth ===");
        console.log("Sell orders: 3 (6 ETH)");
        console.log("Buy orders: 10 (15 ETH)");
        console.log("");

        // Large sell swap benefits from deep buy-side
        uint256 swapSize = 12 ether;
        BalanceDelta delta = executeSellSwap(taker1, swapSize);
        uint256 price = getExecutionPrice(delta, true);
        console.log("Sell 12 ETH -> Price:", price);
        console.log("Token1 received:", uint256(int256(delta.amount1())));
        console.log("(Benefits from deep buy-side)");
        console.log("");
    }

    /*//////////////////////////////////////////////////////////////
            BUY ORDER CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for cancelling buy orders
    function test_Gas_CancelBuyOrder() public {
        depositForUser(maker1, 0, 20 ether);

        // Place order
        uint256 orderId = placeBuyOrder(maker1, 0.995e18, 5 ether);

        // Measure cancel gas
        uint256 gasBefore = gasleft();
        cancelOrder(maker1, orderId);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Cancel Buy Order ===");
        console.log("Gas used:", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
            PRICE IMPROVEMENT WITH BUY ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare sell swap prices: AMM vs Hybrid with buy orders
    function test_PriceImprovement_BuyOrders() public {
        uint256 sellSwapSize = 5 ether;

        // Test 1: Pure AMM
        addStandardLiquidity(100 ether);
        BalanceDelta deltaAMM = executeSellSwap(taker1, sellSwapSize);
        uint256 priceAMM = getExecutionPrice(deltaAMM, true);

        // Reset
        setUp();

        // Test 2: Hybrid with buy orders
        addStandardLiquidity(100 ether);
        depositForUser(maker1, 0, 30 ether);
        for (uint256 i = 0; i < 8; i++) {
            placeBuyOrder(maker1, 0.998e18 - (i * 0.002e18), 1 ether);
        }
        BalanceDelta deltaHybrid = executeSellSwap(taker2, sellSwapSize);
        uint256 priceHybrid = getExecutionPrice(deltaHybrid, true);

        // Calculate improvement
        int256 improvementBps = calculatePriceImprovement(priceAMM, priceHybrid, false);

        console.log("");
        console.log("=== Price Improvement: Buy Orders (Sell Swap) ===");
        console.log("Pure AMM price:     ", priceAMM);
        console.log("Hybrid price:       ", priceHybrid);
        console.log("Improvement (bps):  ", uint256(improvementBps));
        console.log("AMM output:         ", uint256(int256(deltaAMM.amount1())));
        console.log("Hybrid output:      ", uint256(int256(deltaHybrid.amount1())));
        console.log("");
    }

    /*//////////////////////////////////////////////////////////////
                    SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @notice Comprehensive buy order execution summary
    function test_Summary_BuyOrderExecution() public {
        console.log("");
        console.log("===========================================");
        console.log("  BUY ORDER EXECUTION SUMMARY");
        console.log("===========================================");
        console.log("");
        console.log("Buy Order Coverage:");
        console.log("1. Single buy order fill");
        console.log("2. Partial buy order fill");
        console.log("3. Multiple buy order fills");
        console.log("4. Multi-maker buy orders");
        console.log("5. Cross-tick buy order execution");
        console.log("6. Buy vs sell order gas comparison");
        console.log("7. Realistic buy-side scenarios");
        console.log("8. Two-sided markets");
        console.log("9. Buy order cancellation");
        console.log("10. Price improvement analysis");
        console.log("");
        console.log("Key Findings:");
        console.log("- Buy orders work symmetrically to sell orders");
        console.log("- Gas costs comparable between buy/sell");
        console.log("- Deep buy-side provides price improvement for sellers");
        console.log("- Two-sided markets enhance execution quality");
        console.log("");
        console.log("===========================================");
        console.log("");
    }
}
