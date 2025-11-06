// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {MockERC20} from "../utils/Setup.sol";

/// @title Gas Benchmark Comparison Test
/// @notice Comprehensive gas benchmarks comparing AMM vs CLOB vs Hybrid execution
contract GasBenchmarkComparison is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;
    using BalanceDeltaLibrary for BalanceDelta;

    // Contracts
    DojimaHybridHook hook;
    ICLPoolManager poolManager;
    IVault vault;
    MockERC20 token0;
    MockERC20 token1;

    // Pool
    PoolKey poolKey;
    PoolId poolId;

    // Test users
    address maker1;
    address maker2;
    address taker;
    address liquidityProvider;

    // Constants
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Callback action types
    enum CallbackAction {
        Swap,
        ModifyLiquidity
    }

    struct CallbackData {
        CallbackAction action;
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams swapParams;
        ICLPoolManager.ModifyLiquidityParams modifyLiquidityParams;
    }

    function setUp() public {
        // Fork RISE testnet
        vm.createSelectFork("https://testnet.riselabs.xyz/");

        // Get deployed contracts
        poolManager = ICLPoolManager(0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f);
        vault = IVault(poolManager.vault());

        // Deploy tokens
        token0 = new MockERC20("Test Token 0", "TK0", 18);
        token1 = new MockERC20("Test Token 1", "TK1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy hook
        hook = new DojimaHybridHook(poolManager);

        // Create pool
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

        // Initialize pool
        poolManager.initialize(poolKey, 79228162514264337593543950336); // price = 1.0

        // Setup users
        maker1 = makeAddr("maker1");
        maker2 = makeAddr("maker2");
        taker = makeAddr("taker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Mint tokens
        token0.mint(maker1, 1000 ether);
        token1.mint(maker1, 1000 ether);
        token0.mint(maker2, 1000 ether);
        token1.mint(maker2, 1000 ether);
        token0.mint(taker, 1000 ether);
        token1.mint(taker, 1000 ether);
        token0.mint(liquidityProvider, 10000 ether);
        token1.mint(liquidityProvider, 10000 ether);

        // Approvals
        vm.prank(maker1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker1);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(maker2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker2);
        token1.approve(address(hook), type(uint256).max);
        vm.prank(taker);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(taker);
        token1.approve(address(vault), type(uint256).max);
        vm.prank(liquidityProvider);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(liquidityProvider);
        token1.approve(address(vault), type(uint256).max);

        // Add AMM liquidity
        _addLiquidity(liquidityProvider, -600, 600, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Comprehensive gas comparison table
    function test_Gas_ComparisonTable() public {
        console.log("");
        console.log("========================================");
        console.log("      GAS BENCHMARK COMPARISON");
        console.log("========================================");
        console.log("");
        console.log("Operation                      Gas Used    Delta vs AMM");
        console.log("-----------------------------------------------------------");

        // Pure AMM baseline
        uint256 gasAMM = _benchmarkPureAMM();
        console.log("Pure AMM Swap:                ", gasAMM);

        // Hybrid (1 order)
        uint256 gasHybrid1 = _benchmarkHybrid(1);
        int256 delta1 = int256(gasHybrid1) - int256(gasAMM);
        console.log("Hybrid (1 order):             ", gasHybrid1);
        console.log("  Delta vs AMM:               ", uint256(delta1 > 0 ? delta1 : -delta1));

        // Hybrid (3 orders)
        uint256 gasHybrid3 = _benchmarkHybrid(3);
        int256 delta3 = int256(gasHybrid3) - int256(gasAMM);
        console.log("Hybrid (3 orders):            ", gasHybrid3);
        console.log("  Delta vs AMM:               ", uint256(delta3 > 0 ? delta3 : -delta3));

        // Hybrid (5 orders)
        uint256 gasHybrid5 = _benchmarkHybrid(5);
        int256 delta5 = int256(gasHybrid5) - int256(gasAMM);
        console.log("Hybrid (5 orders):            ", gasHybrid5);
        console.log("  Delta vs AMM:               ", uint256(delta5 > 0 ? delta5 : -delta5));

        // Hybrid (10 orders)
        uint256 gasHybrid10 = _benchmarkHybrid(10);
        int256 delta10 = int256(gasHybrid10) - int256(gasAMM);
        console.log("Hybrid (10 orders):           ", gasHybrid10);
        console.log("  Delta vs AMM:               ", uint256(delta10 > 0 ? delta10 : -delta10));

        console.log("-----------------------------------------------------------");

        // Calculate overhead and marginal costs
        uint256 overhead = gasHybrid1 - gasAMM;
        uint256 overheadPct = (overhead * 100) / gasAMM;
        console.log("");
        console.log("Hybrid Overhead (1 order):    ", overhead);
        console.log("  Overhead percentage:        ", overheadPct, "%");

        uint256 marginal3 = (gasHybrid3 - gasHybrid1) / 2;
        console.log("Marginal cost per order (1-3):", marginal3);

        uint256 marginal10 = (gasHybrid10 - gasHybrid5) / 5;
        console.log("Marginal cost per order (5-10):", marginal10);

        console.log("");
        console.log("========================================");
        console.log("");
    }

    /// @notice Detailed operation breakdown
    function test_Gas_OperationBreakdown() public {
        console.log("");
        console.log("========================================");
        console.log("    OPERATION GAS BREAKDOWN");
        console.log("========================================");
        console.log("");

        // Deposit
        uint256 gasDeposit = _benchmarkDeposit();
        console.log("Deposit (internal balance):   ", gasDeposit, "gas");

        // Place Order
        uint256 gasPlaceOrder = _benchmarkPlaceOrder();
        console.log("Place Limit Order:            ", gasPlaceOrder, "gas");

        // Cancel Order
        uint256 gasCancelOrder = _benchmarkCancelOrder();
        console.log("Cancel Order:                 ", gasCancelOrder, "gas");

        // Withdraw
        uint256 gasWithdraw = _benchmarkWithdraw();
        console.log("Withdraw (internal balance):  ", gasWithdraw, "gas");

        console.log("");
        console.log("========================================");
        console.log("");
    }

    /// @notice Scaling analysis
    function test_Gas_ScalingAnalysis() public {
        console.log("");
        console.log("========================================");
        console.log("      SCALING ANALYSIS");
        console.log("========================================");
        console.log("");
        console.log("Orders Matched    Gas Used    Gas/Order");
        console.log("-------------------------------------------");

        uint256[] memory orderCounts = new uint256[](6);
        orderCounts[0] = 1;
        orderCounts[1] = 2;
        orderCounts[2] = 5;
        orderCounts[3] = 10;
        orderCounts[4] = 15;
        orderCounts[5] = 20;

        for (uint i = 0; i < orderCounts.length; i++) {
            uint256 gasUsed = _benchmarkHybrid(orderCounts[i]);
            uint256 gasPerOrder = gasUsed / orderCounts[i];
            console.log("Orders:", orderCounts[i]);
            console.log("  Total gas:", gasUsed);
            console.log("  Gas per order:", gasPerOrder);
            console.log("");
        }

        console.log("");
        console.log("========================================");
        console.log("");
    }

    /*//////////////////////////////////////////////////////////////
                        BENCHMARK HELPERS
    //////////////////////////////////////////////////////////////*/

    function _benchmarkPureAMM() internal returns (uint256) {
        // Setup: No orders, pure AMM
        uint256 gasBefore = gasleft();
        _swapExactInput(taker, false, 3 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Reset state
        vm.roll(block.number + 1);

        return gasUsed;
    }

    function _benchmarkHybrid(uint256 numOrders) internal returns (uint256) {
        // Setup: Place orders
        for (uint i = 0; i < numOrders; i++) {
            address maker = i % 2 == 0 ? maker1 : maker2;
            uint256 price = 1.01e18 + (i * 0.001e18); // Slightly increasing prices

            vm.startPrank(maker);
            hook.deposit(poolKey.currency0, 100 ether);
            hook.placeOrderFromBalance(poolKey, price, 1 ether, false);
            vm.stopPrank();
        }

        // Benchmark: Swap that matches orders
        uint256 gasBefore = gasleft();
        _swapExactInput(taker, false, 3 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Reset state
        vm.roll(block.number + 1);

        return gasUsed;
    }

    function _benchmarkDeposit() internal returns (uint256) {
        vm.startPrank(maker1);
        uint256 gasBefore = gasleft();
        hook.deposit(poolKey.currency0, 10 ether);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        return gasUsed;
    }

    function _benchmarkPlaceOrder() internal returns (uint256) {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 gasBefore = gasleft();
        hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        return gasUsed;
    }

    function _benchmarkCancelOrder() internal returns (uint256) {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        uint256 orderId = hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);

        uint256 gasBefore = gasleft();
        hook.cancelOrder(orderId, poolKey);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        return gasUsed;
    }

    function _benchmarkWithdraw() internal returns (uint256) {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 10 ether);

        uint256 gasBefore = gasleft();
        hook.withdraw(poolKey.currency0, 5 ether);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        return gasUsed;
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _swapExactInput(address user, bool zeroForOne, uint256 amountIn) internal {
        vm.startPrank(user);

        CallbackData memory data = CallbackData({
            action: CallbackAction.Swap,
            sender: user,
            key: poolKey,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            modifyLiquidityParams: ICLPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 0,
                liquidityDelta: 0,
                salt: bytes32(0)
            })
        });

        vault.lock(abi.encode(data));
        vm.stopPrank();
    }

    function _addLiquidity(address user, int24 tickLower, int24 tickUpper, uint256 amount) internal {
        vm.startPrank(user);

        CallbackData memory data = CallbackData({
            action: CallbackAction.ModifyLiquidity,
            sender: user,
            key: poolKey,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0,
                sqrtPriceLimitX96: 0
            }),
            modifyLiquidityParams: ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount),
                salt: bytes32(0)
            })
        });

        vault.lock(abi.encode(data));
        vm.stopPrank();
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(vault), "Only vault");

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.action == CallbackAction.Swap) {
            BalanceDelta delta = poolManager.swap(data.key, data.swapParams, "");
            _settleDeltas(data.sender, data.key, delta);
            return abi.encode(delta);
        } else if (data.action == CallbackAction.ModifyLiquidity) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.modifyLiquidityParams, "");
            _settleDeltas(data.sender, data.key, delta);
            return abi.encode(delta);
        }

        revert("Unknown action");
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) {
            _settle(key.currency0, sender, uint128(-delta0));
        }
        if (delta0 > 0) {
            _take(key.currency0, sender, uint128(delta0));
        }
        if (delta1 < 0) {
            _settle(key.currency1, sender, uint128(-delta1));
        }
        if (delta1 > 0) {
            _take(key.currency1, sender, uint128(delta1));
        }
    }

    /// @notice Settle a debt to the vault
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        vault.sync(currency);

        MockERC20 token = MockERC20(Currency.unwrap(currency));

        // Transfer from payer to vault
        if (payer == address(this)) {
            token.transfer(address(vault), amount);
        } else {
            vm.prank(payer);
            token.transfer(address(vault), amount);
        }

        vault.settle();
    }

    /// @notice Take tokens from vault
    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        vault.take(currency, recipient, amount);
    }
}
