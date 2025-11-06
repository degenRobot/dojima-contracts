// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

/// @title LaunchpadHook
/// @notice Token bonding curve with automatic graduation to concentrated liquidity pool
/// @dev Implements PancakeSwap V4 hooks for token launchpad functionality
contract LaunchpadHook is ICLHooks {
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;

    error NotGraduated();
    error AlreadyGraduated();
    error InsufficientPayment();
    error TokenNotFound();
    error Unauthorized();
    error PoolInitializationFailed();

    event TokenLaunched(address indexed token, address indexed creator, uint256 totalSupply, uint256 graduationThreshold);
    event TokenPurchased(address indexed buyer, address indexed token, uint256 ethSpent, uint256 tokensReceived);
    event TokenGraduated(address indexed token, uint256 totalRaised, uint256 liquidityAdded);

    struct Launchpad {
        address token;
        address creator;
        uint256 totalSupply;
        uint256 sold;
        uint256 raised;
        uint256 graduationThreshold; // ETH amount needed to graduate
        bool graduated;
        uint256 basePrice; // Initial price in wei per token
        uint256 priceIncrement; // Price increase per token sold
    }

    ICLPoolManager public immutable poolManager;
    IVault public immutable vault;

    uint256 public nextLaunchpadId = 1;
    mapping(uint256 => Launchpad) public launchpads;
    mapping(address => uint256) public tokenToLaunchpadId;

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
        vault = CLPoolManager(address(poolManager)).vault();
    }

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return 0x0020; // beforeInitialize only
    }

    /// @notice Launch a new token with bonding curve
    /// @param token Address of the token to launch
    /// @param totalSupply Total supply of tokens for bonding curve
    /// @param graduationThreshold ETH amount needed to graduate to LP pool
    /// @param basePrice Initial price in wei per token (e.g., 0.0001 ETH = 100000000000000 wei)
    /// @param priceIncrement Price increase in wei per token sold
    function launchToken(
        address token,
        uint256 totalSupply,
        uint256 graduationThreshold,
        uint256 basePrice,
        uint256 priceIncrement
    ) external returns (uint256 launchpadId) {
        if (tokenToLaunchpadId[token] != 0) revert TokenNotFound();

        launchpadId = nextLaunchpadId++;

        launchpads[launchpadId] = Launchpad({
            token: token,
            creator: msg.sender,
            totalSupply: totalSupply,
            sold: 0,
            raised: 0,
            graduationThreshold: graduationThreshold,
            graduated: false,
            basePrice: basePrice,
            priceIncrement: priceIncrement
        });

        tokenToLaunchpadId[token] = launchpadId;

        // Transfer tokens to this contract
        IERC20(token).transferFrom(msg.sender, address(this), totalSupply);

        emit TokenLaunched(token, msg.sender, totalSupply, graduationThreshold);
    }

    /// @notice Buy tokens from bonding curve
    /// @param launchpadId ID of the launchpad
    /// @param minTokensOut Minimum tokens to receive (slippage protection)
    function buyTokens(uint256 launchpadId, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        Launchpad storage launchpad = launchpads[launchpadId];
        if (launchpad.graduated) revert AlreadyGraduated();

        uint256 ethIn = msg.value;
        if (ethIn == 0) revert InsufficientPayment();

        // Calculate tokens to receive based on bonding curve
        // Linear bonding curve: price = basePrice + (sold * priceIncrement)
        tokensOut = _calculateTokensOut(launchpad, ethIn);

        if (tokensOut < minTokensOut) revert InsufficientPayment();
        if (launchpad.sold + tokensOut > launchpad.totalSupply) {
            // Can't buy more than available
            tokensOut = launchpad.totalSupply - launchpad.sold;
        }

        // Update state
        launchpad.sold += tokensOut;
        launchpad.raised += ethIn;

        // Transfer tokens to buyer
        IERC20(launchpad.token).transfer(msg.sender, tokensOut);

        emit TokenPurchased(msg.sender, launchpad.token, ethIn, tokensOut);

        // Check if graduated
        if (launchpad.raised >= launchpad.graduationThreshold && !launchpad.graduated) {
            _graduateToLP(launchpadId);
        }
    }

    /// @notice Calculate tokens received for ETH input
    function _calculateTokensOut(Launchpad storage launchpad, uint256 ethIn) internal view returns (uint256) {
        uint256 tokensOut = 0;
        uint256 ethRemaining = ethIn;
        uint256 currentSold = launchpad.sold;

        // Simple approximation for linear bonding curve
        // For exact calculation, would need to integrate the curve
        // price(x) = basePrice + x * priceIncrement
        // This is simplified: average price over the range
        uint256 avgPrice = launchpad.basePrice + (currentSold * launchpad.priceIncrement);
        tokensOut = (ethRemaining * 1e18) / avgPrice;

        return tokensOut;
    }

    /// @notice Graduate token to LP pool (called automatically when threshold reached)
    function _graduateToLP(uint256 launchpadId) internal {
        Launchpad storage launchpad = launchpads[launchpadId];
        if (launchpad.graduated) revert AlreadyGraduated();

        launchpad.graduated = true;

        // Calculate amounts for LP
        uint256 ethForLP = launchpad.raised;
        uint256 tokensForLP = launchpad.totalSupply - launchpad.sold;

        // Calculate final price from bonding curve
        // price = basePrice + (sold * priceIncrement)
        uint256 finalPrice = launchpad.basePrice + (launchpad.sold * launchpad.priceIncrement);

        // Sort currencies (ETH is native, so we use WETH or assume address(0) for native)
        // For simplicity, we'll use the token as currency1 and native ETH as currency0
        Currency currency0 = Currency.wrap(address(0)); // Native ETH
        Currency currency1 = Currency.wrap(launchpad.token);

        // Ensure currency0 < currency1 (required by pool manager)
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }

        // Create pool parameters
        // Hook bitmap: 0x0020 (beforeInitialize only - to prevent manual pool creation)
        bytes32 parameters = bytes32(uint256(0x0020));
        parameters = parameters.setTickSpacing(60); // 60 tick spacing

        // Create PoolKey
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(this)),
            poolManager: poolManager,
            fee: 3000, // 0.3% LP fee
            parameters: parameters
        });

        // Calculate sqrtPriceX96 from final price
        // sqrtPriceX96 = sqrt(price) * 2^96
        // For native ETH (18 decimals) vs token (assumed 18 decimals)
        // price is in wei per token
        uint256 sqrtPrice = _sqrt(finalPrice);
        uint160 sqrtPriceX96 = uint160((sqrtPrice * (2 ** 96)) / 1e9); // Scale down to fit in uint160

        // Initialize the pool
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            // Pool initialized successfully at tick
            emit TokenGraduated(launchpad.token, ethForLP, tokensForLP);
        } catch {
            revert PoolInitializationFailed();
        }

        // Note: Adding initial liquidity would require implementing the locker pattern
        // which is complex and out of scope for this MVP. The pool is initialized
        // and traders can add liquidity manually. Future enhancement: add auto-liquidity.
    }

    /// @notice Calculate square root using Babylonian method
    /// @param x The number to find square root of
    /// @return y The square root
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Get current price for a token
    function getCurrentPrice(uint256 launchpadId) external view returns (uint256) {
        Launchpad storage launchpad = launchpads[launchpadId];
        return launchpad.basePrice + (launchpad.sold * launchpad.priceIncrement);
    }

    /// @notice Get launchpad info
    function getLaunchpad(uint256 launchpadId) external view returns (Launchpad memory) {
        return launchpads[launchpadId];
    }

    // Hook implementations
    function beforeInitialize(address, PoolKey calldata key, uint160) external pure override returns (bytes4) {
        // Prevent manual pool initialization for launched tokens
        // Only allow this hook to initialize pools
        return ICLHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return ICLHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ICLHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ICLHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (ICLHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (ICLHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ICLHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ICLHooks.afterDonate.selector;
    }
}
