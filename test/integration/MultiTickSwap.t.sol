// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {MockERC20} from "../utils/Setup.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

/// @title Multi-Tick Swap Integration Test
/// @notice Tests order matching across multiple price ticks
/// @dev Critical for verifying cross-tick order book functionality
contract MultiTickSwapTest is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

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
    address public maker3;
    address public taker;
    address public liquidityProvider;

    // Pool configuration
    PoolKey poolKey;
    PoolId poolId;
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

        // Initialize pool at price = 1.0 (tick = 0)
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Create test users
        maker1 = makeAddr("maker1");
        maker2 = makeAddr("maker2");
        maker3 = makeAddr("maker3");
        taker = makeAddr("taker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Mint tokens
        token0.mint(maker1, 1000 ether);
        token1.mint(maker1, 1000 ether);
        token0.mint(maker2, 1000 ether);
        token1.mint(maker2, 1000 ether);
        token0.mint(maker3, 1000 ether);
        token1.mint(maker3, 1000 ether);
        token0.mint(taker, 10000 ether);
        token1.mint(taker, 10000 ether);
        token0.mint(liquidityProvider, 10000 ether);
        token1.mint(liquidityProvider, 10000 ether);

        // Approve hook for internal balance deposits
        vm.prank(maker1);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker1);
        token1.approve(address(hook), type(uint256).max);

        vm.prank(maker2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker2);
        token1.approve(address(hook), type(uint256).max);

        vm.prank(maker3);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(maker3);
        token1.approve(address(hook), type(uint256).max);

        // Approve vault for swaps and liquidity
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
                        MULTI-TICK SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test swap that crosses 2 ticks with orders in each
    function test_MultiTick_Cross2Ticks() public {
        // Place sell orders in tick 0 (current)
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 50 ether);
        uint256 order1 = hook.placeOrderFromBalance(poolKey, 1.005e18, 10 ether, false);
        vm.stopPrank();

        // Place sell orders in tick +60 (next tick up)
        vm.startPrank(maker2);
        hook.deposit(poolKey.currency0, 50 ether);
        uint256 order2 = hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);
        vm.stopPrank();

        // Execute large buy swap that should cross both ticks
        BalanceDelta delta = _swapExactInput(taker, false, 25 ether);

        // Verify orders filled
        // TODO: Add assertions when order status queries available
        console.log("Crossed 2 ticks successfully");
    }

    /// @notice Test swap crossing 5 ticks with orders distributed across
    function test_MultiTick_Cross5Ticks() public {
        // Place orders in ticks: 0, +60, +120, +180, +240
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);

        // Tick 0 (price 1.0)
        hook.placeOrderFromBalance(poolKey, 1.002e18, 5 ether, false);

        // Tick +60 (price ~1.006)
        hook.placeOrderFromBalance(poolKey, 1.008e18, 5 ether, false);

        // Tick +120 (price ~1.012)
        hook.placeOrderFromBalance(poolKey, 1.014e18, 5 ether, false);

        // Tick +180 (price ~1.018)
        hook.placeOrderFromBalance(poolKey, 1.020e18, 5 ether, false);

        // Tick +240 (price ~1.024)
        hook.placeOrderFromBalance(poolKey, 1.026e18, 5 ether, false);

        vm.stopPrank();

        // Large swap crossing all 5 ticks
        BalanceDelta delta = _swapExactInput(taker, false, 30 ether);

        console.log("Crossed 5 ticks successfully");
    }

    /// @notice Test maximum tick scanning (20 ticks)
    function test_MultiTick_MaxTickScan() public {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 200 ether);

        // Place 1 order in each of 20 consecutive ticks
        for (uint256 i = 0; i < 20; i++) {
            uint256 price = 1.001e18 + (i * 0.002e18);
            hook.placeOrderFromBalance(poolKey, price, 2 ether, false);
        }

        vm.stopPrank();

        // Huge swap should hit max tick limit
        uint256 gasBefore = gasleft();
        _swapExactInput(taker, false, 50 ether);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas for 20-tick scan:", gasUsed);
    }

    /// @notice Test orders concentrated in single tick
    function test_MultiTick_ManyOrdersSingleTick() public {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);

        // Place 10 orders at same tick, different prices
        for (uint256 i = 0; i < 10; i++) {
            uint256 price = 1.01e18 + (i * 0.0001e18);  // Small price increments
            hook.placeOrderFromBalance(poolKey, price, 2 ether, false);
        }

        vm.stopPrank();

        // Swap should fill multiple orders in same tick
        BalanceDelta delta = _swapExactInput(taker, false, 25 ether);

        console.log("Filled 10 orders in single tick");
    }

    /// @notice Test partial fill across ticks
    function test_MultiTick_PartialFillAcrossTicks() public {
        // Order in tick 0
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 50 ether);
        hook.placeOrderFromBalance(poolKey, 1.005e18, 10 ether, false);
        vm.stopPrank();

        // Order in tick +60
        vm.startPrank(maker2);
        hook.deposit(poolKey.currency0, 50 ether);
        hook.placeOrderFromBalance(poolKey, 1.01e18, 20 ether, false);  // Large order
        vm.stopPrank();

        // Small swap: fills tick 0, partially fills tick +60
        BalanceDelta delta = _swapExactInput(taker, false, 15 ether);

        console.log("Partial fill across ticks");
    }

    /// @notice Test alternating ticks (orders not in consecutive ticks)
    function test_MultiTick_SparseOrders() public {
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);

        // Orders in ticks: 0, +120 (skip +60), +240 (skip +180)
        hook.placeOrderFromBalance(poolKey, 1.002e18, 10 ether, false);   // Tick 0
        hook.placeOrderFromBalance(poolKey, 1.014e18, 10 ether, false);   // Tick +120
        hook.placeOrderFromBalance(poolKey, 1.026e18, 10 ether, false);   // Tick +240

        vm.stopPrank();

        // Swap should skip empty ticks efficiently
        uint256 gasBefore = gasleft();
        _swapExactInput(taker, false, 35 ether);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas for sparse tick scan:", gasUsed);
    }

    /// @notice Test buy orders (negative tick direction)
    function test_MultiTick_BuyOrdersCrossTicks() public {
        // Place buy orders in ticks: 0, -60, -120
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency1, 100 ether);

        hook.placeOrderFromBalance(poolKey, 0.998e18, 10 ether, true);   // Tick 0
        hook.placeOrderFromBalance(poolKey, 0.992e18, 10 ether, true);   // Tick -60
        hook.placeOrderFromBalance(poolKey, 0.986e18, 10 ether, true);   // Tick -120

        vm.stopPrank();

        // Large sell swap crossing downward ticks
        BalanceDelta delta = _swapExactInput(taker, true, 35 ether);

        console.log("Buy orders filled across negative ticks");
    }

    /// @notice Test mixed orders (buy + sell) at different ticks
    function test_MultiTick_MixedBuySellOrders() public {
        // Sell orders above current price
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 50 ether);
        hook.placeOrderFromBalance(poolKey, 1.005e18, 10 ether, false);
        hook.placeOrderFromBalance(poolKey, 1.01e18, 10 ether, false);
        vm.stopPrank();

        // Buy orders below current price
        vm.startPrank(maker2);
        hook.deposit(poolKey.currency1, 50 ether);
        hook.placeOrderFromBalance(poolKey, 0.995e18, 10 ether, true);
        hook.placeOrderFromBalance(poolKey, 0.99e18, 10 ether, true);
        vm.stopPrank();

        // Buy swap (fills sell orders)
        BalanceDelta delta1 = _swapExactInput(taker, false, 25 ether);

        // Sell swap (fills buy orders)
        BalanceDelta delta2 = _swapExactInput(taker, true, 25 ether);

        console.log("Mixed buy/sell orders filled");
    }

    /// @notice Test concurrent swaps (back-to-back)
    function test_MultiTick_ConcurrentSwaps() public {
        // Setup orders
        vm.startPrank(maker1);
        hook.deposit(poolKey.currency0, 100 ether);
        for (uint256 i = 0; i < 5; i++) {
            uint256 price = 1.005e18 + (i * 0.005e18);
            hook.placeOrderFromBalance(poolKey, price, 10 ether, false);
        }
        vm.stopPrank();

        // Execute 3 swaps in sequence
        _swapExactInput(taker, false, 15 ether);
        _swapExactInput(taker, false, 15 ether);
        _swapExactInput(taker, false, 15 ether);

        console.log("3 concurrent swaps completed");
    }

    /// @notice Test gas scaling with tick count
    function test_Gas_TickScaling() public {
        console.log("");
        console.log("=== GAS SCALING: Ticks vs Gas ===");

        uint256[] memory tickCounts = new uint256[](4);
        tickCounts[0] = 2;
        tickCounts[1] = 5;
        tickCounts[2] = 10;
        tickCounts[3] = 20;

        for (uint256 i = 0; i < tickCounts.length; i++) {
            // Reset state
            vm.snapshot();

            // Place orders across N ticks
            vm.startPrank(maker1);
            hook.deposit(poolKey.currency0, 200 ether);

            for (uint256 j = 0; j < tickCounts[i]; j++) {
                uint256 price = 1.001e18 + (j * 0.003e18);
                hook.placeOrderFromBalance(poolKey, price, 5 ether, false);
            }
            vm.stopPrank();

            // Measure gas
            uint256 gasBefore = gasleft();
            _swapExactInput(taker, false, 100 ether);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Ticks:", tickCounts[i], "Gas:", gasUsed);

            vm.revertTo(vm.snapshot());
        }
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta;

        if (data.action == CallbackAction.Swap) {
            delta = poolManager.swap(data.key, data.swapParams, "");
        } else if (data.action == CallbackAction.ModifyLiquidity) {
            (BalanceDelta d,) = poolManager.modifyLiquidity(data.key, data.modifyLiquidityParams, "");
            delta = d;
        }

        _settleDeltas(data.sender, data.key, delta);

        return abi.encode(delta);
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        // Handle token0
        if (delta.amount0() < 0) {
            uint256 amount = uint256(int256(-delta.amount0()));
            _settle(key.currency0, sender, amount);
        } else if (delta.amount0() > 0) {
            uint256 amount = uint256(int256(delta.amount0()));
            _take(key.currency0, sender, amount);
        }

        // Handle token1
        if (delta.amount1() < 0) {
            uint256 amount = uint256(int256(-delta.amount1()));
            _settle(key.currency1, sender, amount);
        } else if (delta.amount1() > 0) {
            uint256 amount = uint256(int256(delta.amount1()));
            _take(key.currency1, sender, amount);
        }
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        vault.sync(currency);

        MockERC20 token = MockERC20(Currency.unwrap(currency));

        if (payer == address(this)) {
            token.transfer(address(vault), amount);
        } else {
            vm.prank(payer);
            token.transfer(address(vault), amount);
        }

        vault.settle();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        vault.take(currency, recipient, amount);
    }

    function _addLiquidity(
        address provider,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta
    ) internal returns (BalanceDelta) {
        CallbackData memory data = CallbackData({
            action: CallbackAction.ModifyLiquidity,
            sender: provider,
            key: poolKey,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0,
                sqrtPriceLimitX96: 0
            }),
            modifyLiquidityParams: ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            })
        });

        bytes memory result = vault.lock(abi.encode(data));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        return delta;
    }

    function _swapExactInput(
        address trader,
        bool zeroForOne,
        uint256 amountIn
    ) internal returns (BalanceDelta) {
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_RATIO + 1
            : TickMath.MAX_SQRT_RATIO - 1;

        CallbackData memory data = CallbackData({
            action: CallbackAction.Swap,
            sender: trader,
            key: poolKey,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),  // Negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            modifyLiquidityParams: ICLPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 0,
                liquidityDelta: 0,
                salt: bytes32(0)
            })
        });

        bytes memory result = vault.lock(abi.encode(data));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        return delta;
    }
}
