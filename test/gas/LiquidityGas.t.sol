// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Setup} from "../utils/Setup.sol";
import {console} from "forge-std/console.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

/// @title LiquidityGas
/// @notice Comprehensive gas benchmarks for liquidity operations
/// @dev Tests all LP operations: add, remove, rebalance with varying positions
contract LiquidityGasTest is Setup {

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                    ADD LIQUIDITY - FIRST POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for first LP position in pool
    function test_Gas_AddLiquidity_First_WideRange() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 10000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 10000) / TICK_SPACING) * TICK_SPACING;

        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 10 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: First Position (Wide Range) ===");
        console.log("Gas used:", gasUsed);
        console.log("Tick range:", uint256(uint24(tickUpper - tickLower)));
    }

    /// @notice Gas cost for first concentrated position
    function test_Gas_AddLiquidity_First_Concentrated() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 300) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 300) / TICK_SPACING) * TICK_SPACING;

        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 10 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: First Position (Concentrated) ===");
        console.log("Gas used:", gasUsed);
        console.log("Tick range:", uint256(uint24(tickUpper - tickLower)));
    }

    /// @notice Gas cost for single-tick position
    function test_Gas_AddLiquidity_First_SingleTick() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = (currentTick / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = tickLower + TICK_SPACING;

        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 10 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: First Position (Single Tick) ===");
        console.log("Gas used:", gasUsed);
        console.log("Tick range:", uint256(uint24(TICK_SPACING)));
    }

    /*//////////////////////////////////////////////////////////////
                ADD LIQUIDITY - EXISTING POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for adding to existing position
    function test_Gas_AddLiquidity_Existing() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;

        // Add initial position
        addLiquidity(poolKey, tickLower, tickUpper, 10 ether, liquidityProvider, "");

        // Measure gas for adding to same position
        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 5 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: Existing Position ===");
        console.log("Gas used:", gasUsed);
    }

    /// @notice Gas cost for adding second position (different range)
    function test_Gas_AddLiquidity_SecondPosition() public {
        int24 currentTick = getCurrentTick(poolId);

        // Add first position
        int24 tickLower1 = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper1 = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        addLiquidity(poolKey, tickLower1, tickUpper1, 10 ether, liquidityProvider, "");

        // Measure gas for second position (different range)
        int24 tickLower2 = ((currentTick - 500) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper2 = ((currentTick + 500) / TICK_SPACING) * TICK_SPACING;

        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower2, tickUpper2, 10 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: Second Position (Different Range) ===");
        console.log("Gas used:", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                    REMOVE LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for removing entire position
    function test_Gas_RemoveLiquidity_Full() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 10 ether;

        // Add position
        addLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");

        // Measure gas for full removal
        uint256 gasBefore = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Remove Liquidity: Full Position ===");
        console.log("Gas used:", gasUsed);
    }

    /// @notice Gas cost for removing partial position
    function test_Gas_RemoveLiquidity_Partial() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 10 ether;

        // Add position
        addLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");

        // Measure gas for partial removal (50%)
        uint256 gasBefore = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Remove Liquidity: Partial (50%) ===");
        console.log("Gas used:", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDITY REBALANCING
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas cost for rebalancing (remove + add new range)
    function test_Gas_RebalanceLiquidity() public {
        int24 currentTick = getCurrentTick(poolId);

        // Add initial position
        int24 tickLower1 = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper1 = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 10 ether;
        addLiquidity(poolKey, tickLower1, tickUpper1, liquidity, liquidityProvider, "");

        // Measure gas for rebalance: remove old + add new
        int24 tickLower2 = ((currentTick - 500) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper2 = ((currentTick + 500) / TICK_SPACING) * TICK_SPACING;

        uint256 gasBefore = gasleft();
        // Remove from old range
        removeLiquidity(poolKey, tickLower1, tickUpper1, liquidity, liquidityProvider, "");
        // Add to new range
        addLiquidity(poolKey, tickLower2, tickUpper2, liquidity, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Rebalance Liquidity ===");
        console.log("Total gas used:", gasUsed);
        console.log("Old range:", uint256(uint24(tickUpper1 - tickLower1)));
        console.log("New range:", uint256(uint24(tickUpper2 - tickLower2)));
    }

    /*//////////////////////////////////////////////////////////////
                LIQUIDITY WITH ACTIVE TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas for adding liquidity after swaps (with fees earned)
    function test_Gas_AddLiquidity_AfterSwaps() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;

        // Add initial liquidity
        addLiquidity(poolKey, tickLower, tickUpper, 10 ether, liquidityProvider, "");

        // Execute some swaps to generate fees
        executeSellSwap(taker1, 1 ether);
        executeBuySwap(taker2, 1 ether);
        executeSellSwap(taker1, 0.5 ether);

        // Measure gas for adding more liquidity (position has accrued fees)
        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 5 ether, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: After Swaps (With Fees) ===");
        console.log("Gas used:", gasUsed);
    }

    /// @notice Gas for removing liquidity after swaps (with fees earned)
    function test_Gas_RemoveLiquidity_AfterSwaps() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 10 ether;

        // Add liquidity
        addLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");

        // Execute swaps to generate fees
        executeSellSwap(taker1, 2 ether);
        executeBuySwap(taker2, 2 ether);

        // Measure gas for removal (with fees)
        uint256 gasBefore = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Remove Liquidity: After Swaps (With Fees) ===");
        console.log("Gas used:", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                LIQUIDITY POSITION SIZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare gas costs for different liquidity amounts
    function test_Gas_AddLiquidity_VaryingSizes() public {
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;

        uint128[] memory sizes = new uint128[](4);
        sizes[0] = 1 ether;
        sizes[1] = 10 ether;
        sizes[2] = 100 ether;
        sizes[3] = 1000 ether;

        console.log("=== Add Liquidity: Varying Sizes ===");

        for (uint256 i = 0; i < sizes.length; i++) {
            // Use different user for each size to avoid conflicts
            address lp = makeAddr(string(abi.encodePacked("lp", i)));
            _fundActor(lp, 2000 ether, 2000 ether);
            // approveTokens handled by _fundActor.max, type(uint256).max);

            uint256 gasBefore = gasleft();
            addLiquidity(poolKey, tickLower, tickUpper, sizes[i], lp, "");
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Liquidity (ETH):", sizes[i] / 1 ether);
            console.log("  Gas:", gasUsed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                LIQUIDITY RANGE COMPARISON
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare gas costs for different tick ranges
    function test_Gas_AddLiquidity_VaryingRanges() public {
        int24 currentTick = getCurrentTick(poolId);

        uint24[] memory ranges = new uint24[](5);
        ranges[0] = 60;      // Single tick
        ranges[1] = 300;     // 5 ticks
        ranges[2] = 600;     // 10 ticks
        ranges[3] = 3000;    // 50 ticks
        ranges[4] = 20000;   // 333 ticks (very wide)

        console.log("=== Add Liquidity: Varying Ranges ===");

        for (uint256 i = 0; i < ranges.length; i++) {
            int24 tickLower = ((currentTick - int24(ranges[i])) / TICK_SPACING) * TICK_SPACING;
            int24 tickUpper = ((currentTick + int24(ranges[i])) / TICK_SPACING) * TICK_SPACING;

            // Use different user for each range
            address lp = makeAddr(string(abi.encodePacked("lp_range", i)));
            _fundActor(lp, 100 ether, 100 ether);
            // approveTokens handled by _fundActor.max, type(uint256).max);

            uint256 gasBefore = gasleft();
            addLiquidity(poolKey, tickLower, tickUpper, 10 ether, lp, "");
            uint256 gasUsed = gasBefore - gasleft();

            uint24 numTicks = uint24((tickUpper - tickLower) / TICK_SPACING);
            console.log("Range:", ranges[i]);
            console.log("  Ticks:", numTicks);
            console.log("  Gas:", gasUsed);
        }
    }

    /*//////////////////////////////////////////////////////////////
            LIQUIDITY WITH LIMIT ORDERS (REALISTIC)
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas for LP operations with active limit orders in pool
    function test_Gas_AddLiquidity_WithLimitOrders() public {
        // Setup realistic scenario: AMM + limit orders
        setupRealisticScenario(
            100 ether,  // AMM liquidity
            5,          // 5 sell orders
            5,          // 5 buy orders
            2 ether     // 2 ETH per order
        );

        // Add more LP (this is common - LPs add liquidity to active pools)
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;

        address newLP = makeAddr("newLP");
        _fundActor(newLP, 100 ether, 100 ether);
        // approveTokens handled by _fundActor.max, type(uint256).max);

        uint256 gasBefore = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, 20 ether, newLP, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Add Liquidity: With Active Limit Orders ===");
        console.log("Gas used:", gasUsed);
        console.log("Orders in pool: 10 (5 buy, 5 sell)");
    }

    /// @notice Gas for removing LP with active limit orders
    function test_Gas_RemoveLiquidity_WithLimitOrders() public {
        // Add initial LP
        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 50 ether;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");

        // Add limit orders
        depositForUser(maker1, 50 ether, 50 ether);
        for (uint256 i = 0; i < 5; i++) {
            placeSellOrder(maker1, 1.002e18 + (i * 0.001e18), 3 ether);
            placeBuyOrder(maker1, 0.998e18 - (i * 0.001e18), 3 ether);
        }

        // Execute some swaps
        executeSellSwap(taker1, 1 ether);
        executeBuySwap(taker2, 1 ether);

        // Measure removal gas
        uint256 gasBefore = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity, liquidityProvider, "");
        uint256 gasUsed = gasBefore - gasleft();

        console.log("=== Remove Liquidity: With Active Limit Orders ===");
        console.log("Gas used:", gasUsed);
        console.log("Orders in pool: 10");
    }

    /*//////////////////////////////////////////////////////////////
                    SUMMARY COMPARISON
    //////////////////////////////////////////////////////////////*/

    /// @notice Comprehensive LP gas comparison
    function test_Summary_LiquidityOperations() public {
        console.log("");
        console.log("=== LIQUIDITY OPERATIONS GAS SUMMARY ===");
        console.log("");

        int24 currentTick = getCurrentTick(poolId);
        int24 tickLower = ((currentTick - 1000) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper = ((currentTick + 1000) / TICK_SPACING) * TICK_SPACING;
        uint128 liquidity = 10 ether;

        // 1. Add first position
        address lp1 = makeAddr("lp1");
        _fundActor(lp1, 100 ether, 100 ether);
        // approveTokens handled by _fundActor.max, type(uint256).max);

        uint256 gas1 = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, liquidity, lp1, "");
        uint256 gasAdd1 = gas1 - gasleft();

        // 2. Add to existing
        uint256 gas2 = gasleft();
        addLiquidity(poolKey, tickLower, tickUpper, liquidity / 2, lp1, "");
        uint256 gasAddExisting = gas2 - gasleft();

        // 3. Add second position (different range)
        int24 tickLower2 = ((currentTick - 500) / TICK_SPACING) * TICK_SPACING;
        int24 tickUpper2 = ((currentTick + 500) / TICK_SPACING) * TICK_SPACING;

        uint256 gas3 = gasleft();
        addLiquidity(poolKey, tickLower2, tickUpper2, liquidity, lp1, "");
        uint256 gasAdd2 = gas3 - gasleft();

        // 4. Remove partial
        uint256 gas4 = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2, lp1, "");
        uint256 gasRemovePartial = gas4 - gasleft();

        // 5. Remove full
        uint256 gas5 = gasleft();
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity, lp1, "");
        uint256 gasRemoveFull = gas5 - gasleft();

        console.log("Add First Position:    ", gasAdd1);
        console.log("Add to Existing:       ", gasAddExisting);
        console.log("Add Second Position:   ", gasAdd2);
        console.log("Remove Partial (50%):  ", gasRemovePartial);
        console.log("Remove Full:           ", gasRemoveFull);
        console.log("");
    }
}
