// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "../orderbook/TickMath.sol";

/// @title PrecisionHelper
/// @notice Helper functions for calculating and optimizing price precision
/// @dev Use this to determine optimal configuration for your use case
library PrecisionHelper {
    
    /// @notice Calculate price precision for given configuration
    /// @param tickSpacing The tick spacing of the pool
    /// @param wordsPerTick Number of bitmap words per tick
    /// @param currentPrice Current price of the asset (in wei, 18 decimals)
    /// @return precisionWei The minimum price precision in wei
    /// @return precisionCents The minimum price precision in cents
    function calculatePrecision(
        int24 tickSpacing,
        uint16 wordsPerTick,
        uint256 currentPrice
    ) internal pure returns (uint256 precisionWei, uint256 precisionCents) {
        // Calculate price range per tick
        // range = currentPrice × (1.0001^tickSpacing - 1)
        uint256 basisPoints = uint256(int256(tickSpacing)); // 1 tick = 1 basis point
        uint256 rangePercent = basisPoints; // Approximate for small values
        uint256 priceRange = (currentPrice * rangePercent) / 10000;
        
        // Calculate number of price points
        uint256 pricePoints = uint256(wordsPerTick) * 256; // 256 bits per word
        
        // Calculate precision
        precisionWei = priceRange / pricePoints;
        
        // Convert to cents (assuming 18 decimals)
        // 1 dollar = 1e18 wei, 1 cent = 1e16 wei
        precisionCents = (precisionWei * 100) / 1e18;
    }
    
    /// @notice Estimate gas cost for order placement
    /// @param wordsPerTick Number of bitmap words per tick
    /// @return estimatedGas Approximate gas cost
    function estimateOrderGas(uint16 wordsPerTick) internal pure returns (uint256 estimatedGas) {
        // Empirically derived formula
        uint256 baseGas = 70000; // Base cost
        uint256 perWordGas = 1500; // Additional cost per word
        estimatedGas = baseGas + (uint256(wordsPerTick) * perWordGas);
    }
    
    /// @notice Calculate storage requirements
    /// @param wordsPerTick Number of bitmap words per tick
    /// @return slotsPerTick Storage slots required per tick
    function calculateStorage(uint16 wordsPerTick) internal pure returns (uint256 slotsPerTick) {
        // 4 arrays per tick: buyBitmap, sellBitmap, buyFenwick, sellFenwick
        slotsPerTick = uint256(wordsPerTick) * 4;
    }
    
    /// @notice Recommend configuration based on use case
    /// @param isStablecoin True for stablecoin pairs
    /// @param isHighVolume True for high-volume pairs
    /// @param targetPrecisionCents Desired precision in cents
    /// @return recommendedWords Recommended wordsPerTick
    /// @return recommendedSpacing Recommended tickSpacing
    function recommendConfiguration(
        bool isStablecoin,
        bool isHighVolume,
        uint256 targetPrecisionCents
    ) internal pure returns (uint16 recommendedWords, int24 recommendedSpacing) {
        if (isStablecoin) {
            // Stablecoins need very high precision
            if (targetPrecisionCents <= 1) {
                // Sub-cent precision
                recommendedWords = 64;
                recommendedSpacing = 1;
            } else {
                // Few cents precision acceptable
                recommendedWords = 32;
                recommendedSpacing = 5;
            }
        } else if (isHighVolume) {
            // High volume pairs optimize for gas
            if (targetPrecisionCents <= 50) {
                // Sub-50 cent precision
                recommendedWords = 16;
                recommendedSpacing = 60;
            } else {
                // Dollar-level precision OK
                recommendedWords = 8;
                recommendedSpacing = 60;
            }
        } else {
            // Low volume or volatile pairs
            recommendedWords = 8;
            recommendedSpacing = 200;
        }
    }
    
    /// @notice Calculate effective spread based on precision
    /// @param precisionWei Minimum price precision in wei
    /// @return minSpreadBps Minimum possible spread in basis points
    function calculateMinSpread(uint256 precisionWei, uint256 currentPrice) 
        internal 
        pure 
        returns (uint256 minSpreadBps) 
    {
        // Minimum spread = 2 × precision (one tick up, one tick down)
        uint256 minSpreadWei = precisionWei * 2;
        minSpreadBps = (minSpreadWei * 10000) / currentPrice;
    }
    
    /// @notice Estimate number of tick crosses for price movement
    /// @param tickSpacing The tick spacing of the pool
    /// @param priceMovementPercent Price movement as percentage (100 = 1%)
    /// @return estimatedCrosses Number of ticks that would be crossed
    function estimateTickCrosses(
        int24 tickSpacing,
        uint256 priceMovementPercent
    ) internal pure returns (uint256 estimatedCrosses) {
        // Each tick represents tickSpacing basis points
        uint256 bpsPerTick = uint256(int256(tickSpacing));
        uint256 totalBps = priceMovementPercent * 100; // Convert percent to bps
        estimatedCrosses = totalBps / bpsPerTick;
    }
    
    /// @notice Check if configuration is valid
    /// @param wordsPerTick Number of bitmap words per tick
    /// @param maxWords Maximum allowed words (protocol limit)
    /// @return isValid True if configuration is valid
    /// @return reason Reason if invalid
    function validateConfiguration(
        uint16 wordsPerTick,
        uint16 maxWords
    ) internal pure returns (bool isValid, string memory reason) {
        if (wordsPerTick == 0) {
            return (false, "Words per tick cannot be zero");
        }
        
        if (wordsPerTick > maxWords) {
            return (false, "Exceeds maximum words per tick");
        }
        
        // Check if power of 2 (optional optimization)
        if ((wordsPerTick & (wordsPerTick - 1)) != 0) {
            // Not a power of 2, but still valid
            // Could warn about potential inefficiency
        }
        
        return (true, "");
    }
    
    /// @notice Calculate configuration efficiency score
    /// @param wordsPerTick Number of bitmap words per tick
    /// @param tickSpacing The tick spacing of the pool
    /// @param targetPrecisionCents Desired precision in cents
    /// @param currentPrice Current price of the asset
    /// @return score Efficiency score (higher is better)
    function calculateEfficiencyScore(
        uint16 wordsPerTick,
        int24 tickSpacing,
        uint256 targetPrecisionCents,
        uint256 currentPrice
    ) internal pure returns (uint256 score) {
        // Calculate actual precision
        (uint256 precisionWei, uint256 actualPrecisionCents) = calculatePrecision(
            tickSpacing,
            wordsPerTick,
            currentPrice
        );
        
        // Calculate gas cost
        uint256 gasEstimate = estimateOrderGas(wordsPerTick);
        
        // Score based on:
        // 1. How close to target precision (40% weight)
        // 2. Gas efficiency (60% weight)
        
        uint256 precisionScore;
        if (actualPrecisionCents <= targetPrecisionCents) {
            // Met or exceeded target
            precisionScore = 100;
        } else {
            // Didn't meet target
            precisionScore = (targetPrecisionCents * 100) / actualPrecisionCents;
        }
        
        // Gas score (inverse relationship)
        uint256 baselineGas = 94000; // 16 words baseline
        uint256 gasScore = (baselineGas * 100) / gasEstimate;
        
        // Combined score
        score = (precisionScore * 40 + gasScore * 60) / 100;
    }
}