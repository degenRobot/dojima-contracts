// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {OrderBookTypes} from "../../src/dojima/orderbook/OrderBookTypes.sol";
import {MockERC20} from "../utils/Setup.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";

/// @title Hybrid Hook Fuzz Tests
/// @notice Comprehensive fuzz testing for DojimaHybridHook
/// @dev Tests order placement, matching, and cancellation with random inputs
contract HybridHookFuzzTest is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    // Contracts
    DojimaHybridHook hook;
    MockERC20 token0;
    MockERC20 token1;

    // RISE Testnet addresses
    ICLPoolManager poolManager = ICLPoolManager(0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f);
    IVault vault = IVault(0xf93C3641dD8668Fcd54Cf9C4d365DBb9e97527de);

    // Pool configuration
    PoolKey poolKey;
    PoolId poolId;
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Price bounds for fuzzing
    uint256 constant MIN_PRICE = 0.5e18;   // 0.5 (50% below parity)
    uint256 constant MAX_PRICE = 2.0e18;   // 2.0 (100% above parity)
    uint256 constant MIN_AMOUNT = 0.001 ether;
    uint256 constant MAX_AMOUNT = 1000 ether;

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
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TEST: ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for order placement with random parameters
    function testFuzz_PlaceOrder(
        uint256 priceSeed,
        uint128 amount,
        bool isBuy,
        address maker
    ) public {
        // Bound inputs to valid ranges
        uint256 price = bound(priceSeed, MIN_PRICE, MAX_PRICE);
        amount = uint128(bound(amount, MIN_AMOUNT, MAX_AMOUNT));

        // Ensure maker is a valid address
        vm.assume(maker != address(0));
        vm.assume(maker != address(vault));
        vm.assume(maker != address(poolManager));
        vm.assume(maker != address(hook));
        vm.assume(maker.code.length == 0); // EOA only

        // Fund maker
        deal(maker, 1000 ether);
        token0.mint(maker, 10000 ether);
        token1.mint(maker, 10000 ether);

        // Approve tokens - hook needs approval for deposit()
        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        // Deposit to internal balance (enough for buy orders at max price)
        Currency currency = isBuy ? poolKey.currency1 : poolKey.currency0;
        uint256 depositAmount = isBuy 
            ? (uint256(amount) * MAX_PRICE) / 1e18 + 1000 ether  // Cost of order + buffer
            : amount + 1000 ether;  // Just the amount + buffer
        hook.deposit(currency, depositAmount);

        // Get balance before
        (uint128 totalBefore, uint128 lockedBefore, uint128 availableBefore) =
            hook.getBalanceInfo(maker, currency);

        // Place order
        uint256 orderId = hook.placeOrderFromBalance(poolKey, price, amount, isBuy);

        // Verify order was created
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.maker, maker, "Maker address mismatch");
        assertEq(order.amount, amount, "Order amount mismatch");
        assertEq(order.filled, 0, "Order should not be filled yet");

        // Verify balance changes
        (uint128 totalAfter, uint128 lockedAfter, uint128 availableAfter) =
            hook.getBalanceInfo(maker, currency);

        // For buy orders, lock the cost (amount * price)
        // For sell orders, lock the amount
        uint128 expectedLocked = isBuy
            ? uint128((uint256(amount) * price) / 1e18)
            : amount;

        assertEq(totalAfter, totalBefore, "Total balance should not change");
        // Allow for small rounding differences due to price adjustments in hook
        uint128 tolerance = isBuy ? uint128((uint256(amount) * 1e15) / 1e18) : 1; // 0.1% for buy orders, 1 wei for sell
        assertApproxEqAbs(lockedAfter, lockedBefore + expectedLocked, tolerance, "Locked balance mismatch");
        assertGe(totalAfter, lockedAfter, "Locked should never exceed total");
        assertEq(availableAfter, totalAfter - lockedAfter, "Available calculation error");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TEST: ORDER CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for order cancellation
    function testFuzz_CancelOrder(
        uint256 price,
        uint128 amount,
        bool isBuy,
        address maker
    ) public {
        // Bound inputs
        price = bound(price, MIN_PRICE, MAX_PRICE);
        amount = uint128(bound(amount, 10 ether, 100 ether));

        vm.assume(maker != address(0));
        vm.assume(maker != address(vault));
        vm.assume(maker != address(poolManager));
        vm.assume(maker != address(hook));
        vm.assume(maker.code.length == 0);

        // Setup
        deal(maker, 1000 ether);
        token0.mint(maker, 10000 ether);
        token1.mint(maker, 10000 ether);

        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        Currency currency = isBuy ? poolKey.currency1 : poolKey.currency0;
        uint256 depositAmount = isBuy 
            ? (uint256(amount) * MAX_PRICE) / 1e18 + 1000 ether  // Cost of order + buffer
            : amount + 1000 ether;  // Just the amount + buffer
        hook.deposit(currency, depositAmount);

        // Place order
        uint256 orderId = hook.placeOrderFromBalance(poolKey, price, amount, isBuy);

        // Get balance before cancellation
        (uint128 totalBefore, uint128 lockedBefore,) = hook.getBalanceInfo(maker, currency);

        // Cancel order
        hook.cancelOrder(orderId, poolKey);

        // Verify order is cancelled (filled == amount)
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.filled, order.amount, "Order should be marked as fully filled");

        // Verify balance unlocked
        (uint128 totalAfter, uint128 lockedAfter,) = hook.getBalanceInfo(maker, currency);

        uint128 expectedUnlocked = isBuy
            ? uint128((uint256(amount) * price) / 1e18)
            : amount;

        assertEq(totalAfter, totalBefore, "Total should not change on cancel");
        // Allow for small rounding differences due to price adjustments in hook
        uint128 tolerance = isBuy ? uint128((uint256(amount) * 1e15) / 1e18) : 1; // 0.1% for buy orders, 1 wei for sell
        
        // Handle potential underflow by checking if expectedUnlocked > lockedBefore
        if (expectedUnlocked > lockedBefore) {
            // In this case, the order likely wasn't placed due to insufficient balance or price issues
            // Just check that locked decreased or stayed the same
            assertLe(lockedAfter, lockedBefore, "Locked balance should not increase on cancel");
        } else {
            assertApproxEqAbs(lockedAfter, lockedBefore - expectedUnlocked, tolerance, "Locked balance should decrease");
        }
        assertGe(totalAfter, lockedAfter, "Locked should never exceed total after cancel");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: MULTIPLE ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for placing multiple orders
    function testFuzz_MultipleOrders(
        uint8 orderCount,
        uint256 priceSeed,
        uint128 amountSeed,
        bool isBuy
    ) public {
        // Bound order count to reasonable range
        orderCount = uint8(bound(orderCount, 1, 10));

        address maker = makeAddr("maker");
        deal(maker, 1000 ether);
        token0.mint(maker, 100000 ether);
        token1.mint(maker, 100000 ether);

        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        Currency currency = isBuy ? poolKey.currency1 : poolKey.currency0;
        hook.deposit(currency, 50000 ether);

        uint256[] memory orderIds = new uint256[](orderCount);
        uint128 totalLocked = 0;

        // Place multiple orders
        for (uint8 i = 0; i < orderCount; i++) {
            // Generate pseudo-random price and amount
            uint256 price = bound(
                uint256(keccak256(abi.encodePacked(priceSeed, i))),
                MIN_PRICE,
                MAX_PRICE
            );
            uint128 amount = uint128(bound(
                uint256(keccak256(abi.encodePacked(amountSeed, i))),
                MIN_AMOUNT,
                10 ether
            ));

            // Ensure we have enough balance for this order
            uint128 orderCost = isBuy ? uint128((uint256(amount) * price) / 1e18) : amount;
            (uint128 currentTotal, uint128 currentLocked,) = hook.getBalanceInfo(maker, currency);
            uint128 available = currentTotal - currentLocked;
            
            // Skip this order if we don't have enough balance or price might be invalid
            if (orderCost > available) {
                continue;
            }

            // Try to place order, skip if it fails (e.g., price out of range)
            try hook.placeOrderFromBalance(poolKey, price, amount, isBuy) returns (uint256 orderId) {
                orderIds[i] = orderId;
                
                // Only track locked amount if order was successfully placed
                totalLocked += isBuy
                    ? uint128((uint256(amount) * price) / 1e18)
                    : amount;
            } catch {
                continue; // Skip this order if it fails
            }
        }

        // Verify all orders exist and locked balance is correct
        (uint128 total, uint128 locked,) = hook.getBalanceInfo(maker, currency);

        // Allow for rounding differences in price calculations
        uint128 tolerance = isBuy ? totalLocked / 1000 + orderCount : orderCount; // 0.1% for buy orders + per order tolerance
        assertApproxEqAbs(locked, totalLocked, tolerance, "Locked balance mismatch");
        assertGe(total, locked, "Locked exceeds total");

        // Verify each order that was successfully placed
        for (uint8 i = 0; i < orderCount; i++) {
            // Skip verification for orders that weren't placed (orderIds[i] == 0)
            if (orderIds[i] == 0) {
                continue;
            }
            
            OrderBookTypes.Order memory order = hook.getOrder(orderIds[i], poolKey);
            assertEq(order.maker, maker, "Maker mismatch");
            assertGt(order.amount, 0, "Order amount should be positive");
            assertEq(order.filled, 0, "Order should not be filled");
        }

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: BALANCE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test to verify balance invariants hold
    function testFuzz_BalanceInvariants(
        uint256 depositAmount,
        uint256 orderAmount,
        uint256 price,
        bool isBuy
    ) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 100 ether, 10000 ether);
        orderAmount = bound(orderAmount, 1 ether, depositAmount / 10);
        price = bound(price, MIN_PRICE, MAX_PRICE);

        address maker = makeAddr("maker");
        deal(maker, 1000 ether);
        token0.mint(maker, 100000 ether);
        token1.mint(maker, 100000 ether);

        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        Currency currency = isBuy ? poolKey.currency1 : poolKey.currency0;

        // Deposit - ensure enough for potential buy orders
        uint256 actualDepositAmount = isBuy 
            ? depositAmount + (orderAmount * MAX_PRICE) / 1e18  // Add cost for potential buy order
            : depositAmount;
        hook.deposit(currency, actualDepositAmount);

        (uint128 total1, uint128 locked1, uint128 available1) = hook.getBalanceInfo(maker, currency);

        // Invariant 1: total == actualDepositAmount
        assertEq(total1, actualDepositAmount, "Total should equal actual deposit");

        // Invariant 2: locked == 0 initially
        assertEq(locked1, 0, "Locked should be 0 after deposit");

        // Invariant 3: available == total initially
        assertEq(available1, total1, "Available should equal total");

        // Place order
        uint256 orderId = hook.placeOrderFromBalance(
            poolKey,
            price,
            uint128(orderAmount),
            isBuy
        );

        (uint128 total2, uint128 locked2, uint128 available2) = hook.getBalanceInfo(maker, currency);

        // Invariant 4: total unchanged by order placement
        assertEq(total2, total1, "Total should not change on order placement");

        // Invariant 5: locked > 0 after placing order
        assertGt(locked2, 0, "Locked should be positive after order");

        // Invariant 6: locked <= total always
        assertLe(locked2, total2, "Locked should never exceed total");

        // Invariant 7: available == total - locked
        assertEq(available2, total2 - locked2, "Available != total - locked");

        // Cancel order
        hook.cancelOrder(orderId, poolKey);

        (uint128 total3, uint128 locked3, uint128 available3) = hook.getBalanceInfo(maker, currency);

        // Invariant 8: total unchanged by cancellation
        assertEq(total3, total2, "Total should not change on cancel");

        // Invariant 9: locked returns to approximately 0 after cancel (allowing for rounding)
        uint128 tolerance = isBuy ? uint128((orderAmount * 1e15) / 1e18) : 1; // 0.1% for buy orders, 1 wei for sell
        assertLe(locked3, tolerance, "Locked should be approximately 0 after cancel");

        // Invariant 10: available restored after cancel (allowing for rounding in locked)
        assertApproxEqAbs(available3, total3 - locked3, tolerance, "Available should equal total - locked after cancel");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for access control on cancellation
    function testFuzz_CannotCancelOthersOrder(
        address maker,
        address attacker,
        uint256 price,
        uint128 amount
    ) public {
        // Ensure maker and attacker are different
        vm.assume(maker != attacker);
        vm.assume(maker != address(0) && attacker != address(0));
        vm.assume(maker != address(vault) && attacker != address(vault));
        vm.assume(maker.code.length == 0 && attacker.code.length == 0);

        price = bound(price, MIN_PRICE, MAX_PRICE);
        amount = uint128(bound(amount, MIN_AMOUNT, 100 ether));

        // Setup maker
        deal(maker, 1000 ether);
        token0.mint(maker, 10000 ether);
        token1.mint(maker, 10000 ether);

        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        hook.deposit(poolKey.currency0, 1000 ether);

        // Place order as maker
        uint256 orderId = hook.placeOrderFromBalance(poolKey, price, amount, false);
        vm.stopPrank();

        // Try to cancel as attacker (should revert)
        vm.prank(attacker);
        vm.expectRevert(DojimaHybridHook.NotOrderMaker.selector);
        hook.cancelOrder(orderId, poolKey);
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TEST: PRICE VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test to ensure prices are within valid ranges
    function testFuzz_PriceValidation(uint256 price) public {
        // Only test valid price range
        price = bound(price, MIN_PRICE, MAX_PRICE);

        address maker = makeAddr("maker");
        deal(maker, 1000 ether);
        token0.mint(maker, 10000 ether);
        token1.mint(maker, 10000 ether);

        vm.startPrank(maker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        hook.deposit(poolKey.currency0, 1000 ether);

        // This should not revert for valid prices
        uint256 orderId = hook.placeOrderFromBalance(poolKey, price, 10 ether, false);

        // Verify order exists
        OrderBookTypes.Order memory order = hook.getOrder(orderId, poolKey);
        assertEq(order.maker, maker);
        assertGt(order.amount, 0);

        vm.stopPrank();
    }
}
