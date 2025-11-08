// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CLBaseHook} from "infinity-hooks/src/pool-cl/CLBaseHook.sol";
import {TickOrderBookManager} from "./orderbook/TickOrderBookManager.sol";
import {OrderBookTypes} from "./orderbook/OrderBookTypes.sol";
import {GlobalOrderIdLibrary} from "./orderbook/OrderBookTypes.sol";
import {TickMath as CoreTickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {TickMath} from "./orderbook/TickMath.sol";
import {TickBitmap} from "./orderbook/TickBitmap.sol";
import {FenwickOrderBook} from "./orderbook/FenwickOrderBook.sol";

/// @title DojimaHybridHook
/// @notice Hybrid AMM + CLOB using tick-integrated order books
/// @dev Implements CLOB-first routing: checks order book before AMM
contract DojimaHybridHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using TickOrderBookManager for TickOrderBookManager.TickBooks;
    using TickBitmap for mapping(int16 => uint256);
    using FenwickOrderBook for OrderBookTypes.Book;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAmount();
    error InsufficientBalance();
    error OrderNotFound();
    error NotOrderMaker();
    error OrderAlreadyFilled();

    /*//////////////////////////////////////////////////////////////
                        BATCH UPDATE STRUCTURES
    //////////////////////////////////////////////////////////////*/

    struct BalanceUpdate {
        address user;
        Currency currency;
        int128 delta;       // Positive for credits, negative for debits
        bool isLocked;      // Whether it affects locked balance
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        PoolId indexed poolId,
        uint256 price,
        uint128 amount,
        bool isBuy
    );

    event OrderFilled(
        uint256 indexed orderId,
        address indexed maker,
        address indexed taker,
        uint128 amountFilled,
        uint256 price
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed maker,
        uint128 amountRemaining
    );

    event OrderBookMatched(
        PoolId indexed poolId,
        uint128 amountFilled,
        uint256 avgPrice,
        uint256 ordersMatched
    );

    // OPTIMIZATION: Single summary event instead of per-order events  
    event HybridExecutionSummary(
        PoolId indexed poolId,
        address indexed taker,
        uint256 totalMatched,
        uint256 ordersCount,
        uint256 avgPrice,
        uint256 surplusGenerated
    );

    // Optional: Detailed events for analytics (can be disabled for gas savings)
    event OrderFillsBatch(
        PoolId indexed poolId,
        uint256[] orderIds,
        address[] makers,
        uint128[] amounts,  // Fix: Changed to uint128[] to match MatchResult
        uint256[] prices
    );

    // Event for explicit routing execution
    event ExplicitRoutingExecuted(
        PoolId indexed poolId,
        address indexed trader,
        uint128 amountCLOB,
        uint128 amountAMM,
        uint256 clobAmountOut,
        uint256 ammAmountOut
    );

    event Deposited(
        address indexed user,
        Currency indexed currency,
        uint256 amount
    );

    event Withdrawn(
        address indexed user,
        Currency indexed currency,
        uint256 amount
    );

    event BalanceUnlocked(
        address indexed user,
        Currency indexed currency,
        uint128 amount
    );

    event TakerRebate(
        PoolId indexed poolId,
        address indexed taker,
        Currency indexed currency,
        uint256 amount
    );

    event BatchOrdersPlaced(
        address indexed maker,
        PoolId indexed poolId,
        uint256 ordersPlaced,
        uint256 totalAmount
    );

    // TODO: Add volume tracking events later
    // event VolumeTracked(PoolId indexed poolId, uint256 volume, uint32 timestamp);

    // TODO: Future: Split surplus between takers, makers, and LPs
    // - Could gamify based on volume (higher volume = better split)
    // - Could add maker rebates on top of limit prices
    // - Could boost LP fees with CLOB surplus
    // event MakerRebateClaimed(address indexed maker, Currency currency, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of bitmap words per tick (16 = 4,096 price points = ~0.1 cent precision)
    uint16 public constant WORDS_PER_TICK = 16;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Per-pool tick order books
    mapping(PoolId => TickOrderBookManager.TickBooks) public tickBooks;

    // TWAV tracking (preserved from original hook)
    mapping(PoolId => int24) public tickLowerLasts;

    // Pending fill results (stored in beforeSwap, used in afterSwap)
    mapping(PoolId => OrderBookTypes.MatchResult) private _pendingFills;

    // AMM swap simulation results
    struct SwapSimulation {
        uint256 ammPrice;        // Effective AMM execution price
        uint256 ammCost;         // Total cost for full swap via AMM
    }

    // CLOB order book analysis results (READ-ONLY)
    struct OrderBookAnalysis {
        uint128 totalAvailable;   // Total CLOB liquidity available
        uint256 avgPrice;         // Weighted average CLOB price
        uint256 totalCost;        // Cost to fill from CLOB
        uint256 ordersFound;      // Number of orders within price limit
        bool worthUsing;          // true if CLOB better than AMM
    }

    // Optimal execution split between CLOB and AMM
    struct OptimalExecution {
        address taker;           // Who initiated swap
        bool isBuy;              // Direction: true = buying token0
        uint128 clobAmount;      // Amount to fill from CLOB
        uint128 ammAmount;       // Amount filled by AMM (for reference)
        uint256 clobCost;        // Cost of CLOB portion
        uint256 savings;         // Surplus to refund to taker
    }

    // OPTIMIZATION: Unified routing decision (reduces storage)
    struct RoutingDecision {
        bool useCLOB;            // Whether to use CLOB
        uint128 clobAmount;      // Amount for CLOB (0 if not using)
        uint256 estimatedSavings; // Expected savings vs pure AMM
        uint256 priceThreshold;  // Price limit for CLOB matching
    }

    // Storage: beforeSwap analysis → afterSwap execution
    mapping(PoolId => SwapSimulation) private _swapSims;
    mapping(PoolId => OrderBookAnalysis) private _clobAnalysis;
    mapping(PoolId => OptimalExecution) private _optimalExec;
    
    // OPTIMIZATION: Simplified routing storage
    mapping(PoolId => RoutingDecision) private _routingDecisions;

    // Internal balance tracking for gas savings
    struct UserBalance {
        uint128 total;      // Total deposited amount
        uint128 locked;     // Amount locked in active orders
    }

    mapping(address => mapping(Currency => UserBalance)) public balances;

    // TODO: Add volume tracking state later
    // mapping(PoolId => uint256) public cumulativeVolume;
    // mapping(PoolId => uint32) public lastVolumeUpdate;

    // TODO: Add rebate tracking state later
    // mapping(address => mapping(Currency => uint256)) public makerRebates;
    // uint256 public makerRebateBps = 2000; // 20%

    // Batch order placement
    struct OrderRequest {
        uint256 price;
        uint128 amount;
        bool isBuy;
    }

    /*//////////////////////////////////////////////////////////////
                    BATCH UPDATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Process order fills with batched balance updates for gas efficiency
    function _processFillsBatched(
        OrderBookTypes.MatchResult memory matched,
        PoolKey calldata key,
        bool isBuy,
        address sender
    ) private {
        // Initialize batch update arrays
        BalanceUpdate[] memory updates = new BalanceUpdate[](matched.filledOrderIds.length * 2);
        uint256 updateCount = 0;
        
        // OPTIMIZATION 1: Single loop for order processing + balance collection
        for (uint256 i = 0; i < matched.filledOrderIds.length; i++) {
            uint256 orderId = matched.filledOrderIds[i];
            address maker = matched.makers[i];
            uint128 filledAmount = matched.filledAmounts[i];
            uint256 fillPrice = matched.fillPrices[i];
            
            // Decode only once per order
            (, , , , bool orderIsBuy) = GlobalOrderIdLibrary.decode(orderId);
            
            if (orderIsBuy) {
                uint128 cost = _safeCast128((uint256(filledAmount) * fillPrice) / 1e18);
                // Queue balance updates (no immediate SSTORE)
                updates[updateCount++] = BalanceUpdate(maker, key.currency1, -int128(cost), true);   // Unlock
                updates[updateCount++] = BalanceUpdate(maker, key.currency0, int128(filledAmount), false); // Credit
            } else {
                uint128 proceeds = _safeCast128((uint256(filledAmount) * fillPrice) / 1e18);
                updates[updateCount++] = BalanceUpdate(maker, key.currency0, -int128(filledAmount), true); // Unlock  
                updates[updateCount++] = BalanceUpdate(maker, key.currency1, int128(proceeds), false);     // Credit
            }
        }
        
        // OPTIMIZATION 2: Apply all balance updates in single pass
        _applyBalanceUpdatesBatched(updates, updateCount);
    }

    /// @notice Apply batched balance updates to minimize SSTORE operations
    function _applyBalanceUpdatesBatched(BalanceUpdate[] memory updates, uint256 updateCount) private {
        for (uint256 i = 0; i < updateCount; i++) {
            BalanceUpdate memory update = updates[i];
            UserBalance storage balance = balances[update.user][update.currency];
            
            if (update.isLocked) {
                // Safe locked balance update
                if (update.delta < 0) {
                    balance.locked -= uint128(uint256(int256(-update.delta)));
                    balance.total -= uint128(uint256(int256(-update.delta)));  // Also reduce total
                } else {
                    balance.locked += uint128(uint256(int256(update.delta)));
                    balance.total += uint128(uint256(int256(update.delta)));   // Also increase total
                }
            } else {
                // Safe total balance update  
                if (update.delta < 0) {
                    balance.total -= uint128(uint256(int256(-update.delta)));
                } else {
                    balance.total += uint128(uint256(int256(update.delta)));
                }
            }
        }
    }

    /// @notice Emit optimized events for hybrid execution
    function _emitOptimizedEvents(
        PoolKey calldata key,
        OrderBookTypes.MatchResult memory matched,
        address sender,
        uint256 surplus,
        bool emitDetails
    ) private {
        emit HybridExecutionSummary(
            key.toId(),
            sender,
            matched.amountFilled,
            matched.ordersMatched,
            matched.avgPrice,
            surplus
        );
        
        // Optional detailed events for frontend/analytics
        if (emitDetails && matched.ordersMatched <= 20) { // Limit detail events
            emit OrderFillsBatch(
                key.toId(),
                matched.filledOrderIds,
                matched.makers,
                matched.filledAmounts,
                matched.fillPrices
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ICLPoolManager _poolManager) CLBaseHook(_poolManager) {
        // Verify vault is properly set
        require(address(vault) != address(0), "Vault not initialized");
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,   // Option A: Let AMM execute, match in afterSwap
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize order book for new pool
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external virtual override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        int24 tickSpacing = key.parameters.getTickSpacing();

        // Initialize tick order books
        // Use WORDS_PER_TICK = 16 words per tick = 4,096 price points ≈ 0.1¢ precision
        tickBooks[poolId].initialize(tickSpacing, WORDS_PER_TICK);

        // Initialize TWAV tracking
        tickLowerLasts[poolId] = _getTickLower(tick, tickSpacing);

        return this.afterInitialize.selector;
    }

    /// @notice Analyze CLOB vs AMM before swap executes
    /// @dev READ-ONLY analysis - does not modify order book state
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // Determine swap direction and amount
        bool isBuy = !params.zeroForOne;  // zeroForOne = false means buying token0
        uint128 amountWanted = uint128(
            params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified)
        );

        // OPTIMIZATION: Try fast analysis first, fallback to full analysis if needed
        RoutingDecision memory decision = _analyzeOptimalRouting(
            poolId,
            isBuy,
            amountWanted,
            sender
        );

        // If fast analysis is uncertain, do full analysis for accuracy
        if (!decision.useCLOB && amountWanted > 1 ether) {
            // For larger swaps, double-check with full analysis
            SwapSimulation memory ammSim = _simulateAMMSwap(poolId, amountWanted);
            OrderBookAnalysis memory clobAnalysis = _analyzeOrderBook(
                poolId,
                isBuy,
                amountWanted,
                ammSim.ammPrice
            );
            
            if (clobAnalysis.worthUsing && clobAnalysis.totalAvailable > 0) {
                decision.useCLOB = true;
                decision.clobAmount = clobAnalysis.totalAvailable < amountWanted 
                    ? clobAnalysis.totalAvailable 
                    : amountWanted;
                decision.priceThreshold = ammSim.ammPrice;
            }
        }

        // Store decision for afterSwap
        _routingDecisions[poolId] = decision;

        // Let AMM execute full swap
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Execute CLOB matching if better than AMM, refund surplus
    /// @dev AMM already executed - we now match CLOB and refund difference
    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external virtual override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();
        int24 tickSpacing = key.parameters.getTickSpacing();

        // Update TWAV tracking
        int24 currentTick = _getTick(poolId);
        int24 currentTickLower = _getTickLower(currentTick, tickSpacing);
        tickLowerLasts[poolId] = currentTickLower;

        // Get swap direction
        bool isBuy = !params.zeroForOne;

        // ⭐ OPTIMIZATION: Use simplified routing decision from beforeSwap
        RoutingDecision memory decision = _routingDecisions[poolId];
        
        // Quick exit if no CLOB usage planned
        if (!decision.useCLOB || decision.clobAmount == 0) {
            delete _routingDecisions[poolId];
            return (this.afterSwap.selector, 0);
        }

        // Calculate ACTUAL AMM execution data for price-limit matching
        uint256 actualAMMPrice = _calculateAMMPrice(delta, isBuy);
        uint256 actualAMMCost = _calculateAMMCost(delta, isBuy);
        
        // Get actual amount swapped
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1(); 
        uint128 actualAmount = uint128(isBuy ? uint256(int256(amount0)) : uint256(int256(-amount0)));
        
        // Use planned CLOB amount, bounded by actual swap amount
        uint128 clobAmount = decision.clobAmount;
        if (clobAmount > actualAmount) {
            clobAmount = actualAmount;
        }

        // CLOB is better! NOW actually match orders (state modification)
        // IMPORTANT: For active matching, start from a LOW tick to find best prices
        // Not from currentTick which is post-swap and might be far from orders
        int24 searchTick = isBuy ? int24(-100000) : int24(800000);

        // Use price-limit matching to only match orders better than AMM price
        OrderBookTypes.MatchResult memory matched = tickBooks[poolId].matchMarketOrderWithLimit(
            poolId,
            isBuy,
            clobAmount,
            searchTick,     // Start from low/high tick to find all available orders
            actualAMMPrice  // Only match orders better than AMM price
        );

        // OPTIMIZATION: Use optimized event emission
        bool emitDetails = matched.ordersMatched <= 10; // Only emit details for smaller batches

        // Determine currencies
        Currency inputCurrency = isBuy ? key.currency1 : key.currency0;
        Currency outputCurrency = isBuy ? key.currency0 : key.currency1;

        // OPTIMIZATION: Process all order fills with batched balance updates
        _processFillsBatched(matched, key, isBuy, sender);

        // Calculate taker refund (surplus from CLOB execution)
        uint256 surplus = _calculateTakerSurplus(
            actualAMMCost,
            matched,
            actualAmount,
            actualAMMPrice
        );

        // Refund surplus to taker's internal balance (if any)
        if (surplus > 1000 && sender != address(0)) {  // Min 1000 wei to avoid dust
            Currency refundCurrency = isBuy ? key.currency1 : key.currency0;
            balances[sender][refundCurrency].total += uint128(surplus);

            emit TakerRebate(poolId, sender, refundCurrency, surplus);
        }

        // OPTIMIZATION: Emit optimized events
        _emitOptimizedEvents(key, matched, sender, surplus, emitDetails);

        // ⭐ OPTIMIZATION: Simplified cleanup
        delete _routingDecisions[poolId];

        return (this.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens to internal balance for gas-efficient trading
    /// @dev Uses vault.lock() to integrate with V4's flash accounting system
    /// @param currency Token to deposit
    /// @param amount Amount to deposit
    function deposit(Currency currency, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        // Use vault.lock to handle deposit with proper settlement
        vault.lock(abi.encodeCall(this.lockAcquiredDeposit, (currency, amount, msg.sender)));

        emit Deposited(msg.sender, currency, amount);
    }

    /// @notice Callback for vault.lock() during deposit
    /// @dev Transfers tokens from user to vault and mints credits to hook
    function lockAcquiredDeposit(Currency currency, uint256 amount, address user) external selfOnly {
        // Sync vault state
        vault.sync(currency);

        // Transfer tokens from user to vault
        IERC20(Currency.unwrap(currency)).safeTransferFrom(user, address(vault), amount);

        // Settle the debt to vault
        vault.settle();

        // Mint vault credits to hook (so we can use them later in swaps)
        vault.mint(address(this), currency, amount);

        // Track in internal balance accounting
        balances[user][currency].total += uint128(amount);
    }

    /// @notice Withdraw available balance (total - locked)
    /// @dev Uses vault.lock() to properly burn credits and transfer tokens
    /// @param currency Token to withdraw
    /// @param amount Amount to withdraw
    function withdraw(Currency currency, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();

        UserBalance storage balance = balances[msg.sender][currency];
        uint128 available = balance.total - balance.locked;

        if (amount > available) revert InsufficientBalance();

        // Debit user's balance
        balance.total -= uint128(amount);

        // Use vault.lock to handle withdrawal with proper settlement
        vault.lock(abi.encodeCall(this.lockAcquiredWithdraw, (currency, amount, msg.sender)));

        emit Withdrawn(msg.sender, currency, amount);
    }

    /// @notice Callback for vault.lock() during withdrawal
    /// @dev Burns hook's vault credits and transfers tokens to user
    function lockAcquiredWithdraw(Currency currency, uint256 amount, address user) external selfOnly {
        // Burn hook's vault credits
        vault.burn(address(this), currency, amount);

        // Transfer tokens from vault to user
        vault.take(currency, user, amount);
    }

    /// @notice Callback for vault.lock() during taker refund
    /// @dev Refunds surplus to taker when CLOB provides better price than AMM
    function lockAcquiredRefund(Currency currency, address taker, uint256 amount) external selfOnly {
        // Burn hook's vault credits (from the surplus)
        vault.burn(address(this), currency, amount);

        // Transfer refund to taker
        vault.take(currency, taker, amount);
    }

    /// @notice Get user's balance information
    /// @param user User address
    /// @param currency Token currency
    /// @return total Total deposited
    /// @return locked Amount locked in orders
    /// @return available Available for withdrawal (total - locked)
    function getBalanceInfo(address user, Currency currency)
        external
        view
        returns (uint128 total, uint128 locked, uint128 available)
    {
        UserBalance storage balance = balances[user][currency];
        total = balance.total;
        locked = balance.locked;
        available = total - locked;
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER PLACEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a limit order at specific price
    /// @param key Pool key
    /// @param price Desired price in 18 decimals (will be rounded to nearest valid price)
    /// @param amount Order size
    /// @param isBuy True for buy order, false for sell order
    /// @return globalOrderId Unique order identifier
    function placeOrder(
        PoolKey calldata key,
        uint256 price,
        uint128 amount,
        bool isBuy
    ) external returns (uint256 globalOrderId) {
        if (amount == 0) revert InvalidAmount();

        PoolId poolId = key.toId();
        int24 tickSpacing = key.parameters.getTickSpacing();

        // Round price to valid price point with directional rounding
        // Buy orders round down (pay less), sell orders round up (receive more)
        uint256 roundedPrice = TickMath.roundPriceToValidIncrement(
            price,
            tickSpacing,
            WORDS_PER_TICK,
            isBuy
        );

        // Place order in tick book manager
        (int24 tick, uint256 priceIndex, uint32 localOrderId) = tickBooks[poolId].placeOrder(
            roundedPrice,
            amount,
            isBuy,
            msg.sender
        );

        // Derive global order ID (no storage needed!)
        globalOrderId = GlobalOrderIdLibrary.encode(
            poolId,
            tick,
            priceIndex,
            localOrderId,
            isBuy
        );

        // Transfer tokens directly to hook (hook holds them until order is filled/cancelled)
        if (isBuy) {
            // Buy order: deposit token1 (quote currency)
            uint256 cost = (uint256(amount) * roundedPrice) / 1e18;
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(
                msg.sender,
                address(this),
                cost
            );
        } else {
            // Sell order: deposit token0 (base currency)
            IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        emit OrderPlaced(globalOrderId, msg.sender, poolId, roundedPrice, amount, isBuy);

        return globalOrderId;
    }

    /// @notice Place a limit order using internal balance (gas-efficient)
    /// @dev Uses locked balance instead of token transfers - saves ~16k gas per order!
    /// @param key Pool key
    /// @param price Desired price in 18 decimals (will be rounded to nearest valid price)
    /// @param amount Order size
    /// @param isBuy True for buy order, false for sell order
    /// @return globalOrderId Unique order identifier
    function placeOrderFromBalance(
        PoolKey calldata key,
        uint256 price,
        uint128 amount,
        bool isBuy
    ) external returns (uint256 globalOrderId) {
        return _placeOrderFromBalance(key, price, amount, isBuy);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place multiple orders in a single transaction
    /// @dev Gas-efficient batch placement with single balance check
    /// @param key Pool key
    /// @param orders Array of order requests
    /// @return orderIds Array of global order IDs
    function placeOrdersBatch(
        PoolKey calldata key,
        OrderRequest[] calldata orders
    ) external returns (uint256[] memory orderIds) {
        if (orders.length == 0) revert InvalidAmount();
        
        orderIds = new uint256[](orders.length);
        
        // Calculate total balance requirements upfront
        uint256 totalToken0Needed;
        uint256 totalToken1Needed;
        
        for (uint i = 0; i < orders.length; i++) {
            if (orders[i].amount == 0) revert InvalidAmount();
            
            if (orders[i].isBuy) {
                // For buy orders, need currency1
                uint256 cost = (uint256(orders[i].amount) * orders[i].price) / 1e18;
                totalToken1Needed += cost;
            } else {
                // For sell orders, need currency0
                totalToken0Needed += orders[i].amount;
            }
        }
        
        // Single balance check for all orders
        if (totalToken0Needed > 0) {
            UserBalance storage bal0 = balances[msg.sender][key.currency0];
            if (bal0.total - bal0.locked < totalToken0Needed) {
                revert InsufficientBalance();
            }
        }
        
        if (totalToken1Needed > 0) {
            UserBalance storage bal1 = balances[msg.sender][key.currency1];
            if (bal1.total - bal1.locked < totalToken1Needed) {
                revert InsufficientBalance();
            }
        }
        
        // Place all orders
        for (uint i = 0; i < orders.length; i++) {
            orderIds[i] = _placeOrderFromBalance(
                key,
                orders[i].price,
                orders[i].amount,
                orders[i].isBuy
            );
        }
        
        emit BatchOrdersPlaced(
            msg.sender,
            key.toId(),
            orders.length,
            totalToken0Needed + totalToken1Needed
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to place order from balance
    /// @dev Shared logic for both external and batch operations
    function _placeOrderFromBalance(
        PoolKey calldata key,
        uint256 price,
        uint128 amount,
        bool isBuy
    ) internal returns (uint256 globalOrderId) {
        if (amount == 0) revert InvalidAmount();

        PoolId poolId = key.toId();
        int24 tickSpacing = key.parameters.getTickSpacing();

        // Determine which currency is needed
        Currency currency = isBuy ? key.currency1 : key.currency0;

        // Round price to valid price point with directional rounding
        uint256 roundedPrice = TickMath.roundPriceToValidIncrement(
            price,
            tickSpacing,
            WORDS_PER_TICK,
            isBuy
        );

        // Calculate required amount
        uint128 required = isBuy
            ? uint128((uint256(amount) * roundedPrice) / 1e18)
            : amount;

        // Check and lock balance (NO TRANSFER - this is the key gas saving!)
        UserBalance storage balance = balances[msg.sender][currency];
        if (balance.total - balance.locked < required) {
            revert InsufficientBalance();
        }

        // Lock the balance
        balance.locked += required;

        // Place order in tick book manager
        (int24 tick, uint256 priceIndex, uint32 localOrderId) = tickBooks[poolId].placeOrder(
            roundedPrice,
            amount,
            isBuy,
            msg.sender
        );

        // Derive global order ID (no storage needed!)
        globalOrderId = GlobalOrderIdLibrary.encode(
            poolId,
            tick,
            priceIndex,
            localOrderId,
            isBuy
        );

        emit OrderPlaced(globalOrderId, msg.sender, poolId, roundedPrice, amount, isBuy);

        return globalOrderId;
    }

    /// @notice Cancel an unfilled order
    /// @param globalOrderId Global order ID to cancel
    /// @param key Pool key for validation
    function cancelOrder(uint256 globalOrderId, PoolKey calldata key) external {
        // OPTIMIZATION 1: Use provided poolKey for lookups (more reliable)
        PoolId poolId = key.toId();
        
        // OPTIMIZATION 2: Single decode operation
        (, int24 tick, uint256 priceIndex, uint32 localOrderId, bool isBuy) 
            = GlobalOrderIdLibrary.decode(globalOrderId);
        
        // OPTIMIZATION 3: Batch storage reads - access order and metadata together
        OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];
        OrderBookTypes.Order[] storage orders = isBuy ? book.buyOrders[priceIndex] : book.sellOrders[priceIndex];
        
        // OPTIMIZATION 4: Early validation (fail fast pattern)
        require(localOrderId < orders.length, "Order not found");
        OrderBookTypes.Order storage order = orders[localOrderId];
        require(order.maker == msg.sender, "Not order maker");
        
        uint128 amountRemaining = order.amount - order.filled;
        require(amountRemaining > 0, "Already filled");
        
        // OPTIMIZATION 5: Mark cancelled immediately (prevent reentrancy)
        order.filled = order.amount;
        
        // OPTIMIZATION 6: Efficient balance handling (prefer internal balance)
        Currency currency = isBuy ? key.currency1 : key.currency0;
        uint128 refundAmount;
        
        if (isBuy) {
            // Buy order: calculate refund from precomputed config
            refundAmount = _safeCast128((uint256(amountRemaining) * 
                (tickBooks[poolId].sharedConfig.minPrice + 
                 priceIndex * tickBooks[poolId].sharedConfig.priceIncrement)) / 1e18);
        } else {
            refundAmount = amountRemaining;
        }
        
        // OPTIMIZATION 7: Single balance operation
        UserBalance storage balance = balances[msg.sender][currency];
        if (balance.locked >= refundAmount) {
            balance.locked -= refundAmount;  // Single SSTORE operation
            emit BalanceUnlocked(msg.sender, currency, refundAmount);
        } else {
            // Fallback: direct transfer (for orders placed via placeOrder)
            IERC20(Currency.unwrap(currency)).safeTransfer(msg.sender, refundAmount);
        }
        
        emit OrderCancelled(globalOrderId, msg.sender, amountRemaining);
    }

    /*//////////////////////////////////////////////////////////////
                    EXPLICIT ROUTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a swap with explicit CLOB/AMM routing amounts
    /// @param key Pool key
    /// @param amountCLOB Amount to execute via CLOB
    /// @param amountAMM Amount to execute via AMM
    /// @param isBuy Whether this is a buy order
    /// @param maxPrice Maximum price for CLOB fills (price limit)
    /// @return totalAmountOut Total amount received from both CLOB and AMM
    function swapWithExplicitRouting(
        PoolKey calldata key,
        uint128 amountCLOB,
        uint128 amountAMM,
        bool isBuy,
        uint256 maxPrice
    ) external returns (uint256 totalAmountOut) {
        PoolId poolId = key.toId();
        
        // Execute CLOB portion if specified
        uint256 clobAmountOut = 0;
        if (amountCLOB > 0) {
            int24 currentTick = _getTick(poolId);
            
            OrderBookTypes.MatchResult memory matched = tickBooks[poolId].matchMarketOrderWithLimit(
                poolId,
                isBuy,
                amountCLOB,
                currentTick,
                maxPrice
            );
            
            // Process CLOB fills
            if (matched.amountFilled > 0) {
                _processFillsBatched(matched, key, isBuy, msg.sender);
                clobAmountOut = matched.amountFilled;
                
                // Emit CLOB execution event
                emit HybridExecutionSummary(
                    poolId,
                    msg.sender,
                    matched.amountFilled,
                    matched.ordersMatched,
                    matched.avgPrice,
                    0 // No surplus calculation for explicit routing
                );
            }
        }
        
        // Execute AMM portion if specified
        uint256 ammAmountOut = 0;
        if (amountAMM > 0) {
            ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
                zeroForOne: !isBuy,
                amountSpecified: int256(uint256(amountAMM)),
                sqrtPriceLimitX96: isBuy ? type(uint160).max : 1
            });
            
            BalanceDelta delta = poolManager.swap(key, params, "");
            ammAmountOut = uint256(int256(isBuy ? delta.amount0() : -delta.amount1()));
        }
        
        totalAmountOut = clobAmountOut + ammAmountOut;
        
        emit ExplicitRoutingExecuted(
            poolId,
            msg.sender,
            amountCLOB,
            amountAMM,
            clobAmountOut,
            ammAmountOut
        );
    }

    /// @notice Get optimal CLOB/AMM routing for a given trade size
    /// @param key Pool key
    /// @param amount Total amount to trade
    /// @param isBuy Whether this is a buy order
    /// @return clobAmount Recommended amount for CLOB
    /// @return ammAmount Recommended amount for AMM
    /// @return expectedPrice Expected average execution price
    function getOptimalRouting(
        PoolKey calldata key,
        uint128 amount,
        bool isBuy
    ) external view returns (uint128 clobAmount, uint128 ammAmount, uint256 expectedPrice) {
        PoolId poolId = key.toId();
        
        // Get current AMM price for comparison
        uint256 ammPrice = _getEstimatedAMMPrice(poolId);
        
        // Quick CLOB depth check
        uint256 availableCLOBRaw = _getFastCLOBDepth(poolId, isBuy, ammPrice, amount);
        uint128 availableCLOB = availableCLOBRaw > type(uint128).max ? type(uint128).max : uint128(availableCLOBRaw);
        
        if (availableCLOB >= amount) {
            // Full CLOB execution possible
            clobAmount = amount;
            ammAmount = 0;
            expectedPrice = ammPrice; // Simplified - actual would be better
        } else if (availableCLOB > amount / 4) {
            // Hybrid execution beneficial
            clobAmount = availableCLOB;
            ammAmount = amount - availableCLOB;
            expectedPrice = (ammPrice * 99) / 100; // ~1% improvement estimate
        } else {
            // Pure AMM execution
            clobAmount = 0;
            ammAmount = amount;
            expectedPrice = ammPrice;
        }
    }

    /// @notice Cancel multiple orders in a single transaction
    /// @param orderIds Array of global order IDs to cancel
    /// @param key Pool key for validation
    function cancelOrdersBatch(uint256[] calldata orderIds, PoolKey calldata key) external {
        uint256 length = orderIds.length;
        require(length > 0 && length <= 50, "Invalid batch size"); // Reasonable limit
        
        for (uint256 i = 0; i < length; i++) {
            this.cancelOrder(orderIds[i], key);
        }
    }

    /// @notice Gas-optimized batch cancellation with packed data
    /// @param packedOrderIds Packed uint256 array to reduce calldata costs
    /// @param key Pool key for validation
    function cancelOrdersBatchPacked(
        bytes calldata packedOrderIds,  // Packed uint256 array
        PoolKey calldata key
    ) external {
        // Decode packed data in chunks to save calldata costs
        uint256 orderCount = packedOrderIds.length / 32;
        require(orderCount > 0 && orderCount <= 50, "Invalid batch size");
        
        for (uint256 i = 0; i < orderCount; i++) {
            uint256 orderId;
            assembly {
                orderId := calldataload(add(packedOrderIds.offset, mul(i, 32)))
            }
            this.cancelOrder(orderId, key);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get best ask price (lowest sell order)
    function getBestAsk(PoolKey calldata key)
        external
        view
        returns (int24 tick, uint256 price)
    {
        PoolId poolId = key.toId();
        int24 currentTick = _getTick(poolId);
        return tickBooks[poolId].getBestAsk(currentTick);
    }

    /// @notice Get best bid price (highest buy order)
    function getBestBid(PoolKey calldata key)
        external
        view
        returns (int24 tick, uint256 price)
    {
        PoolId poolId = key.toId();
        int24 currentTick = _getTick(poolId);
        return tickBooks[poolId].getBestBid(currentTick);
    }

    /// @notice Get order book depth at a specific tick
    function getTickDepth(PoolKey calldata key, int24 tick, bool isBuy)
        external
        view
        returns (uint128 totalAmount, uint256 orderCount)
    {
        PoolId poolId = key.toId();
        return tickBooks[poolId].getTickDepth(tick, isBuy);
    }

    /// @notice Get order details by decoding the global order ID
    /// @dev Returns the order from the order book directly
    /// @param globalOrderId The global order ID to decode
    /// @param key The pool key for validation
    /// @return order The order struct from the order book
    function getOrder(
        uint256 globalOrderId,
        PoolKey calldata key
    ) external view returns (OrderBookTypes.Order memory order) {
        // Decode global order ID
        (
            PoolId decodedPoolId,
            int24 tick,
            uint256 priceIndex,
            uint32 localOrderId,
            bool isBuy
        ) = GlobalOrderIdLibrary.decode(globalOrderId);

        // Verify pool matches (compare lower 160 bits since encode truncates to uint160)
        PoolId poolId = key.toId();
        uint160 poolIdLower = uint160(uint256(PoolId.unwrap(poolId)));
        uint160 decodedPoolIdLower = uint160(uint256(PoolId.unwrap(decodedPoolId)));
        require(poolIdLower == decodedPoolIdLower, "Pool mismatch");

        // Get the order from the book
        OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];
        OrderBookTypes.Order[] storage orders = isBuy ? book.buyOrders[priceIndex] : book.sellOrders[priceIndex];

        require(localOrderId < orders.length, "Order not found");
        order = orders[localOrderId];
    }


    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current tick from pool
    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @notice Get tick lower bound (aligned to tick spacing)
    function _getTickLower(int24 tick, int24 tickSpacing)
        internal
        pure
        returns (int24)
    {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Get current AMM price for routing decisions
    /// @dev Uses current sqrtPriceX96 from pool state
    /// @param poolId Pool identifier
    /// @return price Current price in 18 decimals (token1/token0)
    function _getAMMPrice(PoolId poolId) internal view returns (uint256 price) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        price = TickMath.sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Construct BeforeSwapDelta from specified and unspecified amounts
    function _toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
        internal
        pure
        returns (BeforeSwapDelta)
    {
        return toBeforeSwapDelta(deltaSpecified, deltaUnspecified);
    }

    /// @notice Get current sqrtPriceX96 from pool
    function _getSqrtPriceX96(PoolId poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    /// @notice Calculate effective AMM price from swap delta
    /// @dev Calculates how much was paid per unit received
    /// @param delta The swap delta (amount0, amount1)
    /// @param isBuy True if buying token0
    /// @return price Effective execution price in 18 decimals
    function _calculateAMMPrice(BalanceDelta delta, bool isBuy) internal pure returns (uint256 price) {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (isBuy) {
            // Buying token0 with token1
            // Received: amount0 (positive)
            // Paid: amount1 (negative)
            uint256 received = uint256(int256(amount0));
            uint256 paid = uint256(int256(-amount1));

            // price = paid / received (in 18 decimals)
            price = (paid * 1e18) / received;
        } else {
            // Selling token0 for token1
            // Paid: amount0 (negative)
            // Received: amount1 (positive)
            uint256 paid = uint256(int256(-amount0));
            uint256 received = uint256(int256(amount1));

            // price = received / paid (in 18 decimals)
            price = (received * 1e18) / paid;
        }
    }

    /// @notice Calculate total cost from swap delta
    /// @dev Extracts how much input currency was spent
    /// @param delta The swap delta (amount0, amount1)
    /// @param isBuy True if buying token0
    /// @return cost Total input currency spent
    function _calculateAMMCost(BalanceDelta delta, bool isBuy) internal pure returns (uint256 cost) {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (isBuy) {
            // Buying token0 with token1
            // Cost is amount1 (negative, so negate)
            cost = uint256(int256(-amount1));
        } else {
            // Selling token0 for token1
            // Cost is amount0 (negative, so negate)
            cost = uint256(int256(-amount0));
        }
    }

    /// @notice Simulate AMM swap to get expected price and cost
    /// @dev Uses current pool price as approximation (simple but ~90% accurate)
    /// @param poolId Pool identifier
    /// @param amountWanted Amount user wants to swap
    /// @return sim Simulated AMM execution results
    function _simulateAMMSwap(
        PoolId poolId,
        uint128 amountWanted
    ) internal view returns (SwapSimulation memory sim) {
        // Get current AMM price
        sim.ammPrice = _getAMMPrice(poolId);

        // Estimate cost using current price
        // Note: This is approximation - actual AMM price will shift during swap
        // For more accuracy, would need to replicate CLPool.SwapMath
        sim.ammCost = (uint256(amountWanted) * sim.ammPrice) / 1e18;
    }

    /// @notice Calculate taker surplus from CLOB execution
    /// @dev Surplus = AMM cost - actual execution cost (CLOB + AMM remainder)
    /// @param ammCost Total cost if AMM executed everything
    /// @param matched Match result from CLOB
    /// @param actualAmount Total amount swapped
    /// @param actualAMMPrice Actual AMM price from delta
    /// @return surplus Amount to refund taker (in input currency)
    function _calculateTakerSurplus(
        uint256 ammCost,
        OrderBookTypes.MatchResult memory matched,
        uint128 actualAmount,
        uint256 actualAMMPrice
    ) internal pure returns (uint256 surplus) {
        // If no CLOB matches, no surplus
        if (matched.amountFilled == 0) {
            return 0;
        }

        // Calculate CLOB cost: sum of (filledAmount * fillPrice) for all fills
        // This is already calculated in matched.totalCost
        uint256 clobCost = matched.totalCost;

        // Calculate AMM portion cost (for amount NOT filled by CLOB)
        uint128 ammPortion = actualAmount - matched.amountFilled;
        uint256 ammPortionCost = (uint256(ammPortion) * actualAMMPrice) / 1e18;

        // Total actual execution cost
        uint256 actualCost = clobCost + ammPortionCost;

        // Surplus = what taker paid (AMM) - what they should pay (actual)
        // This should always be >= 0 due to price-limit matching
        if (ammCost > actualCost) {
            surplus = ammCost - actualCost;
        } else {
            surplus = 0;
        }
    }

    /// @notice Analyze order book to find available CLOB liquidity (READ-ONLY)
    /// @dev Does NOT modify order book state - pure view function
    /// @param poolId Pool identifier
    /// @param isBuy True for buying token0 (match sell orders)
    /// @param amountWanted Amount user wants
    /// @param ammPrice AMM execution price limit
    /// @return analysis Order book analysis results
    function _analyzeOrderBook(
        PoolId poolId,
        bool isBuy,
        uint128 amountWanted,
        uint256 ammPrice
    ) internal view returns (OrderBookAnalysis memory analysis) {
        int24 currentTick = _getTick(poolId);
        int24 tickSpacing = tickBooks[poolId].tickSpacing;

        if (isBuy) {
            // Buying token0: find sell orders with price <= ammPrice
            analysis = _analyzeSellOrders(poolId, currentTick, tickSpacing, amountWanted, ammPrice);
        } else {
            // Selling token0: find buy orders with price >= ammPrice
            analysis = _analyzeBuyOrders(poolId, currentTick, tickSpacing, amountWanted, ammPrice);
        }

        // Determine if CLOB is worth using
        if (analysis.totalAvailable > 0) {
            if (isBuy) {
                // For buys: CLOB better if avgPrice < ammPrice
                analysis.worthUsing = analysis.avgPrice < ammPrice;
            } else {
                // For sells: CLOB better if avgPrice > ammPrice
                analysis.worthUsing = analysis.avgPrice > ammPrice;
            }
        }
    }

    /// @notice Analyze sell orders (for buy swaps) - READ-ONLY
    function _analyzeSellOrders(
        PoolId poolId,
        int24 currentTick,
        int24 tickSpacing,
        uint128 amountWanted,
        uint256 ammPrice
    ) internal view returns (OrderBookAnalysis memory analysis) {
        uint128 accumulated = 0;
        uint256 totalCost = 0;
        uint256 ordersFound = 0;

        // For buying: start from lowest sell orders (best ask) and go up
        // Use a reasonable minimum tick (not type(int24).min which can overflow in TickBitmap)
        // Start from low tick to catch all orders (orders could be placed far below current price)
        int24 searchStart = int24(-100000);  // Safe minimum
        int24 tick = tickBooks[poolId].activeSellTicks.nextActiveTickGTE(
            searchStart,
            tickSpacing
        );

        uint8 ticksScanned = 0;
        uint8 MAX_TICKS = 20;  // Gas safety limit

        while (
            tick != type(int24).max &&
            accumulated < amountWanted &&
            ticksScanned < MAX_TICKS
        ) {
            OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];

            if (book.initialized) {
                // Get best ask price at this tick
                uint256 bestAskIndex = book.getBestAsk(tickBooks[poolId].sharedConfig);

                if (bestAskIndex != type(uint256).max) {
                    // Convert index to actual price
                    uint256 orderPrice = FenwickOrderBook.indexToPrice(tickBooks[poolId].sharedConfig, bestAskIndex);

                    // Stop if price worse than AMM
                    if (orderPrice > ammPrice) {
                        break;
                    }

                    // Get depth at this price level
                    // Note: For now we'll estimate based on tree depth
                    // TODO: Implement exact getDepthAtPrice in FenwickOrderBook
                    uint128 available = book.getTotalDepth(tickBooks[poolId].sharedConfig, false); // Approximate

                    if (available > 0) {
                        // Take what we need
                        uint128 toTake = amountWanted - accumulated;
                        if (toTake > available) toTake = available;

                        accumulated += toTake;
                        totalCost += (uint256(toTake) * orderPrice) / 1e18;
                        ordersFound++;
                    }
                }
            }

            // Move to next active tick
            tick = tickBooks[poolId].activeSellTicks.nextActiveTickGTE(
                tick + tickSpacing,
                tickSpacing
            );
            ticksScanned++;
        }

        analysis.totalAvailable = accumulated;
        analysis.avgPrice = accumulated > 0 ? (totalCost * 1e18) / accumulated : 0;
        analysis.totalCost = totalCost;
        analysis.ordersFound = ordersFound;
    }

    /// @notice Analyze buy orders (for sell swaps) - READ-ONLY
    function _analyzeBuyOrders(
        PoolId poolId,
        int24 currentTick,
        int24 tickSpacing,
        uint128 amountWanted,
        uint256 ammPrice
    ) internal view returns (OrderBookAnalysis memory analysis) {
        uint128 accumulated = 0;
        uint256 totalProceeds = 0;  // For sells, we track proceeds not cost
        uint256 ordersFound = 0;

        // For selling: start from highest buy orders (best bid) and go down
        // Start from a high tick to find all buy orders (they could be placed above current price)
        int24 searchStart = int24(800000);  // Safe maximum
        int24 tick = tickBooks[poolId].activeBuyTicks.nextActiveTickLTE(
            searchStart,
            tickSpacing
        );

        uint8 ticksScanned = 0;
        uint8 MAX_TICKS = 20;

        while (
            tick != type(int24).min &&
            accumulated < amountWanted &&
            ticksScanned < MAX_TICKS
        ) {
            OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];

            if (book.initialized) {
                // Get best bid price at this tick
                uint256 bestBidIndex = book.getBestBid(tickBooks[poolId].sharedConfig);

                if (bestBidIndex != type(uint256).max) {
                    uint256 orderPrice = FenwickOrderBook.indexToPrice(tickBooks[poolId].sharedConfig, bestBidIndex);

                    // Stop if price worse than AMM
                    if (orderPrice < ammPrice) break;

                    // Get depth
                    uint128 available = book.getTotalDepth(tickBooks[poolId].sharedConfig, true); // Approximate

                    if (available > 0) {
                        uint128 toTake = amountWanted - accumulated;
                        if (toTake > available) toTake = available;

                        accumulated += toTake;
                        totalProceeds += (uint256(toTake) * orderPrice) / 1e18;
                        ordersFound++;
                    }
                }
            }

            // Move to previous tick
            tick = tickBooks[poolId].activeBuyTicks.nextActiveTickLTE(
                tick - tickSpacing,
                tickSpacing
            );
            ticksScanned++;
        }

        analysis.totalAvailable = accumulated;
        analysis.avgPrice = accumulated > 0 ? (totalProceeds * 1e18) / accumulated : 0;
        analysis.totalCost = totalProceeds;  // For consistency with struct naming
        analysis.ordersFound = ordersFound;
    }

    /// ⭐ OPTIMIZATION: Combined AMM simulation + CLOB analysis for faster routing
    function _analyzeOptimalRouting(
        PoolId poolId,
        bool isBuy,
        uint128 amountWanted,
        address sender
    ) internal view returns (RoutingDecision memory decision) {
        // Step 1: Quick AMM price estimation
        uint256 ammPrice = _getEstimatedAMMPrice(poolId);
        
        // Step 2: Fast CLOB depth check with early exit optimization
        uint256 clobDepth = _getFastCLOBDepth(poolId, isBuy, ammPrice, amountWanted);
        
        if (clobDepth == 0) {
            // No CLOB liquidity - use pure AMM
            decision.useCLOB = false;
            decision.clobAmount = 0;
            decision.estimatedSavings = 0;
            decision.priceThreshold = 0;
            return decision;
        }
        
        // Step 3: Calculate if CLOB usage is profitable  
        uint128 clobAmount = clobDepth >= amountWanted ? amountWanted : uint128(clobDepth);
        
        // Use more lenient profitability check - any CLOB liquidity is worth considering
        // The actual price-limit matching will filter out expensive orders
        bool isProfitable = clobAmount > 0; // Any CLOB liquidity available
        
        if (isProfitable) {
            decision.useCLOB = true;
            decision.clobAmount = clobAmount;
            decision.priceThreshold = ammPrice; // Use AMM price as limit
            decision.estimatedSavings = 0; // Calculated in afterSwap with actual data
        } else {
            decision.useCLOB = false;
            decision.clobAmount = 0;
            decision.estimatedSavings = 0;
            decision.priceThreshold = 0;
        }
    }

    /// ⭐ OPTIMIZATION: Fast AMM price estimation (avoids complex simulation)
    function _getEstimatedAMMPrice(PoolId poolId) internal view returns (uint256 price) {
        // Get current pool state
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        
        // Convert sqrt price to regular price (proper calculation)
        // sqrtPriceX96 = sqrt(price) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2
        
        if (sqrtPriceX96 == 0) {
            return 1e18; // Default 1:1 if no price set
        }
        
        // FIXED: Safe calculation avoiding overflow
        // Price = (sqrtPriceX96 / 2^96)^2 * 10^18
        
        if (sqrtPriceX96 <= type(uint128).max) {
            // For smaller prices, direct calculation
            uint256 sqrtPrice = uint256(sqrtPriceX96);
            price = (sqrtPrice * sqrtPrice * 1e18) >> 192;
        } else {
            // For larger prices, intermediate scaling
            uint256 sqrtPrice = uint256(sqrtPriceX96) >> 48;
            price = (sqrtPrice * sqrtPrice * 1e18) >> 96;
        }
        
        // Ensure minimum price to avoid division by zero issues
        if (price == 0) price = 1;
    }

    /// @notice Validates price is within safe operational range
    function _validatePriceRange(uint256 price) internal pure {
        require(price >= 1e6 && price <= 1e30, "Price out of safe range");
    }

    /// @notice Safe cast to uint128 with overflow protection
    function _safeCast128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "Value exceeds uint128");
        return uint128(value);
    }

    /// ⭐ OPTIMIZATION: Fast CLOB depth check with early exit
    function _getFastCLOBDepth(
        PoolId poolId,
        bool isBuy,
        uint256 ammPrice,
        uint128 maxAmount
    ) internal view returns (uint256 totalDepth) {
        TickOrderBookManager.TickBooks storage books = tickBooks[poolId];
        if (!books.initialized) return 0;
        
        // Quick check: scan more ticks to catch cross-tick orders
        uint8 MAX_QUICK_TICKS = 15; // Balance between gas and coverage
        uint8 ticksScanned = 0;
        uint128 accumulated = 0;
        
        if (isBuy) {
            // For buys: check sell orders starting from best prices
            int24 tick = books.activeSellTicks.nextActiveTickGTE(-887272, books.tickSpacing);
            
            while (tick != type(int24).max && ticksScanned < MAX_QUICK_TICKS) {
                OrderBookTypes.Book storage book = books.books[tick];
                
                if (book.initialized) {
                    uint256 bestPriceIndex = book.getBestAsk(books.sharedConfig);
                    
                    if (bestPriceIndex != type(uint256).max) {
                        uint256 orderPrice = FenwickOrderBook.indexToPrice(books.sharedConfig, bestPriceIndex);
                        
                        // Early exit if price too expensive
                        if (orderPrice > ammPrice) break;
                        
                        // Estimate liquidity at this tick (simplified)
                        uint128 tickDepth = book.getTotalDepth(books.sharedConfig, false);
                        accumulated += tickDepth;
                        
                        // Early exit if we have enough
                        if (accumulated >= maxAmount) {
                            return maxAmount;
                        }
                    }
                }
                
                tick = books.activeSellTicks.nextActiveTickGTE(tick + books.tickSpacing, books.tickSpacing);
                ticksScanned++;
            }
        } else {
            // Similar logic for sells (buy orders)
            int24 tick = books.activeBuyTicks.nextActiveTickLTE(887272, books.tickSpacing);
            
            while (tick != type(int24).min && ticksScanned < MAX_QUICK_TICKS) {
                OrderBookTypes.Book storage book = books.books[tick];
                
                if (book.initialized) {
                    uint256 bestPriceIndex = book.getBestBid(books.sharedConfig);
                    
                    if (bestPriceIndex != type(uint256).max) {
                        uint256 orderPrice = FenwickOrderBook.indexToPrice(books.sharedConfig, bestPriceIndex);
                        
                        if (orderPrice < ammPrice) break;
                        
                        uint128 tickDepth = book.getTotalDepth(books.sharedConfig, true);
                        accumulated += tickDepth;
                        
                        if (accumulated >= maxAmount) {
                            return maxAmount;
                        }
                    }
                }
                
                tick = books.activeBuyTicks.nextActiveTickLTE(tick - books.tickSpacing, books.tickSpacing);
                ticksScanned++;
            }
        }
        
        return accumulated;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPTH QUERIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Get order book depth up to a price limit
    /// @param poolId Pool identifier
    /// @param priceLimit Maximum price to consider
    /// @param isBuy True for buy side depth, false for sell side
    /// @return totalDepth Total liquidity available up to price limit
    function getDepthUpToPrice(
        PoolId poolId,
        uint256 priceLimit,
        bool isBuy
    ) external view returns (uint256 totalDepth) {
        int24 currentTick = _getTick(poolId);
        int24 tickSpacing = tickBooks[poolId].tickSpacing;
        
        // For buys, scan sell orders (ascending price)
        // For sells, scan buy orders (descending price)
        int24 startTick = isBuy ? currentTick : currentTick - tickSpacing;
        int24 endTick = isBuy ? currentTick + tickSpacing * 10 : currentTick - tickSpacing * 10;
        int24 direction = isBuy ? tickSpacing : -tickSpacing;
        
        for (int24 tick = startTick; isBuy ? tick <= endTick : tick >= endTick; tick += direction) {
            
            OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];
            if (!book.initialized) continue;
            
            // Get tick price range
            uint160 sqrtPriceX96 = CoreTickMath.getSqrtRatioAtTick(tick);
            uint256 tickBasePrice = TickMath.sqrtPriceX96ToPrice(sqrtPriceX96);
            
            // Check if tick is beyond price limit
            if (isBuy && tickBasePrice > priceLimit) break;
            if (!isBuy && tickBasePrice < priceLimit) break;
            
            // Sum depth at this tick
            uint256 tickDepth = _getTickDepthWithLimit(
                book,
                tickBooks[poolId].sharedConfig,
                priceLimit,
                isBuy
            );
            
            totalDepth += tickDepth;
        }
    }

    /// @notice Get best bid and ask prices
    /// @param poolId Pool identifier  
    /// @return bestBid Highest buy order price (0 if no bids)
    /// @return bestAsk Lowest sell order price (0 if no asks)
    function getBestBidAsk(PoolId poolId) 
        external 
        view 
        returns (uint256 bestBid, uint256 bestAsk) 
    {
        int24 currentTick = _getTick(poolId);
        int24 tickSpacing = tickBooks[poolId].tickSpacing;
        
        // Find best bid (highest buy price)
        bestBid = _findBestPrice(poolId, currentTick, tickSpacing, true);
        
        // Find best ask (lowest sell price)
        bestAsk = _findBestPrice(poolId, currentTick, tickSpacing, false);
    }


    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get depth at a tick up to price limit
    function _getTickDepthWithLimit(
        OrderBookTypes.Book storage book,
        OrderBookTypes.Config storage config,
        uint256 priceLimit,
        bool isBuy
    ) internal view returns (uint256 depth) {
        // For buy side, check sell orders
        // For sell side, check buy orders
        mapping(uint256 => OrderBookTypes.Order[]) storage orders = 
            isBuy ? book.sellOrders : book.buyOrders;
        
        uint256 startIndex = isBuy ? 0 : config.numPricePoints - 1;
        uint256 endIndex = isBuy ? config.numPricePoints : 0;
        
        for (
            uint256 i = startIndex; 
            isBuy ? i < endIndex : i >= endIndex; 
            i = isBuy ? i + 1 : i - 1
        ) {
            uint256 price = FenwickOrderBook.indexToPrice(config, i);
            
            // Check price limit
            if (isBuy && price > priceLimit) break;
            if (!isBuy && price < priceLimit) break;
            
            // Sum unfilled amounts at this price
            OrderBookTypes.Order[] storage priceOrders = orders[i];
            for (uint j = 0; j < priceOrders.length; j++) {
                depth += priceOrders[j].amount - priceOrders[j].filled;
            }
            
            if (!isBuy && i == 0) break; // Prevent underflow
        }
    }

    /// @notice Find best price in order book
    function _findBestPrice(
        PoolId poolId,
        int24 currentTick,
        int24 tickSpacing,
        bool isBuy
    ) internal view returns (uint256 bestPrice) {
        // For buy orders, scan downward from current tick
        // For sell orders, scan upward from current tick
        int24 startTick = isBuy ? currentTick - tickSpacing : currentTick;
        int24 endTick = isBuy ? currentTick - tickSpacing * 10 : currentTick + tickSpacing * 10;
        int24 direction = isBuy ? -tickSpacing : tickSpacing;
        
        for (int24 tick = startTick; isBuy ? tick >= endTick : tick <= endTick; tick += direction) {
            
            OrderBookTypes.Book storage book = tickBooks[poolId].books[tick];
            if (!book.initialized) continue;
            
            if (isBuy) {
                // Find highest buy price
                uint256 bestIndex = book.getBestBid(tickBooks[poolId].sharedConfig);
                if (bestIndex != type(uint256).max) {
                    bestPrice = FenwickOrderBook.indexToPrice(
                        tickBooks[poolId].sharedConfig,
                        bestIndex
                    );
                    break;
                }
            } else {
                // Find lowest sell price
                uint256 bestIndex = book.getBestAsk(tickBooks[poolId].sharedConfig);
                if (bestIndex != type(uint256).max) {
                    bestPrice = FenwickOrderBook.indexToPrice(
                        tickBooks[poolId].sharedConfig,
                        bestIndex
                    );
                    break;
                }
            }
        }
    }
}
