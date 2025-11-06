// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/// @title IDojimaRouter
/// @notice Interface for custom routing through CLOB and AMM
/// @dev Allows users to specify routing preferences
interface IDojimaRouter {
    /// @notice Routing parameters for hybrid execution
    struct RouteParams {
        uint128 totalAmount;      // Total amount to swap
        uint128 maxCLOBAmount;    // Max to route through CLOB (0 = no limit)
        uint128 minCLOBAmount;    // Min to route through CLOB
        uint256 maxPriceImpact;   // Max acceptable price impact (basis points)
        bool preferCLOB;          // Prefer CLOB over AMM when equal
        bool allowPartialFill;    // Allow partial CLOB fills
    }

    /// @notice Result of routing calculation
    struct RouteResult {
        uint128 clobAmount;       // Amount routed through CLOB
        uint128 ammAmount;        // Amount routed through AMM
        uint256 avgExecutionPrice;// Volume-weighted average price
        uint256 priceImprovement; // Basis points better than pure AMM
        uint256 gasEstimate;      // Estimated gas for execution
    }

    /// @notice Execution summary after swap
    struct ExecutionSummary {
        uint128 clobFilled;       // Actual amount filled via CLOB
        uint128 ammFilled;        // Actual amount filled via AMM
        uint256 avgPrice;         // Actual average execution price
        uint256 gasUsed;          // Actual gas used
        uint256 makerRebates;     // Total rebates to makers
        uint256[] filledOrderIds; // Orders that were filled
    }

    /// @notice Calculate optimal routing without executing
    /// @param key Pool key
    /// @param params Swap parameters
    /// @param routeParams Routing preferences
    /// @return result Optimal routing split
    function calculateRoute(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        RouteParams calldata routeParams
    ) external view returns (RouteResult memory result);

    /// @notice Execute swap with custom routing
    /// @param key Pool key
    /// @param params Swap parameters  
    /// @param routeParams Routing preferences
    /// @return delta Balance changes
    /// @return summary Execution details
    function swapWithRoute(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        RouteParams calldata routeParams
    ) external returns (BalanceDelta delta, ExecutionSummary memory summary);

    /// @notice Get current market depth for routing decisions
    /// @param key Pool key
    /// @param isBuy True if buying token0
    /// @param maxPriceDeviation Max price deviation from mid (basis points)
    /// @return depth Available liquidity within price range
    function getMarketDepth(
        PoolKey calldata key,
        bool isBuy,
        uint256 maxPriceDeviation
    ) external view returns (uint256 depth);

    /// @notice Simulate swap execution
    /// @param key Pool key
    /// @param params Swap parameters
    /// @param routeParams Routing preferences
    /// @return result Expected execution result
    function simulateSwap(
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        RouteParams calldata routeParams
    ) external view returns (RouteResult memory result);
}