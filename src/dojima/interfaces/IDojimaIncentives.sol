// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title IDojimaIncentives
/// @notice Interface for the DojimaIncentives contract
interface IDojimaIncentives {

    /*//////////////////////////////////////////////////////////////
                        POOL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure incentives for a pool
    function configurePool(
        PoolId poolId,
        uint32 twavWindow,
        int24 activeTickRange,
        uint256 decayFactor,
        uint256 optimalSpreadTicks,
        uint256 rewardPerSec
    ) external;

    /// @notice Update emission rate for a pool
    function updateEmissionRate(PoolId poolId, uint256 newRate) external;

    /// @notice Disable incentives for a pool
    function deactivatePool(PoolId poolId) external;

    /*//////////////////////////////////////////////////////////////
                        POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add AMM liquidity position
    function addAMMPosition(
        PoolId poolId,
        address user,
        uint128 liquidity
    ) external;

    /// @notice Remove AMM liquidity position
    function removeAMMPosition(
        PoolId poolId,
        address user,
        uint128 liquidity
    ) external;

    /// @notice Add limit order for incentives
    function addLimitOrder(
        PoolId poolId,
        uint256 orderId,
        address maker,
        int24 tick,
        int24 currentTick,
        uint128 liquidity
    ) external;

    /// @notice Remove limit order from incentives
    function removeLimitOrder(PoolId poolId, uint256 orderId) external;

    /*//////////////////////////////////////////////////////////////
                        REWARD CLAIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all rewards for a user in a pool
    function claimRewards(PoolId poolId) external;

    /// @notice Claim rewards for a user (hook can call this)
    function claimRewardsFor(PoolId poolId, address user) external;

    /*//////////////////////////////////////////////////////////////
                        WEIGHT CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate weight for a limit order based on spread
    function calculateLimitOrderWeight(
        PoolId poolId,
        int24 orderTick,
        int24 currentTick,
        uint128 liquidity
    ) external view returns (uint256 weight, bool isActive);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending rewards for a user
    function pendingRewards(PoolId poolId, address user) external view returns (uint256 totalPending);
}
