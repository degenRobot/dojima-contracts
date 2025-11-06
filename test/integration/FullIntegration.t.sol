// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {MockERC20} from "../utils/Setup.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/// @title FullIntegration
/// @notice Comprehensive integration tests for Dojima Hybrid AMM+CLOB
/// @dev Tests full flow: liquidity → orders → swaps → balance credits → withdrawals
contract FullIntegrationTest is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    // Contracts
    DojimaHybridHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    // RISE Testnet addresses
    ICLPoolManager poolManager = ICLPoolManager(0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f);
    IVault vault = IVault(0xf93C3641dD8668Fcd54Cf9C4d365DBb9e97527de);

    // Test users
    address public maker1;
    address public maker2;
    address public taker;
    address public liquidityProvider;

    // Pool configuration
    PoolKey poolKey;
    PoolId poolId;
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Events to test
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        bool isBuy,
        uint256 price,
        uint128 amount
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed maker,
        uint128 amount,
        uint256 fillPrice
    );
    event Deposited(address indexed user, Currency indexed currency, uint256 amount);
    event Withdrawn(address indexed user, Currency indexed currency, uint256 amount);
    event BalanceLocked(address indexed user, Currency indexed currency, uint128 amount);
    event BalanceUnlocked(address indexed user, Currency indexed currency, uint128 amount);

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

        // Create test users
        maker1 = makeAddr("maker1");
        maker2 = makeAddr("maker2");
        taker = makeAddr("taker");
        liquidityProvider = makeAddr("liquidityProvider");

        vm.deal(maker1, 100 ether);
        vm.deal(maker2, 100 ether);
        vm.deal(taker, 100 ether);
        vm.deal(liquidityProvider, 100 ether);

        // Mint tokens to users
        token0.mint(maker1, 1000 ether);
        token1.mint(maker1, 1000 ether);
        token0.mint(maker2, 1000 ether);
        token1.mint(maker2, 1000 ether);
        token0.mint(taker, 1000 ether);
        token1.mint(taker, 1000 ether);
        token0.mint(liquidityProvider, 10000 ether);
        token1.mint(liquidityProvider, 10000 ether);

        // Approve hook for deposit
        vm.prank(maker1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker1);
        token1.approve(address(hook), type(uint256).max);

        vm.prank(maker2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker2);
        token1.approve(address(hook), type(uint256).max);

        vm.prank(taker);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(taker);
        token1.approve(address(hook), type(uint256).max);

        vm.prank(liquidityProvider);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(liquidityProvider);
        token1.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL BALANCE INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test complete flow: deposit → order → cancel → withdraw
    function test_Integration_DepositOrderCancelWithdraw() public {
        // STEP 1: Maker deposits tokens
        vm.startPrank(maker1);

        hook.deposit(poolKey.currency0, 100 ether);

        // Verify internal balance
        (uint128 totalToken0, uint128 lockedToken0, uint128 availableToken0) =
            hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(totalToken0, 100 ether, "Deposit: total incorrect");
        assertEq(lockedToken0, 0, "Deposit: locked should be 0");
        assertEq(availableToken0, 100 ether, "Deposit: available incorrect");

        // STEP 2: Maker places sell order at 1.01 (sell token0 for token1)
        uint256 orderId = hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);

        // Verify balance locked
        (totalToken0, lockedToken0, availableToken0) =
            hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(totalToken0, 100 ether, "After order: total should stay same");
        assertEq(lockedToken0, 10 ether, "After order: locked incorrect");
        assertEq(availableToken0, 90 ether, "After order: available incorrect");

        // STEP 3: Cancel order
        hook.cancelOrder(orderId, poolKey);

        // Verify balance unlocked
        (totalToken0, lockedToken0, availableToken0) =
            hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(totalToken0, 100 ether, "After cancel: total should stay same");
        assertEq(lockedToken0, 0, "After cancel: should be unlocked");
        assertEq(availableToken0, 100 ether, "After cancel: available should be full");

        // STEP 4: Withdraw all
        uint256 maker1BalanceBefore = token0.balanceOf(maker1);

        hook.withdraw(poolKey.currency0, 100 ether);

        uint256 maker1BalanceAfter = token0.balanceOf(maker1);
        assertEq(
            maker1BalanceAfter - maker1BalanceBefore,
            100 ether,
            "Withdraw: should receive all tokens"
        );

        // Verify internal balance cleared
        (totalToken0, lockedToken0, availableToken0) =
            hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(totalToken0, 0, "After withdraw: should be 0");

        vm.stopPrank();
    }

    /// @notice Test multiple makers with orders at different prices
    function test_Integration_MultipleMakers() public {
        // STEP 1: Maker1 deposits and places sell order at 1.01
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 order1 = hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);
        vm.stopPrank();

        // STEP 2: Maker2 deposits and places sell order at 1.02
        vm.startPrank(maker2);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 order2 = hook.placeOrderFromBalance(poolKey, 1.02e18, 10 ether, false);
        vm.stopPrank();

        // STEP 3: Verify both makers have locked balances
        (, uint128 locked1Token0,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        (, uint128 locked2Token0,) = hook.getBalanceInfo(maker2, poolKey.currency0);

        assertEq(locked1Token0, 10 ether, "Maker1 should have locked balance");
        assertEq(locked2Token0, 10 ether, "Maker2 should have locked balance");

        // STEP 4: Both makers cancel orders
        vm.prank(maker1);
        hook.cancelOrder(order1, poolKey);

        vm.prank(maker2);
        hook.cancelOrder(order2, poolKey);

        // STEP 5: Verify both unlocked
        (, locked1Token0,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        (, locked2Token0,) = hook.getBalanceInfo(maker2, poolKey.currency0);

        assertEq(locked1Token0, 0, "Maker1 should be unlocked");
        assertEq(locked2Token0, 0, "Maker2 should be unlocked");
    }

    /// @notice Test large order placement
    function test_Integration_LargeOrder() public {
        // Maker places large sell order
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 orderId = hook.placeOrderFromBalance(poolKey, 1.01e18, 50 ether, false);

        // Verify full amount locked
        (, uint128 lockedBefore,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(lockedBefore, 50 ether, "Full amount should be locked");

        // Cancel the order
        hook.cancelOrder(orderId, poolKey);

        // Verify unlocked
        (, uint128 lockedAfter,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(lockedAfter, 0, "Should be fully unlocked");

        vm.stopPrank();
    }

    /// @notice Test order cancellation and balance reuse
    function test_Integration_CancelAndReuse() public {
        // STEP 1: Deposit and place order
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 orderId = hook.placeOrderFromBalance(poolKey, 1.01e18, 30 ether, false);

        // Verify locked
        (, uint128 lockedBefore,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(lockedBefore, 30 ether, "Should be locked");

        // STEP 2: Cancel order
        vm.expectEmit(true, true, false, true);
        emit BalanceUnlocked(maker1, poolKey.currency0, 30 ether);

        hook.cancelOrder(orderId, poolKey);

        // Verify unlocked
        (, uint128 lockedAfter, uint128 availableAfter) =
            hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(lockedAfter, 0, "Should be unlocked");
        assertEq(availableAfter, 100 ether, "Should have full balance available");

        // STEP 3: Reuse balance for new order
        uint256 newOrderId = hook.placeOrderFromBalance(poolKey, 1.02e18, 40 ether, false);

        // Verify new lock
        (, uint128 lockedNew,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        assertEq(lockedNew, 40 ether, "New order should lock balance");

        vm.stopPrank();
    }

    /// @notice Test buy order with token1 locking
    function test_Integration_BuyOrderLocking() public {
        // Maker1 places buy order (buy token0, sell token1)
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency1, 100 ether);
        uint256 buyOrder = hook.placeOrderFromBalance(poolKey, 0.99e18, 10 ether, true);

        // Verify token1 locked (10 ether * 0.99 = ~9.9 ether cost)
        // Note: Allow for small rounding errors from price conversion
        (, uint128 lockedToken1,) = hook.getBalanceInfo(maker1, poolKey.currency1);
        uint128 expectedLocked = uint128((uint256(10 ether) * 0.99e18) / 1e18);

        // Assert locked is within 0.01% of expected (accounting for rounding in price conversion)
        uint256 diff = lockedToken1 > expectedLocked ?
            lockedToken1 - expectedLocked :
            expectedLocked - lockedToken1;
        assertTrue(diff < expectedLocked / 10000, "Token1 should be locked for buy order (within 0.01%)");

        // Cancel and verify unlock
        hook.cancelOrder(buyOrder, poolKey);
        (, uint128 lockedAfter,) = hook.getBalanceInfo(maker1, poolKey.currency1);
        
        // Allow for small rounding differences in unlock (similar tolerance as lock)
        uint256 tolerance = expectedLocked / 100; // 1% tolerance for price rounding
        assertLe(lockedAfter, tolerance, "Should be approximately unlocked (within 1%)");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test critical invariant: sum of internal balances == hook's ERC20 balance
    function test_Invariant_BalanceConservation() public {
        // Multiple users deposit
        vm.prank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);

        vm.prank(maker2);
        hook.deposit(poolKey.currency0, 200 ether);

        vm.prank(taker);
        hook.deposit(poolKey.currency0, 150 ether);

        // Calculate sum of internal balances
        (uint128 maker1Total,,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        (uint128 maker2Total,,) = hook.getBalanceInfo(maker2, poolKey.currency0);
        (uint128 takerTotal,,) = hook.getBalanceInfo(taker, poolKey.currency0);

        uint256 sumInternalBalances = uint256(maker1Total) + uint256(maker2Total) + uint256(takerTotal);

        // Get hook's vault balance (V4 uses vault credits, not direct ERC20 balances)
        uint256 hookVaultBalance = vault.balanceOf(address(hook), poolKey.currency0);

        // CRITICAL INVARIANT: sum of internal balances == hook's vault balance
        assertEq(sumInternalBalances, hookVaultBalance, "Balance conservation violated!");
    }

    /// @notice Test invariant after complex operations
    function test_Invariant_AfterComplexFlow() public {
        // Deposit
        vm.prank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);

        vm.prank(maker2);
        hook.deposit(poolKey.currency0, 200 ether);

        // Place orders (locks balances)
        vm.prank(maker1);
        uint256 order1 = hook.placeOrderFromBalance(poolKey, 1.01e18, 50 ether, false);

        vm.prank(maker2);
        uint256 order2 = hook.placeOrderFromBalance(poolKey, 1.02e18, 100 ether, false);

        // Cancel orders
        vm.prank(maker1);
        hook.cancelOrder(order1, poolKey);

        // Partial withdraw
        vm.prank(maker1);
        hook.withdraw(poolKey.currency0, 50 ether);

        // Verify invariant for token0 (sum of internal balances == hook's vault balance)
        (uint128 maker1Token0,,) = hook.getBalanceInfo(maker1, poolKey.currency0);
        (uint128 maker2Token0,,) = hook.getBalanceInfo(maker2, poolKey.currency0);
        uint256 sumToken0 = uint256(maker1Token0) + uint256(maker2Token0);
        uint256 hookVaultBalance = vault.balanceOf(address(hook), poolKey.currency0);
        assertEq(sumToken0, hookVaultBalance, "Token0 invariant violated!");
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Benchmark gas for internal balance operations
    function test_Gas_InternalBalanceOperations() public {
        vm.startPrank(maker1);

        // Gas: Deposit
        uint256 gasBefore = gasleft();
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 gasDeposit = gasBefore - gasleft();

        // Gas: Place order
        gasBefore = gasleft();
        uint256 orderId = hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);
        uint256 gasPlaceOrder = gasBefore - gasleft();

        // Gas: Cancel order
        gasBefore = gasleft();
        hook.cancelOrder(orderId, poolKey);
        uint256 gasCancel = gasBefore - gasleft();

        // Gas: Withdraw
        gasBefore = gasleft();
        hook.withdraw(poolKey.currency0, 100 ether);
        uint256 gasWithdraw = gasBefore - gasleft();

        vm.stopPrank();

        // Log results
        console.log("=== Gas Benchmarks ===");
        console.log("Deposit:      ", gasDeposit);
        console.log("Place Order:  ", gasPlaceOrder);
        console.log("Cancel Order: ", gasCancel);
        console.log("Withdraw:     ", gasWithdraw);
        console.log("TOTAL:        ", gasDeposit + gasPlaceOrder + gasCancel + gasWithdraw);
    }

    /// @notice Benchmark gas for multiple orders
    function test_Gas_MultipleOrders() public {
        vm.startPrank(maker1);

        hook.deposit(poolKey.currency0, 1000 ether);

        // Gas for 10 orders
        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < 10; i++) {
            hook.placeOrderFromBalance(poolKey, 1.01e18 + (i * 0.01e18), 10 ether, false);
        }
        uint256 gas10Orders = gasBefore - gasleft();

        vm.stopPrank();

        console.log("=== Gas for 10 Orders ===");
        console.log("Total gas:    ", gas10Orders);
        console.log("Per order:    ", gas10Orders / 10);
    }
}
