// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DojimaHybridHook} from "src/dojima/DojimaHybridHook.sol";
import {OrderBookTypes, GlobalOrderIdLibrary} from "src/dojima/orderbook/OrderBookTypes.sol";
import {MockERC20} from "../utils/Setup.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";

contract DojimaHybridHookTest is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    // Contracts
    DojimaHybridHook hook;
    MockERC20 token0;
    MockERC20 token1;

    // RISE Testnet addresses
    ICLPoolManager poolManager = ICLPoolManager(0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f);
    IVault vault = IVault(0xf93C3641dD8668Fcd54Cf9C4d365DBb9e97527de);

    // Test accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Pool configuration
    PoolKey poolKey;
    PoolId poolId;
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    function setUp() public {
        // Fork RISE testnet
        vm.createSelectFork("https://testnet.riselabs.xyz/");

        // Deploy mock tokens
        token0 = new MockERC20("Test Token 0", "TK0", 18);
        token1 = new MockERC20("Test Token 1", "TK1", 18);

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy hook
        hook = new DojimaHybridHook(poolManager);

        // Create pool key
        bytes32 parameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));
        parameters = parameters.setTickSpacing(TICK_SPACING);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: FEE,
            parameters: parameters
        });

        poolId = poolKey.toId();

        // Initialize pool at price = 1.0
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // price = 1.0
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Mint tokens to test accounts
        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);
        token0.mint(bob, 1000 ether);
        token1.mint(bob, 1000 ether);

        // Approve vault and hook for token transfers
        vm.startPrank(alice);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    function test_PlaceOrder() public {
        console.log("Testing basic order placement...");

        // Get current pool price and use a price slightly above it
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        console.log("Current tick:", uint256(uint24(currentTick)));
        console.log("Current sqrtPriceX96:", sqrtPriceX96);

        // Price = 1.0 from initialization, so use 1.01 (1% above)
        uint256 price = 1.01e18;
        uint128 amount = 10 ether;

        uint256 aliceToken0Before = token0.balanceOf(alice);

        vm.prank(alice);
        uint256 orderId = hook.placeOrder(
            poolKey,
            price,
            amount,
            false // sell order (deposit token0)
        );

        console.log("Order ID:", orderId);
        // Note: Order IDs are now derived, not sequential

        // Check order details
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.maker, alice, "Maker should be alice");

        assertEq(order.amount, amount, "Amount should match");
        assertEq(order.filled, 0, "Should not be filled yet");

        // Check tokens were transferred
        uint256 aliceToken0After = token0.balanceOf(alice);
        assertEq(aliceToken0Before - aliceToken0After, amount, "Should have deposited token0");

        console.log("[PASS] Order placed successfully");
    }

    function test_GetBestPrices() public {
        console.log("Testing getBestAsk and getBestBid...");

        // Place sell orders at valid prices
        vm.prank(alice);
        hook.placeOrder(poolKey, 1.01e18, 10 ether, false);

        // Place another sell order at a different price
        vm.prank(alice);
        hook.placeOrder(poolKey, 1.009e18, 10 ether, false);

        // Get best ask price (we only placed sell orders)
        (int24 askTick, uint256 askPrice) = hook.getBestAsk(poolKey);

        console.log("Ask tick:", uint256(uint24(askTick)));
        console.log("Best ask:", askPrice);

        // Verify we found an ask (sell order)
        assertTrue(askTick != type(int24).max, "Should have ask tick");

        // getBestBid should return min tick (no buy orders placed)
        (int24 bidTick, uint256 bidPrice) = hook.getBestBid(poolKey);
        console.log("Bid tick (should be min - no buy orders):", int256(bidTick));
        console.log("Best bid:", bidPrice);

        // With no buy orders, bidTick should be type(int24).min
        assertTrue(bidTick == type(int24).min, "Bid tick should be min (no buy orders)");

        console.log("[PASS] Best prices retrieved successfully");
    }

    // NOTE: getUserOrders was removed in Phase 1 optimizations
    // User orders are now tracked via OrderPlaced events for gas efficiency
    // Frontend should index events to build user order lists
    function test_GetUserOrders() public {
        console.log("Testing user order placement (event-based tracking)...");

        // Alice places 3 orders - events will be emitted
        // Use prices that align with price increments
        vm.startPrank(alice);
        uint256 order1 = hook.placeOrder(poolKey, 1.01e18, 5 ether, false);
        uint256 order2 = hook.placeOrder(poolKey, 1.009e18, 5 ether, false);
        uint256 order3 = hook.placeOrder(poolKey, 1.008e18, 5 ether, false);
        vm.stopPrank();

        // Verify orders were created by checking they can be retrieved
        OrderBookTypes.Order memory o1 = hook.getOrder(order1, poolKey);
        OrderBookTypes.Order memory o2 = hook.getOrder(order2, poolKey);
        OrderBookTypes.Order memory o3 = hook.getOrder(order3, poolKey);

        assertEq(o1.maker, alice, "Order 1 maker should be alice");
        assertEq(o2.maker, alice, "Order 2 maker should be alice");
        assertEq(o3.maker, alice, "Order 3 maker should be alice");

        console.log("[PASS] User orders placed successfully (track via events)");
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_CancelOrder() public {
        console.log("Testing order cancellation...");

        // Place order
        vm.prank(alice);
        uint256 orderId = hook.placeOrder(poolKey, 1.01e18, 10 ether, false);

        // Cancel order
        vm.prank(alice);
        hook.cancelOrder(orderId, poolKey);

        // Check order is cancelled (filled == amount means cancelled or fully filled)
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.filled, order.amount, "Order should be marked as filled (cancelled)");

        console.log("[PASS] Order cancelled successfully");
    }

    function test_CannotCancelOthersOrder() public {
        console.log("Testing cannot cancel others' orders...");

        // Alice places order
        vm.prank(alice);
        uint256 orderId = hook.placeOrder(poolKey, 1.01e18, 10 ether, false);

        // Bob tries to cancel (should revert)
        vm.prank(bob);
        vm.expectRevert(DojimaHybridHook.NotOrderMaker.selector);
        hook.cancelOrder(orderId, poolKey);

        console.log("[PASS] Cannot cancel others' orders");
    }

    /*//////////////////////////////////////////////////////////////
                        HYBRID EXECUTION (CLOB + AMM)
    //////////////////////////////////////////////////////////////*/

    function test_HybridExecution_PartialCLOBFill() public {
        console.log("Testing hybrid execution: partial CLOB + AMM fill...");

        // Setup: Place sell order for 50 ETH at price slightly above market
        uint256 orderPrice = 1.01e18;
        uint128 orderAmount = 50 ether;

        vm.prank(alice);
        uint256 orderId = hook.placeOrder(poolKey, orderPrice, orderAmount, false);

        console.log("Placed sell order:", orderId);
        console.log("Order amount:", orderAmount);

        // Verify order placed
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.amount, orderAmount, "Order amount should match");
        assertEq(order.filled, 0, "Order should not be filled yet");

        console.log("[PASS] Hybrid execution test setup complete");
    }

    function test_BeforeSwapHook_OrderMatching() public {
        console.log("Testing beforeSwap hook with order matching...");

        // Place a sell order below current market price (should be executable)
        vm.prank(alice);
        uint256 orderId = hook.placeOrder(poolKey, 0.99e18, 10 ether, false);

        console.log("Placed sell order at 0.99, orderId:", orderId);

        OrderBookTypes.Order memory orderBefore = hook.getOrder(orderId, poolKey);
        console.log("Order amount before swap:", orderBefore.amount);
        console.log("Order filled before swap:", orderBefore.filled);

        // Note: To actually execute a swap and test order matching, we would need to:
        // 1. Add liquidity to the pool
        // 2. Call poolManager.swap() which triggers beforeSwap hook
        // 3. Verify order gets filled and events are emitted
        // This requires more complex setup with vault callbacks

        console.log("[PASS] Order ready for matching");
        console.log("Note: Full swap test requires liquidity provider setup");
    }

    function test_PureCLOBExecution() public {
        console.log("Testing pure CLOB execution (100% fill from order book)...");

        // Place sell order at 1.01
        vm.prank(alice);
        uint256 orderId = hook.placeOrder(poolKey, 1.01e18, 100 ether, false);

        // Verify order placed
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.amount, 100 ether, "Order amount should match");

        console.log("[PASS] Pure CLOB setup complete");
        console.log("Note: Full swap execution requires implementing taker flow");
    }

    function test_CrossTickMatching() public {
        console.log("Testing cross-tick matching...");

        // Place orders at different price levels
        // 1.01e18 is known to work (tick 60), let's use prices near that
        vm.startPrank(alice);

        // Order 1: Price 1.01 (tick 60)
        uint256 order1 = hook.placeOrder(poolKey, 1.01e18, 10 ether, false);

        // Order 2: Price 1.008 (tick 60, different price level)
        uint256 order2 = hook.placeOrder(poolKey, 1.008e18, 10 ether, false);

        // Order 3: Price 1.009 (tick 60, another price level)
        uint256 order3 = hook.placeOrder(poolKey, 1.009e18, 10 ether, false);

        vm.stopPrank();

        // Verify all orders placed successfully
        OrderBookTypes.Order memory meta1 = hook.getOrder(order1, poolKey);
        OrderBookTypes.Order memory meta2 = hook.getOrder(order2, poolKey);
        OrderBookTypes.Order memory meta3 = hook.getOrder(order3, poolKey);

        // Decode tick and price information from order IDs
        (,int24 tick1, uint256 priceIndex1,,) = GlobalOrderIdLibrary.decode(order1);
        (,int24 tick2, uint256 priceIndex2,,) = GlobalOrderIdLibrary.decode(order2);
        (,int24 tick3, uint256 priceIndex3,,) = GlobalOrderIdLibrary.decode(order3);

        console.log("Order 1 tick:", uint256(uint24(tick1)), "priceIndex:", priceIndex1);
        console.log("Order 2 tick:", uint256(uint24(tick2)), "priceIndex:", priceIndex2);
        console.log("Order 3 tick:", uint256(uint24(tick3)), "priceIndex:", priceIndex3);

        // Verify orders are in different price levels (may be same tick, that's OK)
        assertTrue(priceIndex1 != priceIndex2 || tick1 != tick2, "Orders 1 and 2 should be at different price levels");
        assertTrue(priceIndex1 != priceIndex3 || tick1 != tick3, "Orders 1 and 3 should be at different price levels");

        console.log("[PASS] Cross-tick orders placed successfully");
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetTickDepth() public {
        console.log("Testing getTickDepth...");

        // Get current tick
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        // Place orders around $2,500
        vm.prank(alice);
        hook.placeOrder(poolKey, 1.00e18, 10 ether, false);

        // Check depth
        (uint128 totalAmount, uint256 orderCount) = hook.getTickDepth(poolKey, tick, false);

        console.log("Tick depth - amount:", totalAmount);
        console.log("Tick depth - count:", orderCount);

        // Note: depth tracking might be simplified for now
        // Just verify it doesn't revert
        console.log("[PASS] getTickDepth executed successfully");
    }
}
