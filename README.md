# Dojima Hybrid AMM + CLOB

> Experimental hybrid AMM + CLOB system built on PancakeSwap V4 hooks for RISE

**Experimental Project**: This is an open-source experiment demonstrating advanced DeFi primitives. Contracts are not audited and require additional work to be production-ready.

## Overview

Dojima is a hybrid trading venue that combines Automated Market Makers (AMM) with Central Limit Order Books (CLOB) using PancakeSwap V4's hooks architecture. Built specifically for high-performance EVM chains such as RISE, it enables CEX-like onchain trading with sub-5ms latency and 100K+ TPS capacity.

<img src="image.png">


### How It Works

Our `DojimaHybridHook` integrates with PancakeSwap V4's pool lifecycle to provide:

- **Unified Liquidity**: AMM provides base liquidity while CLOB adds precision price discovery
- **Smart Routing**: Automatically routes trades through AMM, CLOB, or hybrid execution for optimal prices
- **Internal Balance System**: Deposit once, trade unlimited times with minimal gas overhead
- **Price-Time Priority**: Traditional orderbook mechanics with maker fee rebates
- **Cross-Tick Matching**: Orders can span multiple price levels for better execution

### Built for RISE Performance

RISE is an Ethereum Layer 2 blockchain redefining performance with near-instant transactions at unprecedented scale. Its unique architecture enables:

- **5ms latency** - Real-time order book updates and instant trade confirmation
- **100K+ TPS capacity** - Supporting millions of simultaneous users
- **Full decentralization** - Maintaining Ethereum's core principles

This performance unlocks true onchain order books, bringing CEX-like trading experience while remaining fully decentralized.

## PancakeSwap V4 Hooks Architecture

Dojima leverages PancakeSwap V4's revolutionary hooks system, which allows custom logic to be executed at specific points in the pool lifecycle:

```
┌─────────────────────────────────────────────────────────┐
│                  DojimaHybridHook                       │
│  ┌────────────────────┐      ┌──────────────────────┐   │
│  │  Internal Balance  │      │  Tick-Integrated     │   │
│  │  System            │      │  Order Book          │   │
│  │  (ERC20 deposit)   │      │  (Fenwick Tree)      │   │
│  └────────────────────┘      └──────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Hook Integration (beforeSwap/afterSwap)         │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│          PancakeSwap V4 (infinity-core)                 │
│  ┌────────────┐  ┌───────────────┐  ┌──────────────┐    │
│  │  Vault     │  │  CLPoolManager│  │  AMM Pools   │    │
│  └────────────┘  └───────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### Hook Integration Points

Our hook implements these PancakeSwap V4 interfaces from `lib/infinity-core/`:

- **beforeSwap**: Analyze order book and determine optimal routing
- **afterSwap**: Process maker fee rebates and update internal balances
- **beforeModifyLiquidity**: Handle LP position changes
- **afterModifyLiquidity**: Update tick-integrated order book state

Reference implementations in `lib/infinity-hooks/` provide patterns for limit orders and fee management.

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed system design.

## Key Features

### 1. Tick-Integrated Order Book
- **Price-tick alignment**: Orders stored at AMM price ticks for efficient routing
- **Fenwick Tree**: O(log n) order matching and depth queries
- **High precision**: 4,096 price levels per tick (0.1% granularity)
- **Multi-tick matching**: Orders can span across multiple ticks

### 2. Internal Balance System
- **Deposit once**: Users deposit ERC20s to internal balance
- **Zero-transfer orders**: Place orders by locking balance (no ERC20 transfer)
- **Auto-credit fills**: Maker balances credited automatically when orders fill
- **Instant withdrawals**: Withdraw proceeds anytime

### 3. Optimized Hybrid Execution
- **Smart routing**: Fast analysis for small swaps, full analysis for large swaps
- **Price-limit matching**: Only matches CLOB orders better than AMM price
- **Cross-tick matching**: Efficiently spans multiple price ticks

### 4. Advanced Features
- **Maker rebates**: Fee sharing for liquidity providers
- **Volume tracking**: TWAV and volume oracles
- **Token launchpad**: Bonding curve with automatic graduation to LP pools

## Repository Structure

```
contracts/
├── src/dojima/
│   ├── DojimaHybridHook.sol           # Main hook
│   ├── orderbook/
│   │   ├── FenwickOrderBook.sol       # Order book core
│   │   ├── TickOrderBookManager.sol   # Tick management
│   │   ├── OrderBookTypes.sol         # Shared types
│   │   └── TickMath.sol               # Price conversions
│   ├── DojimaIncentives.sol           # Incentives system
│   ├── DojimaVolumeOracle.sol         # Volume tracking
│   └── LaunchpadHook.sol              # Token launchpad
├── test/
│   ├── integration/
│   │   ├── SwapIntegration.t.sol      # Core swap tests 
│   │   ├── FullIntegration.t.sol      # End-to-end tests 
│   │   ├── PriceOptimization.t.sol    # Routing optimization 
│   │   └── MultiTickSwap.t.sol        # Cross-tick matching
│   ├── unit/
│   │   ├── FenwickOrderBook.t.sol     # Order book unit tests
│   │   ├── InternalBalance.t.sol      # Balance system tests 
│   │   └── TakerRefund.t.sol          # Refund mechanism tests
│   ├── gas/
│   │   ├── BuyOrderExecution.t.sol    # Gas benchmarks
│   │   ├── ExecutionQuality.t.sol     # Quality metrics
│   │   └── LiquidityGas.t.sol         # Liquidity gas costs
│   └── utils/Setup.sol                # Test utilities
├── script/
│   ├── DeployDojimaHooks.s.sol        # Main deployment
│   ├── SetupNewPool.s.sol             # Pool setup automation
│   └── ...                            # Other scripts
└── docs/
    ├── README.md                       # This file
    ├── ARCHITECTURE.md                 # System design
    └── SETUP.md                        # Development guide
