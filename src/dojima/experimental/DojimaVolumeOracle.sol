// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title DojimaVolumeOracle
/// @notice Time-Weighted Average Volume (TWAV) oracle for tracking AMM vs limit order volume
/// @dev Implements observation-based tracking similar to Uniswap V3 oracle but for volume metrics
contract DojimaVolumeOracle {

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Volume observation for a specific point in time
    /// @dev Stores cumulative values to enable TWAV calculation over any time window
    struct VolumeObservation {
        uint32 blockTimestamp;              // Timestamp of observation
        int56 tickCumulative;                // Cumulative tick (for TWAP if needed)
        uint256 ammVolumeCumulative;         // Cumulative AMM volume in quote token
        uint256 limitOrderVolumeCumulative;  // Cumulative limit order volume in quote token
        bool initialized;                    // Whether observation has been initialized
    }

    /// @notice Current state of the observation array for a pool
    struct ObservationState {
        uint16 index;           // Index of most recent observation
        uint16 cardinality;     // Current number of populated observations
        uint16 cardinalityNext; // Target cardinality for automatic growth
    }

    /// @notice Result of TWAV calculation
    struct TWAVResult {
        uint256 ammVolumeRate;        // AMM volume per second
        uint256 limitOrderVolumeRate; // Limit order volume per second
        uint16 ammShareBps;           // AMM share in basis points (0-10000)
        uint16 limitOrderShareBps;    // Limit order share in basis points (0-10000)
        uint32 timeWindow;            // Time window used for calculation
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Circular buffer of observations for each pool
    mapping(PoolId => VolumeObservation[65535]) public observations;

    /// @notice Current state of observations for each pool
    mapping(PoolId => ObservationState) public states;

    /// @notice Authorized hook contract that can write observations
    address public immutable hookContract;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyHook();
    error InvalidTimestamp();
    error OracleNotInitialized();
    error InvalidSecondsAgo();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHook() {
        if (msg.sender != hookContract) revert OnlyHook();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _hookContract) {
        hookContract = _hookContract;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the oracle for a new pool
    /// @param poolId The pool ID to initialize
    /// @param tick The initial tick of the pool
    /// @return cardinality The initial cardinality (1)
    /// @return cardinalityNext The initial cardinality target (16)
    function initialize(PoolId poolId, int24 tick) external onlyHook returns (uint16 cardinality, uint16 cardinalityNext) {
        ObservationState storage state = states[poolId];
        if (state.cardinality != 0) return (state.cardinality, state.cardinalityNext);

        observations[poolId][0] = VolumeObservation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: int56(tick), // Initialize with current tick
            ammVolumeCumulative: 0,
            limitOrderVolumeCumulative: 0,
            initialized: true
        });

        state.cardinality = 1;
        state.cardinalityNext = 16; // Start with room for 16 observations

        return (1, 16);
    }

    /// @notice Record a new volume observation
    /// @param poolId The pool ID
    /// @param tick Current tick of the pool
    /// @param volumeInQuote Volume to record (in quote token decimals)
    /// @param isLimitOrder True if this is limit order volume, false for AMM volume
    /// @return indexUpdated The new observation index
    /// @return cardinalityUpdated The new cardinality
    function write(
        PoolId poolId,
        int24 tick,
        uint256 volumeInQuote,
        bool isLimitOrder
    ) external onlyHook returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        ObservationState memory state = states[poolId];
        if (state.cardinality == 0) revert OracleNotInitialized();

        VolumeObservation memory last = observations[poolId][state.index];

        // If same timestamp, update in place
        if (last.blockTimestamp == uint32(block.timestamp)) {
            if (isLimitOrder) {
                observations[poolId][state.index].limitOrderVolumeCumulative += volumeInQuote;
            } else {
                observations[poolId][state.index].ammVolumeCumulative += volumeInQuote;
            }
            return (state.index, state.cardinality);
        }

        // Calculate new cumulative values
        uint32 delta = uint32(block.timestamp) - last.blockTimestamp;
        int56 newTickCumulative = last.tickCumulative + int56(tick) * int56(uint56(delta));

        uint256 newAmmVolumeCumulative = last.ammVolumeCumulative;
        uint256 newLimitOrderVolumeCumulative = last.limitOrderVolumeCumulative;

        if (isLimitOrder) {
            newLimitOrderVolumeCumulative += volumeInQuote;
        } else {
            newAmmVolumeCumulative += volumeInQuote;
        }

        // Write to next index
        indexUpdated = (state.index + 1) % state.cardinalityNext;
        observations[poolId][indexUpdated] = VolumeObservation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: newTickCumulative,
            ammVolumeCumulative: newAmmVolumeCumulative,
            limitOrderVolumeCumulative: newLimitOrderVolumeCumulative,
            initialized: true
        });

        // Update cardinality if we've grown
        cardinalityUpdated = state.cardinality;
        if (indexUpdated == state.cardinality && indexUpdated < state.cardinalityNext) {
            cardinalityUpdated = state.cardinality + 1;
        }

        // Update state
        states[poolId].index = indexUpdated;
        states[poolId].cardinality = cardinalityUpdated;

        return (indexUpdated, cardinalityUpdated);
    }

    /// @notice Get Time-Weighted Average Volume over a time window
    /// @param poolId The pool ID
    /// @param secondsAgo Seconds in the past to calculate TWAV from
    /// @return result TWAV result with volume rates and shares
    function getTWAV(PoolId poolId, uint32 secondsAgo) external view returns (TWAVResult memory result) {
        if (secondsAgo == 0) revert InvalidSecondsAgo();

        ObservationState memory state = states[poolId];
        if (state.cardinality == 0) revert OracleNotInitialized();

        VolumeObservation memory current = observations[poolId][state.index];
        uint32 targetTimestamp = uint32(block.timestamp) - secondsAgo;

        // Get observation at target time (with interpolation if needed)
        VolumeObservation memory historical = _observeSingle(
            poolId,
            uint32(block.timestamp),
            targetTimestamp,
            current.tickCumulative,
            state.index,
            state.cardinality
        );

        // Calculate time window
        result.timeWindow = current.blockTimestamp - historical.blockTimestamp;
        if (result.timeWindow == 0) {
            // No time elapsed, return zero rates
            return result;
        }

        // Calculate volume deltas
        uint256 ammVolumeDelta = current.ammVolumeCumulative - historical.ammVolumeCumulative;
        uint256 limitOrderVolumeDelta = current.limitOrderVolumeCumulative - historical.limitOrderVolumeCumulative;

        // Calculate volume rates (volume per second)
        result.ammVolumeRate = ammVolumeDelta / result.timeWindow;
        result.limitOrderVolumeRate = limitOrderVolumeDelta / result.timeWindow;

        // Calculate shares in basis points
        uint256 totalVolumeRate = result.ammVolumeRate + result.limitOrderVolumeRate;
        if (totalVolumeRate > 0) {
            result.ammShareBps = uint16((result.ammVolumeRate * 10000) / totalVolumeRate);
            result.limitOrderShareBps = uint16(10000 - result.ammShareBps);
        } else {
            // No volume, default to 50/50 split
            result.ammShareBps = 5000;
            result.limitOrderShareBps = 5000;
        }

        return result;
    }

    /// @notice Increase the cardinality target for the observations array
    /// @param poolId The pool ID
    /// @param cardinalityNext The new target cardinality
    /// @return cardinalityNextOld The old target cardinality
    /// @return cardinalityNextNew The new target cardinality
    function increaseCardinalityNext(PoolId poolId, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        ObservationState storage state = states[poolId];
        cardinalityNextOld = state.cardinalityNext;

        if (cardinalityNext <= cardinalityNextOld) {
            return (cardinalityNextOld, cardinalityNextOld);
        }

        cardinalityNextNew = cardinalityNext;
        state.cardinalityNext = cardinalityNextNew;

        return (cardinalityNextOld, cardinalityNextNew);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fetch a single observation at a target timestamp
    /// @dev Uses binary search and interpolation for timestamps between observations
    /// @param poolId The pool ID
    /// @param time Current timestamp
    /// @param target Target timestamp to observe
    /// @param tick Current tick
    /// @param index Latest observation index
    /// @param cardinality Number of observations
    /// @return observation The observation at the target time (interpolated if needed)
    function _observeSingle(
        PoolId poolId,
        uint32 time,
        uint32 target,
        int56 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (VolumeObservation memory observation) {
        // If target is current time, return current observation
        if (target == time) {
            return observations[poolId][index];
        }

        // Binary search for the target timestamp
        (VolumeObservation memory beforeOrAt, VolumeObservation memory atOrAfter) =
            _getSurroundingObservations(poolId, time, target, tick, index, cardinality);

        // If exact match, return it
        if (beforeOrAt.blockTimestamp == target) {
            return beforeOrAt;
        }

        // Otherwise interpolate
        return _interpolate(beforeOrAt, atOrAfter, target);
    }

    /// @notice Binary search to find observations surrounding a target timestamp
    /// @param poolId The pool ID
    /// @param time Current timestamp
    /// @param target Target timestamp
    /// @param tick Current tick
    /// @param index Latest observation index
    /// @param cardinality Number of observations
    /// @return beforeOrAt Observation at or before target
    /// @return atOrAfter Observation at or after target
    function _getSurroundingObservations(
        PoolId poolId,
        uint32 time,
        uint32 target,
        int56 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (VolumeObservation memory beforeOrAt, VolumeObservation memory atOrAfter) {
        // Get oldest observation
        uint16 oldestIndex = (index + 1) % cardinality;
        VolumeObservation memory oldest = observations[poolId][oldestIndex];

        if (!oldest.initialized) {
            oldestIndex = 0;
            oldest = observations[poolId][0];
        }

        // Check bounds
        if (target < oldest.blockTimestamp) revert InvalidTimestamp();
        if (target >= time) {
            // Target is current or future, return latest
            return (observations[poolId][index], observations[poolId][index]);
        }

        // Binary search
        uint16 l = oldestIndex;
        uint16 r = index;

        while (true) {
            uint16 mid = (l + r + 1) / 2;
            if (mid >= cardinality) mid -= cardinality;

            VolumeObservation memory midObs = observations[poolId][mid];

            if (midObs.blockTimestamp <= target) {
                if (mid == index || observations[poolId][(mid + 1) % cardinality].blockTimestamp > target) {
                    return (midObs, observations[poolId][(mid + 1) % cardinality]);
                }
                l = mid + 1;
            } else {
                r = mid - 1;
            }

            if (l >= cardinality) l -= cardinality;
            if (r >= cardinality) r -= cardinality;
        }
    }

    /// @notice Interpolate observation values between two timestamps
    /// @param beforeObs Observation before target
    /// @param afterObs Observation after target
    /// @param target Target timestamp
    /// @return result Interpolated observation
    function _interpolate(
        VolumeObservation memory beforeObs,
        VolumeObservation memory afterObs,
        uint32 target
    ) internal pure returns (VolumeObservation memory result) {
        uint32 delta = afterObs.blockTimestamp - beforeObs.blockTimestamp;
        uint32 targetDelta = target - beforeObs.blockTimestamp;

        // Linear interpolation
        result.blockTimestamp = target;
        result.tickCumulative = beforeObs.tickCumulative +
            ((afterObs.tickCumulative - beforeObs.tickCumulative) * int56(uint56(targetDelta))) / int56(uint56(delta));

        result.ammVolumeCumulative = beforeObs.ammVolumeCumulative +
            ((afterObs.ammVolumeCumulative - beforeObs.ammVolumeCumulative) * targetDelta) / delta;

        result.limitOrderVolumeCumulative = beforeObs.limitOrderVolumeCumulative +
            ((afterObs.limitOrderVolumeCumulative - beforeObs.limitOrderVolumeCumulative) * targetDelta) / delta;

        result.initialized = true;

        return result;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the current observation state for a pool
    /// @param poolId The pool ID
    /// @return state The observation state
    function getState(PoolId poolId) external view returns (ObservationState memory state) {
        return states[poolId];
    }

    /// @notice Get a specific observation
    /// @param poolId The pool ID
    /// @param index The observation index
    /// @return observation The observation at the index
    function getObservation(PoolId poolId, uint256 index) external view returns (VolumeObservation memory observation) {
        return observations[poolId][index];
    }
}
