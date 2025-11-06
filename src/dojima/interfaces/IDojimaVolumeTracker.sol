// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title IDojimaVolumeTracker
/// @notice Interface for the DojimaVolumeTracker contract
interface IDojimaVolumeTracker {

    /*//////////////////////////////////////////////////////////////
                        VOLUME TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Record volume for a user
    function recordVolume(address user, PoolId poolId, uint256 volumeInQuote) external;

    /*//////////////////////////////////////////////////////////////
                        REBATE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get maker rebate for a user based on their 30-day volume
    function getMakerRebate(address user) external view returns (uint256 rebateBps);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's volume statistics
    function getUserStats(address user)
        external
        view
        returns (
            uint256 totalVolume,
            uint256 volume30Day,
            uint256 currentRebate,
            uint256 nextTierVolume,
            uint256 nextTierRebate
        );
}
