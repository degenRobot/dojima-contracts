// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {DojimaHybridHook} from "../../src/dojima/DojimaHybridHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

/// @title Setup
/// @notice Consolidated test setup for all Dojima tests
/// @dev Provides shared infrastructure following tokenized-strategy patterns
contract Setup is Test {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /*//////////////////////////////////////////////////////////////
                        CALLBACK TYPES
    //////////////////////////////////////////////////////////////*/

    enum CallbackAction {
        ModifyLiquidity,
        Swap
    }

    struct CallbackData {
        CallbackAction action;
        address sender;
        PoolKey key;
        ICLPoolManager.ModifyLiquidityParams modifyLiquidityParams;
        ICLPoolManager.SwapParams swapParams;
    }

    struct SwapCallbackData {
        PoolKey key;
        ICLPoolManager.SwapParams params;
        address sender;
    }

    /*//////////////////////////////////////////////////////////////
                        CONTRACTS & ADDRESSES
    //////////////////////////////////////////////////////////////*/

    // Core contracts
    DojimaHybridHook public hook;
    MockERC20 public token0;
    MockERC20 public token1;

    // RISE Testnet contracts (deployed)
    ICLPoolManager public poolManager = ICLPoolManager(0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f);
    IVault public vault = IVault(0xf93C3641dD8668Fcd54Cf9C4d365DBb9e97527de);

    // Pool configuration
    PoolKey public poolKey;
    PoolId public poolId;

    /*//////////////////////////////////////////////////////////////
                        TEST ACTORS
    //////////////////////////////////////////////////////////////*/

    // Base actors (from Setup.sol)
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
    address public taker = makeAddr("taker");
    address public keeper = makeAddr("keeper");

    // Dojima-specific actors (from DojimaSetup.sol)
    address public maker1 = makeAddr("maker1");
    address public maker2 = makeAddr("maker2");
    address public maker3 = makeAddr("maker3");
    address public taker1 = makeAddr("taker1");
    address public taker2 = makeAddr("taker2");

    // Additional actors for comprehensive testing
    address public liquidityProvider = makeAddr("liquidityProvider");
    address public carol = makeAddr("carol");

    /*//////////////////////////////////////////////////////////////
                        CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint24 public constant FEE = 3000; // 0.3%
    int24 public constant TICK_SPACING = 60;
    uint160 public constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // price = 1.0

    // Fuzz bounds
    uint256 public constant MIN_FUZZ_AMOUNT = 0.01 ether;
    uint256 public constant MAX_FUZZ_AMOUNT = 1000 ether;

    // Gas measurement
    uint256 public gasSnapshot;

    /*//////////////////////////////////////////////////////////////
                        SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // Fork RISE testnet
        vm.createSelectFork("https://testnet.riselabs.xyz");

        // Deploy tokens
        _deployTokens();

        // Deploy hook
        _deployHook();

        // Create and initialize pool
        _createPool();

        // Setup test actors
        _setupActors();

        // Label addresses for better traces
        _labelAddresses();

        // Add initial AMM liquidity
        _addInitialLiquidity();
    }

    function _deployTokens() internal {
        token0 = new MockERC20("Test Token 0", "TK0", 18);
        token1 = new MockERC20("Test Token 1", "TK1", 18);

        // Ensure token0 < token1 (required by Uniswap V4)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
    }

    function _deployHook() internal {
        hook = new DojimaHybridHook(poolManager);
    }

    function _createPool() internal {
        // Create pool with hook
        bytes32 params = bytes32(uint256(hook.getHooksRegistrationBitmap()));
        params = params.setTickSpacing(TICK_SPACING);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: FEE,
            parameters: params
        });

        // Initialize pool
        poolManager.initialize(poolKey, INITIAL_SQRT_PRICE);
        poolId = poolKey.toId();
    }

    function _setupActors() internal {
        address[] memory actors = new address[](12);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;
        actors[3] = dave;
        actors[4] = taker;
        actors[5] = keeper;
        actors[6] = maker1;
        actors[7] = maker2;
        actors[8] = maker3;
        actors[9] = taker1;
        actors[10] = taker2;
        actors[11] = liquidityProvider;

        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];

            // Mint tokens
            token0.mint(actor, 10000 ether);
            token1.mint(actor, 10000 ether);

            // Approve contracts
            vm.startPrank(actor);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            token0.approve(address(vault), type(uint256).max);
            token1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _labelAddresses() internal {
        vm.label(address(hook), "Hook");
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(vault), "Vault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(dave, "Dave");
        vm.label(taker, "Taker");
        vm.label(keeper, "Keeper");
        vm.label(maker1, "Maker1");
        vm.label(maker2, "Maker2");
        vm.label(maker3, "Maker3");
        vm.label(taker1, "Taker1");
        vm.label(taker2, "Taker2");
        vm.label(liquidityProvider, "LiquidityProvider");
    }

    function _addInitialLiquidity() internal {
        // Add wide-range liquidity around price = 1.0
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1000 ether,
            salt: bytes32(0)
        });

        CallbackData memory data = CallbackData({
            action: CallbackAction.ModifyLiquidity,
            sender: liquidityProvider,
            key: poolKey,
            modifyLiquidityParams: params,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0,
                sqrtPriceLimitX96: 0
            })
        });

        vault.lock(abi.encode(data));
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT.LOCK() CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Main callback handler for vault.lock()
    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(vault), "Only vault can call lockAcquired");

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.action == CallbackAction.ModifyLiquidity) {
            return _handleModifyLiquidity(data);
        } else if (data.action == CallbackAction.Swap) {
            return _handleSwap(data);
        }

        revert("Unknown callback action");
    }

    function _handleModifyLiquidity(CallbackData memory data) internal returns (bytes memory) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.modifyLiquidityParams, "");
        _settleDeltas(data.sender, data.key, delta);
        return abi.encode(delta);
    }

    function _handleSwap(CallbackData memory data) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.swap(data.key, data.swapParams, "");
        _settleDeltas(data.sender, data.key, delta);
        return abi.encode(delta);
    }

    /// @notice Swap callback for direct swap calls
    function swapCallback(SwapCallbackData calldata data) external returns (BalanceDelta) {
        require(msg.sender == address(vault), "Only vault can call");
        
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");
        _settleDeltas(data.sender, data.key, delta);
        return delta;
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        // Handle token0 settlement
        if (delta.amount0() < 0) {
            uint256 amount = uint256(int256(-delta.amount0()));
            _settle(key.currency0, sender, amount);
        } else if (delta.amount0() > 0) {
            uint256 amount = uint256(int256(delta.amount0()));
            _take(key.currency0, sender, amount);
        }

        // Handle token1 settlement
        if (delta.amount1() < 0) {
            uint256 amount = uint256(int256(-delta.amount1()));
            _settle(key.currency1, sender, amount);
        } else if (delta.amount1() > 0) {
            uint256 amount = uint256(int256(delta.amount1()));
            _take(key.currency1, sender, amount);
        }
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        vault.sync(currency);
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        vm.prank(payer);
        token.transfer(address(vault), amount);
        vault.settle();
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        vault.take(currency, recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNDING HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fund a specific actor with tokens
    function _fundActor(address actor, uint256 amount0, uint256 amount1) internal {
        token0.mint(actor, amount0);
        token1.mint(actor, amount1);

        vm.startPrank(actor);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Airdrop tokens to address
    function airdrop(MockERC20 token, address to, uint256 amount) public {
        uint256 balanceBefore = token.balanceOf(to);
        deal(address(token), to, balanceBefore + amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL BALANCE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens to internal balance
    function depositForUser(address user, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(user);
        if (amount0 > 0) {
            token0.approve(address(hook), amount0);
            hook.deposit(poolKey.currency0, amount0);
        }
        if (amount1 > 0) {
            token1.approve(address(hook), amount1);
            hook.deposit(poolKey.currency1, amount1);
        }
        vm.stopPrank();
    }

    /// @notice Withdraw tokens from internal balance
    function withdrawForUser(address user, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(user);
        if (amount0 > 0) hook.withdraw(poolKey.currency0, amount0);
        if (amount1 > 0) hook.withdraw(poolKey.currency1, amount1);
        vm.stopPrank();
    }

    /// @notice Get user's internal balance
    function getBalance(address user, Currency currency)
        public
        view
        returns (uint128 total, uint128 locked, uint128 available)
    {
        (total, locked,) = hook.getBalanceInfo(user, currency);
        available = total - locked;
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a sell order (selling token0 for token1)
    function placeSellOrder(address maker, uint256 price, uint128 amount) internal returns (uint256 orderId) {
        uint256 validPrice = roundToValidPrice(price);
        vm.startPrank(maker);
        orderId = hook.placeOrderFromBalance(poolKey, validPrice, amount, false);
        vm.stopPrank();
    }

    /// @notice Place a buy order (buying token0 with token1)
    function placeBuyOrder(address maker, uint256 price, uint128 amount) internal returns (uint256 orderId) {
        uint256 validPrice = roundToValidPrice(price);
        vm.startPrank(maker);
        orderId = hook.placeOrderFromBalance(poolKey, validPrice, amount, true);
        vm.stopPrank();
    }

    /// @notice Round price to valid increment for order book
    function roundToValidPrice(uint256 price) internal pure returns (uint256) {
        // Use standardized increments for testing
        uint256 minPrice = 500000000000000000;  // 0.5e18 (50% of 1.0)
        uint256 increment = 1000000000000000;   // 1e15 (0.1% increments)
        uint256 maxPrice = 2000000000000000000; // 2.0e18 (200% of 1.0)
        
        // Clamp to valid range
        if (price < minPrice) price = minPrice;
        if (price > maxPrice) price = maxPrice - increment;
        
        // Round to nearest increment
        uint256 offset = price - minPrice;
        uint256 numIncrements = (offset + increment / 2) / increment;
        
        return minPrice + (numIncrements * increment);
    }

    /// @notice Cancel an order
    function cancelOrder(address maker, uint256 orderId) internal {
        vm.startPrank(maker);
        hook.cancelOrder(orderId, poolKey);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add liquidity using callback pattern
    function _addLiquidity(address provider, int24 tickLower, int24 tickUpper, uint128 liquidityDelta) internal returns (BalanceDelta delta) {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(0)
        });

        CallbackData memory data = CallbackData({
            action: CallbackAction.ModifyLiquidity,
            sender: provider,
            key: poolKey,
            modifyLiquidityParams: params,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0,
                sqrtPriceLimitX96: 0
            })
        });

        bytes memory result = vault.lock(abi.encode(data));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Add liquidity (public interface for tests)
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper, 
        uint128 liquidityDelta,
        address provider,
        bytes memory hookData
    ) public returns (BalanceDelta delta, BalanceDelta feeDelta) {
        delta = _addLiquidity(provider, tickLower, tickUpper, liquidityDelta);
        feeDelta = BalanceDelta.wrap(0); // No fees in our case
    }

    /// @notice Get current tick for a pool
    function getCurrentTick(PoolId poolId_) public view returns (int24 tick) {
        (, int24 tick_, , ) = poolManager.getSlot0(poolId_);
        return tick_;
    }

    /// @notice Remove liquidity (public interface for tests)
    function removeLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta,
        address provider,
        bytes memory hookData
    ) public returns (BalanceDelta delta, BalanceDelta feeDelta) {
        delta = _removeLiquidity(provider, tickLower, tickUpper, liquidityDelta);
        feeDelta = BalanceDelta.wrap(0); // No fees in our case
    }

    /// @notice Remove liquidity using callback pattern
    function _removeLiquidity(address provider, int24 tickLower, int24 tickUpper, uint128 liquidityDelta) internal returns (BalanceDelta delta) {
        ICLPoolManager.ModifyLiquidityParams memory params = ICLPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(liquidityDelta)), // Negative to remove
            salt: bytes32(0)
        });

        CallbackData memory data = CallbackData({
            action: CallbackAction.ModifyLiquidity,
            sender: provider,
            key: poolKey,
            modifyLiquidityParams: params,
            swapParams: ICLPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 0,
                sqrtPriceLimitX96: 0
            })
        });

        bytes memory result = vault.lock(abi.encode(data));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Add standard wide-range liquidity
    function addStandardLiquidity(uint128 liquidity) internal returns (BalanceDelta delta) {
        return _addLiquidity(liquidityProvider, -60 * 10, 60 * 10, liquidity);
    }

    /// @notice Add concentrated liquidity around current price
    function addConcentratedLiquidity(uint128 liquidity, int24 tickRange) internal returns (BalanceDelta delta) {
        return _addLiquidity(liquidityProvider, -tickRange, tickRange, liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute swap using callback pattern
    function _swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal returns (BalanceDelta delta) {
        return _swapExactInputSingle(key, zeroForOne, amountIn, amountOutMinimum, msg.sender);
    }

    function _swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        address swapper
    ) internal returns (BalanceDelta delta) {
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        CallbackData memory data = CallbackData({
            action: CallbackAction.Swap,
            sender: swapper,
            key: key,
            modifyLiquidityParams: ICLPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 0,
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            swapParams: params
        });

        bytes memory result = vault.lock(abi.encode(data));
        delta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Execute a buy swap (buy token0 with token1)
    function executeBuySwap(address trader, uint256 amountIn) internal returns (BalanceDelta delta) {
        return _swapExactInputSingle(poolKey, false, uint128(amountIn), 0, trader);
    }

    /// @notice Execute a sell swap (sell token0 for token1)
    function executeSellSwap(address trader, uint256 amountIn) internal returns (BalanceDelta delta) {
        return _swapExactInputSingle(poolKey, true, uint128(amountIn), 0, trader);
    }

    /*//////////////////////////////////////////////////////////////
                        SCENARIO HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Setup a realistic scenario with AMM liquidity and limit orders
    function setupRealisticScenario(
        uint128 ammLiquidity,
        uint256 numSellOrders,
        uint256 numBuyOrders,
        uint128 orderSize
    ) internal {
        // Add AMM liquidity
        addStandardLiquidity(ammLiquidity);

        // Setup makers with internal balance
        depositForUser(maker1, 100 ether, 100 ether);
        depositForUser(maker2, 100 ether, 100 ether);
        depositForUser(maker3, 100 ether, 100 ether);

        // Place sell orders (above current price)
        for (uint256 i = 0; i < numSellOrders; i++) {
            uint256 price = 1.001e18 + (i * 0.002e18); // 1.001, 1.003, 1.005...
            address maker = i % 3 == 0 ? maker1 : (i % 3 == 1 ? maker2 : maker3);
            placeSellOrder(maker, price, orderSize);
        }

        // Place buy orders (below current price)
        for (uint256 i = 0; i < numBuyOrders; i++) {
            uint256 price = 0.999e18 - (i * 0.002e18); // 0.999, 0.997, 0.995...
            address maker = i % 3 == 0 ? maker1 : (i % 3 == 1 ? maker2 : maker3);
            placeBuyOrder(maker, price, orderSize);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MEASUREMENT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get effective execution price from a swap
    function getExecutionPrice(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256 price) {
        if (zeroForOne) {
            // Selling token0 for token1
            uint256 amountIn = uint256(int256(-delta.amount0()));
            uint256 amountOut = uint256(int256(delta.amount1()));
            price = (amountOut * 1e18) / amountIn;
        } else {
            // Buying token0 with token1
            uint256 amountIn = uint256(int256(-delta.amount1()));
            uint256 amountOut = uint256(int256(delta.amount0()));
            price = (amountIn * 1e18) / amountOut;
        }
    }

    /// @notice Calculate price improvement in basis points
    function calculatePriceImprovement(
        uint256 priceWithoutCLOB,
        uint256 priceWithCLOB,
        bool isBuy
    ) internal pure returns (int256 improvementBps) {
        if (isBuy) {
            // For buys, lower price is better
            int256 diff = int256(priceWithoutCLOB) - int256(priceWithCLOB);
            improvementBps = (diff * 10000) / int256(priceWithoutCLOB);
        } else {
            // For sells, higher price is better
            int256 diff = int256(priceWithCLOB) - int256(priceWithoutCLOB);
            improvementBps = (diff * 10000) / int256(priceWithoutCLOB);
        }
    }

    /// @notice Get token balances for an address
    function getBalances(address user) internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = token0.balanceOf(user);
        balance1 = token1.balanceOf(user);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS MEASUREMENT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Start gas measurement
    function startGasMeasurement() internal {
        gasSnapshot = gasleft();
    }

    /// @notice End gas measurement and return gas used
    function endGasMeasurement() internal returns (uint256 gasUsed) {
        gasUsed = gasSnapshot - gasleft();
        console2.log("Gas used:", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                        ASSERTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Assert balance is approximately equal
    function assertBalanceApproxEq(
        address user,
        Currency currency,
        uint128 expected,
        uint128 tolerance,
        string memory message
    ) public {
        (uint128 actual,,) = hook.getBalanceInfo(user, currency);
        assertApproxEqAbs(actual, expected, tolerance, message);
    }

    /// @notice Assert refund was credited
    function assertRefundReceived(
        address user,
        Currency currency,
        uint128 balanceBefore,
        uint128 minRefund,
        string memory message
    ) public {
        (uint128 balanceAfter,,) = hook.getBalanceInfo(user, currency);
        uint128 refund = balanceAfter - balanceBefore;
        assertGt(refund, minRefund, message);
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE CONVERSION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert price to sqrtPriceX96 format
    function _priceToSqrtPriceX96(uint256 price) internal pure returns (uint160) {
        uint256 sqrtPrice = sqrt(price * 1e18) * 2**48 / 1e9;
        return uint160(sqrtPrice);
    }

    /// @notice Simple sqrt implementation
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}