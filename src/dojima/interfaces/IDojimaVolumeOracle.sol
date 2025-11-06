// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title IDojimaVolumeOracle
/// @notice Interface for the DojimaVolumeOracle contract
interface IDojimaVolumeOracle {

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VolumeObservation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint256 ammVolumeCumulative;
        uint256 limitOrderVolumeCumulative;
        bool initialized;
    }

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    struct TWAVResult {
        uint256 ammVolumeRate;        // AMM volume per second
        uint256 limitOrderVolumeRate; // Limit order volume per second
        uint16 ammShareBps;           // AMM share in basis points (0-10000)
        uint16 limitOrderShareBps;    // Limit order share in basis points (0-10000)
        uint32 timeWindow;            // Time window used for calculation
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the oracle for a new pool
    function initialize(PoolId poolId, int24 tick) external returns (uint16 cardinality, uint16 cardinalityNext);

    /// @notice Record a new volume observation
    function write(
        PoolId poolId,
        int24 tick,
        uint256 volumeInQuote,
        bool isLimitOrder
    ) external returns (uint16 indexUpdated, uint16 cardinalityUpdated);

    /// @notice Get Time-Weighted Average Volume over a time window
    function getTWAV(PoolId poolId, uint32 secondsAgo) external view returns (TWAVResult memory result);

    /// @notice Increase the cardinality target for the observations array
    function increaseCardinalityNext(PoolId poolId, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the current observation state for a pool
    function getState(PoolId poolId) external view returns (ObservationState memory state);

    /// @notice Get a specific observation
    function getObservation(PoolId poolId, uint256 index) external view returns (VolumeObservation memory observation);
}