```

## Quick Start

### Installation
```bash
forge install
```

### Run Tests
```bash
# All tests
forge test

# Core integration tests
forge test --match-path "test/integration/*" -v

# Routing optimization tests
forge test --match-contract PriceOptimizationTest -v

# Unit tests
forge test --match-path "test/unit/*" -v

# Gas benchmarks
forge test --match-path "test/gas/*" --gas-report
```

## Usage Examples

### For Traders

```solidity
// 1. Deposit tokens once
hook.deposit(USDC, 10_000e6); // Deposit $10k

// 2. Place multiple limit orders (cheap!)
hook.placeOrderFromBalance(poolKey, 2500e18, 1e18, true);  // Buy 1 ETH @ $2500
hook.placeOrderFromBalance(poolKey, 2400e18, 1e18, true);  // Buy 1 ETH @ $2400
hook.placeOrderFromBalance(poolKey, 2300e18, 1e18, true);  // Buy 1 ETH @ $2300

// 3. Orders fill automatically with price optimization
// - Only matches if order price beats AMM
// - Automatic refunds for better execution
// - Cross-tick routing for large orders

// 4. Withdraw proceeds
hook.withdraw(ETH, 3e18);
```

### For Market Makers

```solidity
// Deposit both sides
hook.deposit(ETH, 100e18);
hook.deposit(USDC, 250_000e6);

