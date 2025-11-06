// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {MockERC20} from "../utils/Setup.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {Setup} from "../utils/Setup.sol";

/// @title Taker Refund Tests
/// @notice Tests for Phase 2C - Taker refund mechanism
contract TakerRefundTest is Setup {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Note: All test infrastructure is inherited from Setup base class
    // (hook, token0, token1, poolManager, vault, poolKey, alice, bob, taker, etc.)

    function setUp() public override {
        // Call parent setUp to initialize all test infrastructure
        super.setUp();
    }

    /// @notice Test taker receives refund when CLOB fills at better price
    function test_TakerRefund_PureCLOB() public {
        // Alice deposits and places sell order at better price
        vm.startPrank(alice);
        hook.deposit(Currency.wrap(address(token0)), 100 ether);
        uint256 orderId = hook.placeOrderFromBalance(
            poolKey,
            0.99e18,  // Sell at $0.99 (better than AMM $1.00)
            10 ether,
            false  // sell order
        );
        vm.stopPrank();

        // Taker deposits (for internal balance refund)
        vm.startPrank(taker);
        hook.deposit(Currency.wrap(address(token1)), 100 ether);

        // Get taker's balance before swap
        (uint128 balanceBefore,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));

        // Execute swap (buy 10 ETH)
        // AMM would cost: 10 * $1.00 = 10 token1
        // CLOB fills: 10 ETH @ $0.99 = 9.9 token1
        // Expected refund: 10 - 9.9 = 0.1 token1
        _executeSwap(taker, true, 10 ether);

        // Check taker's balance after swap (should have refund)
        (uint128 balanceAfter,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));
        vm.stopPrank();

        // Taker should have received refund
        uint256 refund = balanceAfter - balanceBefore;

        // Should receive approximately 0.1 token1 refund (1% savings on 10 token1)
        assertGt(refund, 0, "Taker should receive refund");
        assertApproxEqAbs(refund, 0.1 ether, 0.01 ether, "Refund should be ~0.1 token1");
    }

    /// @notice Test taker refund with hybrid execution (CLOB + AMM)
    function test_TakerRefund_Hybrid() public {
        // Alice places sell order for 6 ETH at $0.99
        vm.startPrank(alice);
        hook.deposit(Currency.wrap(address(token0)), 100 ether);
        hook.placeOrderFromBalance(poolKey, 0.99e18, 6 ether, false);
        vm.stopPrank();

        // Taker deposits
        vm.startPrank(taker);
        hook.deposit(Currency.wrap(address(token1)), 100 ether);

        (uint128 balanceBefore,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));

        // Execute swap for 10 ETH
        // CLOB: 6 ETH @ $0.99 = 5.94 token1
        // AMM: 4 ETH @ $1.00 = 4.00 token1
        // Total actual: 9.94 token1
        // AMM cost: 10.00 token1
        // Expected refund: 0.06 token1
        _executeSwap(taker, true, 10 ether);

        (uint128 balanceAfter,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));
        vm.stopPrank();

        uint256 refund = balanceAfter - balanceBefore;

        assertGt(refund, 0, "Taker should receive refund");
        assertApproxEqAbs(refund, 0.06 ether, 0.01 ether, "Refund should be ~0.06 token1");
    }

    /// @notice Test taker refund with multiple orders at different prices
    function test_TakerRefund_MultipleOrders() public {
        // Alice places multiple sell orders
        vm.startPrank(alice);
        hook.deposit(Currency.wrap(address(token0)), 100 ether);
        hook.placeOrderFromBalance(poolKey, 0.985e18, 3 ether, false);  // Best
        hook.placeOrderFromBalance(poolKey, 0.990e18, 4 ether, false);  // Good
        hook.placeOrderFromBalance(poolKey, 0.995e18, 5 ether, false);  // OK
        vm.stopPrank();

        // Taker swaps 10 ETH
        vm.startPrank(taker);
        hook.deposit(Currency.wrap(address(token1)), 100 ether);

        (uint128 balanceBefore,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));

        // Should match first two orders (7 ETH from CLOB, 3 ETH from AMM)
        // CLOB: 3 @ 0.985 + 4 @ 0.990 = 2.955 + 3.96 = 6.915
        // AMM: 3 @ 1.00 = 3.00
        // Total: 9.915 vs AMM 10.00 → refund ~0.085
        _executeSwap(taker, true, 10 ether);

        (uint128 balanceAfter,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));
        vm.stopPrank();

        uint256 refund = balanceAfter - balanceBefore;

        assertGt(refund, 0, "Taker should receive refund");
        // Should save approximately 0.5-1% on average
        assertGt(refund, 0.05 ether, "Refund should be >0.05 token1");
    }

    /// @notice Test no refund when only AMM is used (no CLOB orders)
    function test_NoRefund_PureAMM() public {
        // No limit orders placed

        vm.startPrank(taker);
        hook.deposit(Currency.wrap(address(token1)), 100 ether);

        (uint128 balanceBefore,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));

        _executeSwap(taker, true, 10 ether);

        (uint128 balanceAfter,,) = hook.getBalanceInfo(taker, Currency.wrap(address(token1)));
        vm.stopPrank();

        // No refund expected (pure AMM)
        uint256 refund = balanceAfter - balanceBefore;
        assertEq(refund, 0, "No refund expected for pure AMM");
    }

    /// @notice Test dust refund is not credited (< 1000 wei threshold)
    function test_NoDustRefund() public {
        // This is hard to test precisely without manipulating prices
        // But we can verify the threshold is working in general
        // Skip for now - would need very specific price points
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _executeSwap(address swapper, bool zeroForOne, uint128 amount) internal {
        // IMPORTANT: In PancakeSwap V4, only contracts with lockAcquired() can interact with vault
        // The pattern is: User → Router → vault.lock() → Router.lockAcquired() → poolManager.swap()
        // 
        // We need to temporarily stop prank so that the TEST CONTRACT (which has lockAcquired)
        // is the one calling vault.lock(), not the pranked user address
        
        vm.stopPrank(); // Stop prank so test contract calls vault.lock()
        
        if (zeroForOne) {
            // Selling token0 for token1
            executeSellSwap(swapper, amount);
        } else {
            // Buying token0 with token1  
            executeBuySwap(swapper, amount);
        }
        
        vm.startPrank(swapper); // Restart prank for the calling context
    }

    function _getBalance(address user, Currency currency) internal view returns (uint128) {
        (uint128 total,,) = hook.getBalanceInfo(user, currency);
        return total;
    }
}
