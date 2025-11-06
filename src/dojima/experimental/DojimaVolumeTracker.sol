// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title DojimaVolumeTracker
/// @notice Tracks user trading volume across all pools for tiered maker rebates
/// @dev Uses 30-day rolling window with decay mechanism
contract DojimaVolumeTracker {

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebate tier configuration
    struct RebateTier {
        uint256 volumeThreshold;  // Min 30-day volume (in quote token)
        uint256 rebateBps;        // Maker rebate in basis points
    }

    /// @notice User volume tracking
    struct UserVolume {
        uint256 totalVolume;      // Total lifetime volume
        uint256 last30DayVolume;  // Volume in last 30 days
        uint256 lastUpdateTime;   // Last time volume was recorded
        uint256 dailyVolume;      // Volume today
        uint256 lastDayTimestamp; // Timestamp of current day
    }

    /// @notice Daily volume snapshot for decay calculation
    struct DailySnapshot {
        uint32 timestamp;         // Day timestamp
        uint256 volume;           // Volume on that day
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorized hook contract
    address public immutable hookContract;

    /// @notice Admin address
    address public admin;

    /// @notice Rebate tiers (sorted by volume ascending)
    RebateTier[] public rebateTiers;

    /// @notice User volume data
    mapping(address => UserVolume) public userVolumes;

    /// @notice Daily snapshots for each user (circular buffer of 30 days)
    mapping(address => DailySnapshot[30]) public dailySnapshots;

    /// @notice Current snapshot index for each user
    mapping(address => uint8) public snapshotIndex;

    /// @notice Base rebate for users below tier 1
    uint256 public baseRebateBps = 2000; // 20%

    /// @notice Time window for volume tracking (30 days)
    uint256 public constant VOLUME_WINDOW = 30 days;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event VolumeRecorded(
        address indexed user,
        PoolId indexed poolId,
        uint256 volume,
        uint256 newTotalVolume,
        uint256 new30DayVolume,
        uint256 timestamp
    );

    event RebateTierUpdated(
        uint256 indexed tierIndex,
        uint256 volumeThreshold,
        uint256 rebateBps
    );

    event UserTierChanged(
        address indexed user,
        uint256 oldRebateBps,
        uint256 newRebateBps,
        uint256 volume30Day
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyHook();
    error OnlyAdmin();
    error InvalidTierConfig();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHook() {
        if (msg.sender != hookContract) revert OnlyHook();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _hookContract) {
        hookContract = _hookContract;
        admin = msg.sender;

        // Initialize default rebate tiers
        // Tier 0: $0-10k = 20% (2000 bps)
        // Tier 1: $10k-50k = 25% (2500 bps)
        // Tier 2: $50k-250k = 30% (3000 bps)
        // Tier 3: $250k-1M = 35% (3500 bps)
        // Tier 4: $1M+ = 40% (4000 bps)
        rebateTiers.push(RebateTier({volumeThreshold: 10_000e6, rebateBps: 2500})); // $10k (assuming 6 decimals USDC)
        rebateTiers.push(RebateTier({volumeThreshold: 50_000e6, rebateBps: 3000})); // $50k
        rebateTiers.push(RebateTier({volumeThreshold: 250_000e6, rebateBps: 3500})); // $250k
        rebateTiers.push(RebateTier({volumeThreshold: 1_000_000e6, rebateBps: 4000})); // $1M
    }

    /*//////////////////////////////////////////////////////////////
                        VOLUME TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Record volume for a user
    /// @param user The user address
    /// @param poolId The pool ID (for event logging)
    /// @param volumeInQuote Volume in quote token (e.g., USDC with 6 decimals)
    function recordVolume(address user, PoolId poolId, uint256 volumeInQuote) external onlyHook {
        if (volumeInQuote == 0) return;

        UserVolume storage userVol = userVolumes[user];
        uint256 oldRebate = getMakerRebate(user);

        // Update daily volume
        uint256 currentDay = block.timestamp / 1 days;
        uint256 lastDay = userVol.lastDayTimestamp / 1 days;

        if (currentDay > lastDay) {
            // New day - save yesterday's volume and start fresh
            _saveSnapshot(user, userVol.dailyVolume, userVol.lastDayTimestamp);
            userVol.dailyVolume = volumeInQuote;
            userVol.lastDayTimestamp = block.timestamp;
        } else {
            // Same day - accumulate
            userVol.dailyVolume += volumeInQuote;
        }

        // Update total lifetime volume
        userVol.totalVolume += volumeInQuote;

        // Decay old volume and calculate new 30-day volume
        userVol.last30DayVolume = _calculate30DayVolume(user, userVol.dailyVolume);

        userVol.lastUpdateTime = block.timestamp;

        uint256 newRebate = getMakerRebate(user);

        emit VolumeRecorded(user, poolId, volumeInQuote, userVol.totalVolume, userVol.last30DayVolume, block.timestamp);

        if (newRebate != oldRebate) {
            emit UserTierChanged(user, oldRebate, newRebate, userVol.last30DayVolume);
        }
    }

    /// @notice Save a daily snapshot
    /// @param user The user address
    /// @param volume The volume for the day
    /// @param timestamp The day's timestamp
    function _saveSnapshot(address user, uint256 volume, uint256 timestamp) internal {
        if (volume == 0) return;

        uint8 index = snapshotIndex[user];
        dailySnapshots[user][index] = DailySnapshot({
            timestamp: uint32(timestamp),
            volume: volume
        });

        // Move to next index (circular buffer)
        snapshotIndex[user] = uint8((index + 1) % 30);
    }

    /// @notice Calculate 30-day volume by summing non-expired snapshots
    /// @param user The user address
    /// @param todayVolume Today's volume (not yet in snapshots)
    /// @return total30Day Total volume in last 30 days
    function _calculate30DayVolume(address user, uint256 todayVolume) internal view returns (uint256 total30Day) {
        // Handle case where blockchain time is less than 30 days old
        uint256 cutoffTime = block.timestamp > VOLUME_WINDOW ? block.timestamp - VOLUME_WINDOW : 0;

        // Start with today's volume
        total30Day = todayVolume;

        // Add all non-expired snapshots
        for (uint256 i = 0; i < 30; i++) {
            DailySnapshot memory snapshot = dailySnapshots[user][i];
            if (snapshot.timestamp >= cutoffTime && snapshot.timestamp > 0) {
                total30Day += snapshot.volume;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        REBATE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get maker rebate for a user based on their 30-day volume
    /// @param user The user address
    /// @return rebateBps Maker rebate in basis points
    function getMakerRebate(address user) public view returns (uint256 rebateBps) {
        UserVolume memory userVol = userVolumes[user];

        // Recalculate 30-day volume with decay
        uint256 volume30Day = _calculate30DayVolume(user, userVol.dailyVolume);

        // Find appropriate tier
        rebateBps = baseRebateBps; // Default base rebate

        for (uint256 i = 0; i < rebateTiers.length; i++) {
            if (volume30Day >= rebateTiers[i].volumeThreshold) {
                rebateBps = rebateTiers[i].rebateBps;
            } else {
                break; // Tiers are sorted, so we can stop
            }
        }

        return rebateBps;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's volume statistics
    /// @param user The user address
    /// @return totalVolume Total lifetime volume
    /// @return volume30Day Volume in last 30 days
    /// @return currentRebate Current rebate in basis points
    /// @return nextTierVolume Volume needed for next tier (0 if at max tier)
    /// @return nextTierRebate Rebate at next tier
    function getUserStats(address user)
        external
        view
        returns (
            uint256 totalVolume,
            uint256 volume30Day,
            uint256 currentRebate,
            uint256 nextTierVolume,
            uint256 nextTierRebate
        )
    {
        UserVolume memory userVol = userVolumes[user];
        totalVolume = userVol.totalVolume;
        volume30Day = _calculate30DayVolume(user, userVol.dailyVolume);
        currentRebate = getMakerRebate(user);

        // Find next tier
        for (uint256 i = 0; i < rebateTiers.length; i++) {
            if (volume30Day < rebateTiers[i].volumeThreshold) {
                nextTierVolume = rebateTiers[i].volumeThreshold;
                nextTierRebate = rebateTiers[i].rebateBps;
                return (totalVolume, volume30Day, currentRebate, nextTierVolume, nextTierRebate);
            }
        }

        // Already at max tier
        nextTierVolume = 0;
        nextTierRebate = currentRebate;
    }

    /// @notice Get all rebate tiers
    /// @return tiers Array of rebate tiers
    function getRebateTiers() external view returns (RebateTier[] memory tiers) {
        return rebateTiers;
    }

    /// @notice Get user's daily snapshots
    /// @param user The user address
    /// @return snapshots Array of daily snapshots
    function getUserSnapshots(address user) external view returns (DailySnapshot[30] memory snapshots) {
        for (uint256 i = 0; i < 30; i++) {
            snapshots[i] = dailySnapshots[user][i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update rebate tier
    /// @param tierIndex Index of tier to update
    /// @param volumeThreshold New volume threshold
    /// @param rebateBps New rebate in basis points
    function updateRebateTier(uint256 tierIndex, uint256 volumeThreshold, uint256 rebateBps) external onlyAdmin {
        if (tierIndex >= rebateTiers.length) revert InvalidTierConfig();
        if (rebateBps > 5000) revert InvalidTierConfig(); // Max 50%

        // Validate ordering
        if (tierIndex > 0 && volumeThreshold <= rebateTiers[tierIndex - 1].volumeThreshold) {
            revert InvalidTierConfig();
        }
        if (tierIndex < rebateTiers.length - 1 && volumeThreshold >= rebateTiers[tierIndex + 1].volumeThreshold) {
            revert InvalidTierConfig();
        }

        rebateTiers[tierIndex].volumeThreshold = volumeThreshold;
        rebateTiers[tierIndex].rebateBps = rebateBps;

        emit RebateTierUpdated(tierIndex, volumeThreshold, rebateBps);
    }

    /// @notice Add a new rebate tier
    /// @param volumeThreshold Volume threshold
    /// @param rebateBps Rebate in basis points
    function addRebateTier(uint256 volumeThreshold, uint256 rebateBps) external onlyAdmin {
        if (rebateBps > 5000) revert InvalidTierConfig(); // Max 50%

        // Must be higher than last tier
        if (rebateTiers.length > 0) {
            if (volumeThreshold <= rebateTiers[rebateTiers.length - 1].volumeThreshold) {
                revert InvalidTierConfig();
            }
        }

        rebateTiers.push(RebateTier({volumeThreshold: volumeThreshold, rebateBps: rebateBps}));

        emit RebateTierUpdated(rebateTiers.length - 1, volumeThreshold, rebateBps);
    }

    /// @notice Update base rebate
    /// @param newBaseRebateBps New base rebate in basis points
    function updateBaseRebate(uint256 newBaseRebateBps) external onlyAdmin {
        if (newBaseRebateBps > 5000) revert InvalidTierConfig(); // Max 50%
        baseRebateBps = newBaseRebateBps;
    }

    /// @notice Transfer admin
    /// @param newAdmin New admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin");
        admin = newAdmin;
    }
}
