// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DojimaIncentives
/// @notice Dynamic reward distribution using TWAV-based volume split
/// @dev Rewards are distributed proportionally to AMM LPs and limit order makers based on volume contribution
contract DojimaIncentives {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuration for a pool's incentive program
    struct PoolConfig {
        uint32 twavWindow;           // Time window for TWAV calculation (seconds)
        int24 activeTickRange;       // Max tick distance from current tick for rewards
        uint256 decayFactor;         // Spread decay factor (basis points per tick)
        uint256 optimalSpreadTicks;  // Ticks within this range get bonus
        uint256 rewardPerSec;        // Reward tokens emitted per second
        uint256 lastUpdateTime;      // Last time rewards were calculated
        bool active;                 // Whether incentives are active for this pool
    }

    /// @notice Pool state for reward distribution
    struct PoolState {
        uint256 accAMMRewardPerLiquidity;        // Accumulated reward per unit of AMM liquidity
        uint256 accLimitOrderRewardPerWeight;    // Accumulated reward per unit of limit order weight
        uint256 totalAMMLiquidity;               // Total AMM liquidity in pool
        uint256 totalLimitOrderWeight;           // Total weighted limit order liquidity
    }

    /// @notice User AMM position info
    struct AMMPosition {
        uint128 liquidity;           // User's liquidity amount
        uint256 rewardDebt;          // Reward debt for calculation
        uint256 pendingRewards;      // Unclaimed rewards
    }

    /// @notice Limit order position info
    struct LimitOrderPosition {
        uint256 orderId;             // Order ID
        int24 tick;                  // Order tick
        uint128 liquidity;           // Order liquidity
        uint256 weight;              // Calculated weight based on spread
        uint256 rewardDebt;          // Reward debt for calculation
        bool active;                 // Whether order is still active
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reward token
    IERC20 public immutable rewardToken;

    /// @notice Volume oracle for TWAV calculation
    address public immutable volumeOracle;

    /// @notice Authorized hook contract
    address public immutable hookContract;

    /// @notice Admin address
    address public admin;

    /// @notice Pool configurations
    mapping(PoolId => PoolConfig) public poolConfigs;

    /// @notice Pool states
    mapping(PoolId => PoolState) public poolStates;

    /// @notice User AMM positions per pool
    mapping(PoolId => mapping(address => AMMPosition)) public ammPositions;

    /// @notice Limit order positions per pool
    mapping(PoolId => mapping(uint256 => LimitOrderPosition)) public limitOrderPositions;

    /// @notice User's limit order IDs per pool
    mapping(PoolId => mapping(address => uint256[])) public userLimitOrders;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolConfigured(
        PoolId indexed poolId,
        uint32 twavWindow,
        int24 activeTickRange,
        uint256 rewardPerSec
    );

    event AMMPositionAdded(
        PoolId indexed poolId,
        address indexed user,
        uint128 liquidity,
        uint256 timestamp
    );

    event AMMPositionRemoved(
        PoolId indexed poolId,
        address indexed user,
        uint128 liquidity,
        uint256 timestamp
    );

    event LimitOrderAdded(
        PoolId indexed poolId,
        uint256 indexed orderId,
        address indexed maker,
        int24 tick,
        uint128 liquidity,
        uint256 weight,
        uint256 timestamp
    );

    event LimitOrderRemoved(
        PoolId indexed poolId,
        uint256 indexed orderId,
        uint256 timestamp
    );

    event RewardsClaimed(
        address indexed user,
        PoolId indexed poolId,
        uint256 amount,
        uint256 timestamp
    );

    event RewardsDistributed(
        PoolId indexed poolId,
        uint256 ammRewards,
        uint256 limitOrderRewards,
        uint16 ammShareBps,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyHook();
    error OnlyAdmin();
    error PoolNotActive();
    error InvalidConfig();
    error NoRewardsToClaim();

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

    constructor(
        address _rewardToken,
        address _volumeOracle,
        address _hookContract
    ) {
        rewardToken = IERC20(_rewardToken);
        volumeOracle = _volumeOracle;
        hookContract = _hookContract;
        admin = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                        POOL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure incentives for a pool
    /// @param poolId The pool ID
    /// @param twavWindow Time window for TWAV (e.g., 300 = 5 minutes)
    /// @param activeTickRange Max tick distance for rewards (e.g., 100)
    /// @param decayFactor Decay per tick in bps (e.g., 50 = 0.5% per tick)
    /// @param optimalSpreadTicks Optimal spread for bonus (e.g., 10)
    /// @param rewardPerSec Rewards per second (in token decimals)
    function configurePool(
        PoolId poolId,
        uint32 twavWindow,
        int24 activeTickRange,
        uint256 decayFactor,
        uint256 optimalSpreadTicks,
        uint256 rewardPerSec
    ) external onlyAdmin {
        if (twavWindow == 0 || activeTickRange == 0) revert InvalidConfig();

        _updatePool(poolId);

        poolConfigs[poolId] = PoolConfig({
            twavWindow: twavWindow,
            activeTickRange: activeTickRange,
            decayFactor: decayFactor,
            optimalSpreadTicks: optimalSpreadTicks,
            rewardPerSec: rewardPerSec,
            lastUpdateTime: block.timestamp,
            active: true
        });

        emit PoolConfigured(poolId, twavWindow, activeTickRange, rewardPerSec);
    }

    /// @notice Update emission rate for a pool
    /// @param poolId The pool ID
    /// @param newRate New reward per second
    function updateEmissionRate(PoolId poolId, uint256 newRate) external onlyAdmin {
        _updatePool(poolId);
        poolConfigs[poolId].rewardPerSec = newRate;
    }

    /// @notice Disable incentives for a pool
    /// @param poolId The pool ID
    function deactivatePool(PoolId poolId) external onlyAdmin {
        _updatePool(poolId);
        poolConfigs[poolId].active = false;
    }

    /*//////////////////////////////////////////////////////////////
                        AMM POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add AMM liquidity position
    /// @param poolId The pool ID
    /// @param user The user address
    /// @param liquidity The liquidity amount
    function addAMMPosition(
        PoolId poolId,
        address user,
        uint128 liquidity
    ) external onlyHook {
        if (!poolConfigs[poolId].active) return;

        _updatePool(poolId);
        _updateAMMUser(poolId, user);

        AMMPosition storage position = ammPositions[poolId][user];
        position.liquidity += liquidity;

        PoolState storage state = poolStates[poolId];
        state.totalAMMLiquidity += uint256(liquidity);

        position.rewardDebt = uint256(position.liquidity) * state.accAMMRewardPerLiquidity / 1e18;

        emit AMMPositionAdded(poolId, user, liquidity, block.timestamp);
    }

    /// @notice Remove AMM liquidity position
    /// @param poolId The pool ID
    /// @param user The user address
    /// @param liquidity The liquidity amount
    function removeAMMPosition(
        PoolId poolId,
        address user,
        uint128 liquidity
    ) external onlyHook {
        if (!poolConfigs[poolId].active) return;

        _updatePool(poolId);
        _updateAMMUser(poolId, user);

        AMMPosition storage position = ammPositions[poolId][user];
        position.liquidity -= liquidity;

        PoolState storage state = poolStates[poolId];
        state.totalAMMLiquidity -= uint256(liquidity);

        position.rewardDebt = uint256(position.liquidity) * state.accAMMRewardPerLiquidity / 1e18;

        emit AMMPositionRemoved(poolId, user, liquidity, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                    LIMIT ORDER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add limit order for incentives
    /// @param poolId The pool ID
    /// @param orderId The order ID
    /// @param maker The maker address
    /// @param tick The order tick
    /// @param currentTick The current pool tick
    /// @param liquidity The order liquidity
    function addLimitOrder(
        PoolId poolId,
        uint256 orderId,
        address maker,
        int24 tick,
        int24 currentTick,
        uint128 liquidity
    ) external onlyHook {
        if (!poolConfigs[poolId].active) return;

        _updatePool(poolId);

        // Calculate weight based on spread
        (uint256 weight, bool isActive) = calculateLimitOrderWeight(poolId, tick, currentTick, liquidity);

        if (!isActive || weight == 0) return; // Outside active range or zero weight

        // Update user pending rewards before changing their weight
        _updateLimitOrderUser(poolId, maker);

        // Create position
        LimitOrderPosition storage position = limitOrderPositions[poolId][orderId];
        position.orderId = orderId;
        position.tick = tick;
        position.liquidity = liquidity;
        position.weight = weight;
        position.active = true;

        // Update global state
        PoolState storage state = poolStates[poolId];
        state.totalLimitOrderWeight += weight;

        // Set reward debt
        position.rewardDebt = weight * state.accLimitOrderRewardPerWeight / 1e18;

        // Track user's orders
        userLimitOrders[poolId][maker].push(orderId);

        emit LimitOrderAdded(poolId, orderId, maker, tick, liquidity, weight, block.timestamp);
    }

    /// @notice Remove limit order from incentives
    /// @param poolId The pool ID
    /// @param orderId The order ID
    function removeLimitOrder(PoolId poolId, uint256 orderId) external onlyHook {
        LimitOrderPosition storage position = limitOrderPositions[poolId][orderId];

        if (!position.active) return;

        _updatePool(poolId);

        // Update global state
        PoolState storage state = poolStates[poolId];
        state.totalLimitOrderWeight -= position.weight;

        // Mark as inactive
        position.active = false;

        emit LimitOrderRemoved(poolId, orderId, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        REWARD CLAIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim all rewards for a user in a pool
    /// @param poolId The pool ID
    function claimRewards(PoolId poolId) external {
        _claimRewards(poolId, msg.sender);
    }

    /// @notice Claim rewards for a user (hook can call this)
    /// @param poolId The pool ID
    /// @param user The user address
    function claimRewardsFor(PoolId poolId, address user) external onlyHook {
        _claimRewards(poolId, user);
    }

    /// @notice Internal claim function
    function _claimRewards(PoolId poolId, address user) internal {
        _updatePool(poolId);
        _updateAMMUser(poolId, user);
        _updateLimitOrderUser(poolId, user);

        AMMPosition storage ammPos = ammPositions[poolId][user];
        uint256 totalPending = ammPos.pendingRewards;

        // Clear pending from AMM
        ammPos.pendingRewards = 0;

        // Add pending from limit orders
        uint256[] storage orderIds = userLimitOrders[poolId][user];
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrderPosition storage loPos = limitOrderPositions[poolId][orderIds[i]];
            if (loPos.active) {
                uint256 pending = loPos.weight * poolStates[poolId].accLimitOrderRewardPerWeight / 1e18 - loPos.rewardDebt;
                totalPending += pending;
                loPos.rewardDebt = loPos.weight * poolStates[poolId].accLimitOrderRewardPerWeight / 1e18;
            }
        }

        if (totalPending == 0) revert NoRewardsToClaim();

        rewardToken.safeTransfer(user, totalPending);

        emit RewardsClaimed(user, poolId, totalPending, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        WEIGHT CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate weight for a limit order based on spread
    /// @param poolId The pool ID
    /// @param orderTick The order tick
    /// @param currentTick The current pool tick
    /// @param liquidity The order liquidity
    /// @return weight The calculated weight
    /// @return isActive Whether the order is within active range
    function calculateLimitOrderWeight(
        PoolId poolId,
        int24 orderTick,
        int24 currentTick,
        uint128 liquidity
    ) public view returns (uint256 weight, bool isActive) {
        PoolConfig memory config = poolConfigs[poolId];

        // Calculate spread in ticks
        int24 spreadTicks = orderTick > currentTick ? orderTick - currentTick : currentTick - orderTick;

        // Check if within active range
        isActive = spreadTicks <= config.activeTickRange;
        if (!isActive) return (0, false);

        // Exponential decay: weight = liquidity / (1 + spread * decayFactor)
        uint256 decayDivisor = 1e18 + (uint256(int256(spreadTicks)) * config.decayFactor * 1e18) / 10000;
        weight = (uint256(liquidity) * 1e18 * 1e18) / decayDivisor;

        // Bonus for optimal spread
        if (uint256(int256(spreadTicks)) <= config.optimalSpreadTicks) {
            weight = (weight * 120) / 100; // 20% bonus
        }

        return (weight, true);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update pool rewards using TWAV oracle
    function _updatePool(PoolId poolId) internal {
        PoolConfig storage config = poolConfigs[poolId];
        if (!config.active) return;
        if (block.timestamp <= config.lastUpdateTime) return;

        PoolState storage state = poolStates[poolId];
        uint256 timeDelta = block.timestamp - config.lastUpdateTime;
        uint256 totalRewards = timeDelta * config.rewardPerSec;

        if (totalRewards == 0) {
            config.lastUpdateTime = block.timestamp;
            return;
        }

        // Get TWAV-based volume split from oracle
        (uint256 ammRewards, uint256 limitOrderRewards, uint16 ammShareBps) =
            _calculateRewardSplit(poolId, totalRewards, config.twavWindow);

        // Update accumulators
        if (ammRewards > 0 && state.totalAMMLiquidity > 0) {
            state.accAMMRewardPerLiquidity += (ammRewards * 1e18) / state.totalAMMLiquidity;
        }

        if (limitOrderRewards > 0 && state.totalLimitOrderWeight > 0) {
            state.accLimitOrderRewardPerWeight += (limitOrderRewards * 1e18) / state.totalLimitOrderWeight;
        }

        config.lastUpdateTime = block.timestamp;

        emit RewardsDistributed(poolId, ammRewards, limitOrderRewards, ammShareBps, block.timestamp);
    }

    /// @notice Calculate reward split using TWAV oracle
    /// @param poolId The pool ID
    /// @param totalRewards Total rewards to distribute
    /// @param twavWindow Time window for TWAV
    /// @return ammRewards Rewards for AMM LPs
    /// @return limitOrderRewards Rewards for limit orders
    /// @return ammShareBps AMM share in basis points
    function _calculateRewardSplit(
        PoolId poolId,
        uint256 totalRewards,
        uint32 twavWindow
    ) internal view returns (uint256 ammRewards, uint256 limitOrderRewards, uint16 ammShareBps) {
        // Call volume oracle for TWAV
        try IDojimaVolumeOracle(volumeOracle).getTWAV(poolId, twavWindow) returns (
            IDojimaVolumeOracle.TWAVResult memory twav
        ) {
            ammShareBps = twav.ammShareBps;

            // Split rewards based on volume share
            ammRewards = (totalRewards * twav.ammShareBps) / 10000;
            limitOrderRewards = totalRewards - ammRewards;
        } catch {
            // Fallback to 50/50 split if oracle fails
            ammShareBps = 5000;
            ammRewards = totalRewards / 2;
            limitOrderRewards = totalRewards - ammRewards;
        }
    }

    /// @notice Update AMM user rewards
    function _updateAMMUser(PoolId poolId, address user) internal {
        AMMPosition storage position = ammPositions[poolId][user];
        PoolState storage state = poolStates[poolId];

        if (position.liquidity > 0) {
            uint256 pending = uint256(position.liquidity) * state.accAMMRewardPerLiquidity / 1e18 - position.rewardDebt;
            position.pendingRewards += pending;
        }

        position.rewardDebt = uint256(position.liquidity) * state.accAMMRewardPerLiquidity / 1e18;
    }

    /// @notice Update limit order user rewards
    function _updateLimitOrderUser(PoolId poolId, address user) internal {
        uint256[] storage orderIds = userLimitOrders[poolId][user];
        PoolState storage state = poolStates[poolId];

        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrderPosition storage position = limitOrderPositions[poolId][orderIds[i]];
            if (position.active && position.weight > 0) {
                // Note: We don't accumulate pending here, it's calculated on claim
                position.rewardDebt = position.weight * state.accLimitOrderRewardPerWeight / 1e18;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending rewards for a user
    /// @param poolId The pool ID
    /// @param user The user address
    /// @return totalPending Total pending rewards
    function pendingRewards(PoolId poolId, address user) external view returns (uint256 totalPending) {
        PoolConfig memory config = poolConfigs[poolId];
        PoolState memory state = poolStates[poolId];

        // Simulate pool update
        if (config.active && block.timestamp > config.lastUpdateTime) {
            uint256 timeDelta = block.timestamp - config.lastUpdateTime;
            uint256 totalRewards = timeDelta * config.rewardPerSec;

            if (totalRewards > 0) {
                (uint256 ammRewards, uint256 limitOrderRewards,) =
                    _calculateRewardSplit(poolId, totalRewards, config.twavWindow);

                if (ammRewards > 0 && state.totalAMMLiquidity > 0) {
                    state.accAMMRewardPerLiquidity += (ammRewards * 1e18) / state.totalAMMLiquidity;
                }

                if (limitOrderRewards > 0 && state.totalLimitOrderWeight > 0) {
                    state.accLimitOrderRewardPerWeight += (limitOrderRewards * 1e18) / state.totalLimitOrderWeight;
                }
            }
        }

        // Calculate AMM pending
        AMMPosition memory ammPos = ammPositions[poolId][user];
        if (ammPos.liquidity > 0) {
            totalPending += uint256(ammPos.liquidity) * state.accAMMRewardPerLiquidity / 1e18 - ammPos.rewardDebt;
        }
        totalPending += ammPos.pendingRewards;

        // Calculate limit order pending
        uint256[] storage orderIds = userLimitOrders[poolId][user];
        for (uint256 i = 0; i < orderIds.length; i++) {
            LimitOrderPosition memory loPos = limitOrderPositions[poolId][orderIds[i]];
            if (loPos.active && loPos.weight > 0) {
                totalPending += loPos.weight * state.accLimitOrderRewardPerWeight / 1e18 - loPos.rewardDebt;
            }
        }
    }

    /// @notice Get user's AMM position
    /// @param poolId The pool ID
    /// @param user The user address
    /// @return position The AMM position
    function getAMMPosition(PoolId poolId, address user) external view returns (AMMPosition memory position) {
        return ammPositions[poolId][user];
    }

    /// @notice Get limit order position
    /// @param poolId The pool ID
    /// @param orderId The order ID
    /// @return position The limit order position
    function getLimitOrderPosition(PoolId poolId, uint256 orderId)
        external view returns (LimitOrderPosition memory position)
    {
        return limitOrderPositions[poolId][orderId];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw tokens
    /// @param token Token address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external onlyAdmin {
        IERC20(token).safeTransfer(admin, amount);
    }

    /// @notice Transfer admin
    /// @param newAdmin New admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin");
        admin = newAdmin;
    }
}

/*//////////////////////////////////////////////////////////////
                      ORACLE INTERFACE
//////////////////////////////////////////////////////////////*/

interface IDojimaVolumeOracle {
    struct TWAVResult {
        uint256 ammVolumeRate;
        uint256 limitOrderVolumeRate;
        uint16 ammShareBps;
        uint16 limitOrderShareBps;
        uint32 timeWindow;
    }

    function getTWAV(PoolId poolId, uint32 secondsAgo) external view returns (TWAVResult memory result);
}
