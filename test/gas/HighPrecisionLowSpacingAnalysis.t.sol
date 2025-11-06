// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// import {PrecisionGasBenchmark} from "./PrecisionGasBenchmark.t.sol";
import {PrecisionHelper} from "../../src/dojima/libraries/PrecisionHelper.sol";

/// @title HighPrecisionLowSpacingAnalysis
/// @notice Analyzes the specific case of high words (32+) with low tick spacing
/// @dev Tests precision, gas costs, and tick crossing behavior
contract HighPrecisionLowSpacingAnalysis is Test {
    
    struct Config {
        uint16 words;
        int24 spacing;
        string name;
    }
    
    function test_32WordsLowSpacing() public {
        console.log("\n=== 32 WORDS WITH LOW SPACING ANALYSIS ===");
        console.log("Testing high bitmap density with tight tick ranges\n");
        
        // Test configurations with 32 words
        analyzeConfig("32 words, spacing 1", 32, 1, 2500e18);   // ETH at $2500
        analyzeConfig("32 words, spacing 5", 32, 5, 2500e18);
        analyzeConfig("32 words, spacing 10", 32, 10, 2500e18);
        analyzeConfig("32 words, spacing 30", 32, 30, 2500e18);
        analyzeConfig("32 words, spacing 60", 32, 60, 2500e18); // For comparison
        
        console.log("\n=== STABLECOIN SCENARIO (32 words) ===");
        analyzeConfig("USDC/USDT spacing 1", 32, 1, 1e18);      // $1.00
        analyzeConfig("USDC/USDT spacing 5", 32, 5, 1e18);
        
        console.log("\n=== TICK CROSSING ANALYSIS ===");
        analyzeTickCrossingBehavior();
        
        console.log("\n=== STORAGE DENSITY ANALYSIS ===");
        analyzeStorageDensity();
    }
    
    function analyzeConfig(
        string memory name,
        uint16 wordsPerTick,
        int24 tickSpacing,
        uint256 assetPrice
    ) internal {
        console.log("\n--- Configuration:", name, "---");
        
        // Calculate precision
        (uint256 precisionWei, uint256 precisionCents) = PrecisionHelper.calculatePrecision(
            tickSpacing,
            wordsPerTick,
            assetPrice
        );
        
        // Calculate range per tick
        uint256 bps = uint256(int256(tickSpacing));
        uint256 rangePercent = bps; // basis points
        uint256 priceRange = (assetPrice * rangePercent) / 10000;
        
        console.log("Asset price: $", assetPrice / 1e18);
        console.log("Range per tick: $", priceRange / 1e18);
        console.log("Price points: ", wordsPerTick * 256);
        console.log("Precision: $", precisionWei / 1e18);
        console.log("Precision (cents):", precisionCents);
        
        // Gas estimates
        uint256 gasEstimate = PrecisionHelper.estimateOrderGas(wordsPerTick);
        uint256 storageSlots = PrecisionHelper.calculateStorage(wordsPerTick);
        
        console.log("\nGas & Storage:");
        console.log("Place order gas:", gasEstimate);
        console.log("Storage per tick:", storageSlots, "slots");
        
        // Efficiency analysis
        uint256 gasPerCentPrecision = gasEstimate / (precisionCents > 0 ? precisionCents : 1);
        console.log("Gas per cent precision:", gasPerCentPrecision);
        
        // Use case analysis
        console.log("\nBest for:");
        if (tickSpacing == 1) {
            console.log("- Ultra-tight market making");
            console.log("- High-frequency arbitrage");
            console.log("- WARNING: Many tick crosses on large moves!");
        } else if (tickSpacing <= 10) {
            console.log("- Professional market making");
            console.log("- Institutional trading");
            console.log("- Balanced tick crossing");
        } else {
            console.log("- General trading");
            console.log("- Good gas efficiency");
        }
    }
    
    function analyzeTickCrossingBehavior() internal {
        console.log("\nImpact of low spacing on tick crosses:");
        console.log("(For $100 price movement on $2500 ETH = 4% move)\n");
        
        int24[] memory spacings = new int24[](6);
        spacings[0] = 1;
        spacings[1] = 5;
        spacings[2] = 10;
        spacings[3] = 30;
        spacings[4] = 60;
        spacings[5] = 200;
        
        console.log("Spacing | Ticks Crossed | Gas Impact | Storage Impact");
        console.log("--------|---------------|------------|---------------");
        
        for (uint i = 0; i < spacings.length; i++) {
            int24 spacing = spacings[i];
            uint256 ticksCrossed = PrecisionHelper.estimateTickCrosses(spacing, 4); // 4% move
            uint256 gasPerTick = 17000; // Approximate gas to cross a tick
            uint256 totalGasImpact = ticksCrossed * gasPerTick;
            uint256 storagePerTick = 32 * 4; // 32 words * 4 arrays
            uint256 totalStorage = ticksCrossed * storagePerTick;
            
            console.log(string.concat(
                pad(toString(uint256(int256(spacing))), 7),
                " | ",
                pad(toString(ticksCrossed), 13),
                " | ",
                pad(toString(totalGasImpact / 1000), 10),
                "k | ",
                pad(toString(totalStorage), 13),
                " slots"
            ));
        }
        
        console.log("\nKey insight: Low spacing = more tick crosses = higher execution gas");
    }
    
    function analyzeStorageDensity() internal {
        console.log("\nStorage efficiency with 32 words:");
        
        // Compare different configurations
        
        Config[] memory configs = new Config[](4);
        configs[0] = Config(32, 1, "Ultra-dense");
        configs[1] = Config(32, 10, "Dense");
        configs[2] = Config(16, 60, "Standard");
        configs[3] = Config(8, 200, "Sparse");
        
        console.log("\nConfig      | Price Points | $/Point | Active Ticks* | Total Storage");
        console.log("------------|--------------|---------|---------------|---------------");
        
        for (uint i = 0; i < configs.length; i++) {
            Config memory cfg = configs[i];
            
            uint256 pricePoints = cfg.words * 256;
            (uint256 precisionWei,) = PrecisionHelper.calculatePrecision(
                cfg.spacing,
                cfg.words,
                2500e18
            );
            
            // Estimate active ticks for +/-10% range
            uint256 activeTicks = (2000) / uint256(int256(cfg.spacing)); // 20% range / spacing
            uint256 storagePerTick = cfg.words * 4;
            uint256 totalStorage = activeTicks * storagePerTick;
            
            console.log(string.concat(
                pad(cfg.name, 11),
                " | ",
                pad(toString(pricePoints), 12),
                " | $",
                pad(toString(precisionWei / 1e16), 6), // in cents
                " | ",
                pad(toString(activeTicks), 13),
                " | ",
                toString(totalStorage),
                " slots"
            ));
        }
        
        console.log("\n*Active ticks estimated for +/-10% price range");
    }
    
    function test_OptimalConfigurationsFor32Words() public {
        console.log("\n=== OPTIMAL CONFIGURATIONS FOR 32 WORDS ===");
        
        console.log("\n1. STABLECOIN PAIRS");
        console.log("   Config: 32 words, 1 spacing");
        console.log("   Precision: $0.00001 (0.001 cents)");
        console.log("   Use case: Capture 0.01% deviations");
        console.log("   Trade-off: ~400 tick crosses for 4% move");
        
        console.log("\n2. ETH/BTC PAIRS");
        console.log("   Config: 32 words, 5 spacing");
        console.log("   Precision: $0.01 at $50k BTC");
        console.log("   Use case: Professional arbitrage");
        console.log("   Trade-off: ~80 tick crosses for 4% move");
        
        console.log("\n3. MAJOR PAIRS (ETH/USDC)");
        console.log("   Config: 32 words, 10 spacing");
        console.log("   Precision: $0.03 at $2500 ETH");
        console.log("   Use case: Institutional market making");
        console.log("   Trade-off: ~40 tick crosses for 4% move");
        
        console.log("\n4. HIGH-VOLUME OPTIMIZATION");
        console.log("   Config: 32 words, 30 spacing");
        console.log("   Precision: $0.09 at $2500 ETH");
        console.log("   Use case: Balance precision vs tick crosses");
        console.log("   Trade-off: ~13 tick crosses for 4% move");
    }
    
    function test_GasBreakdown32Words() public {
        console.log("\n=== GAS BREAKDOWN FOR 32 WORDS ===");
        
        uint256 baseGas = 70000;
        uint256 perWordGas = 1500;
        uint256 total = baseGas + (32 * perWordGas);
        
        console.log("Base operations: ", baseGas, "gas");
        console.log("Bitmap updates:  ", 32 * perWordGas, "gas (32 x 1500)");
        console.log("Total:           ", total, "gas");
        
        console.log("\nCompared to defaults:");
        console.log("- 16 words: 94k gas (baseline)");
        console.log("- 32 words: 118k gas (+25%)");
        console.log("- Worth it for: <$0.50 precision needs");
    }
    
    // Helper functions
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function pad(string memory str, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length >= length) return str;
        
        bytes memory result = new bytes(length);
        uint256 diff = length - strBytes.length;
        
        for (uint i = 0; i < diff; i++) {
            result[i] = " ";
        }
        for (uint i = 0; i < strBytes.length; i++) {
            result[diff + i] = strBytes[i];
        }
        return string(result);
    }
}