// Place spread orders across multiple price points
for (uint i = 0; i < 50; i++) {
    uint256 bidPrice = currentPrice - (i * spreadIncrement);
    uint256 askPrice = currentPrice + (i * spreadIncrement);

    hook.placeOrderFromBalance(poolKey, bidPrice, 1e18, true);   // Bids
    hook.placeOrderFromBalance(poolKey, askPrice, 1e18, false);  // Asks
}
```

## Current Implementation Status

### Core Contracts Implemented
- **DojimaHybridHook**: Main hook implementing hybrid AMM+CLOB execution
- **FenwickOrderBook**: Efficient order book data structure with O(log n) operations
- **TickOrderBookManager**: Manages order placement and matching across price ticks
- **DojimaRouter**: Router for multi-pool interactions
- **LaunchpadHook**: Token bonding curve with automatic graduation to liquidity pools

### Key Features Working
- Hybrid AMM+CLOB execution with price-limit matching
- Internal balance system for gas-efficient trading
- Cross-tick order matching and routing
- Maker fee rebate system
- Balance conservation and security

### Test Coverage
- **Core Functionality**: 155/163 tests passing (95.1% success rate)
- **SwapIntegration**: 9/9 tests passing (100%)
- **FullIntegration**: 9/9 tests passing (100%)
- **InternalBalance**: 22/23 tests passing (95.7%)
- **PriceOptimization**: 4/7 tests passing (57%)

### Recent Optimizations
- Routing optimization with ~60% reduced storage operations
- Smart analysis for different swap sizes
- Price-limit matching preventing expensive order execution (0.2-2% better prices)
- Proper PancakeSwap V4 vault.lock() integration

### Future Improvements
- Complete remaining test coverage for 100% pass rate
- User-specified routing with `swapWithRouteAmounts()`
- BeforeSwapDelta integration for 10-30% gas savings
- Advanced order types (post-only, FOK, IOC)
- Multi-pool arbitrage detection
- Enhanced volume tracking and analytics
- Production security audits

## Technical Highlights

### Routing Optimization System
The system uses a two-tier analysis approach for optimal AMM+CLOB execution:

```solidity
// Fast analysis for small swaps (<1 ETH)
RoutingDecision memory decision = _analyzeOptimalRouting(poolId, isBuy, amountWanted, sender);

// Full analysis fallback for large swaps where accuracy matters  
if (!decision.useCLOB && amountWanted > 1 ether) {
    SwapSimulation memory ammSim = _simulateAMMSwap(poolId, amountWanted);
    OrderBookAnalysis memory clobAnalysis = _analyzeOrderBook(poolId, isBuy, amountWanted, ammSim.ammPrice);
    // ... determine optimal routing
}
```

**Key Optimizations**:
- **Unified Storage**: Single `RoutingDecision` struct vs 3 separate mappings
- **Smart Price Estimation**: Direct sqrtPriceX96 conversion vs complex simulation  
- **Early Exit Logic**: Stop scanning when sufficient CLOB depth found
- **Price-Limit Matching**: Only execute CLOB orders better than AMM price

### Price-Limit Matching Algorithm
```solidity
// Only match orders that beat AMM execution price
if (isBuy && orderPrice > actualAMMPrice) break;  // Skip expensive asks
if (!isBuy && orderPrice < actualAMMPrice) break; // Skip low bids
```

This prevents matching expensive tail orders and guarantees better execution.

## Gas Performance

| Operation | Gas Used | Notes |
|-----------|----------|-------|
| **AMM Swap (baseline)** | ~86k | Pure PancakeSwap V4 |
| **Order placement (hot)** | ~92k | From internal balance |
| **Order placement (cold)** | ~212k | First order in tick |
| **Hybrid execution** | ~650k | CLOB matching + AMM remainder |
| **Price optimization** | +5-15k | Smart routing overhead |

### Optimization Results
- **Storage Operations**: ~60% reduction vs original implementation
- **Routing Efficiency**: 0.2-2% better execution prices
- **Gas Savings**: ~55k per expensive order skipped
- **Analysis Speed**: ~20-30% faster for typical swaps

**Key Insights**:
- Internal balance system eliminates ERC20 transfer costs
- Price-limit matching prevents expensive order execution
- Smart routing scales efficiently with order book depth


## Resources

- **PancakeSwap V4**: [Developer Docs](https://developer.pancakeswap.finance/)
- **Foundry**: [book.getfoundry.sh](https://book.getfoundry.sh/)
- **RISE Testnet**: [Explorer](https://explorer.testnet.riselabs.xyz)
- **RISE Docs**: [riselabs.xyz](https://docs.risechain.com)

## License

MIT
