// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TickBitmap
/// @notice Bitmap for tracking active ticks with orders
/// @dev Efficient O(log n) lookup for next active tick
library TickBitmap {
    /// @notice Get the position in the bitmap for a tick
    /// @param tick The tick
    /// @return wordPos The position in the word array
    /// @return bitPos The position within the word
    function position(int24 tick)
        internal
        pure
        returns (int16 wordPos, uint8 bitPos)
    {
        // Divide by 256 to get word position
        wordPos = int16(tick >> 8);
        // Modulo 256 to get bit position
        bitPos = uint8(uint24(tick % 256));
    }

    /// @notice Set a tick as active (has orders)
    /// @param self The bitmap storage
    /// @param tick The tick to set
    function setTick(
        mapping(int16 => uint256) storage self,
        int24 tick
    ) internal {
        (int16 wordPos, uint8 bitPos) = position(tick);
        uint256 mask = 1 << bitPos;
        self[wordPos] |= mask;
    }

    /// @notice Clear a tick (no more orders)
    /// @param self The bitmap storage
    /// @param tick The tick to clear
    function clearTick(
        mapping(int16 => uint256) storage self,
        int24 tick
    ) internal {
        (int16 wordPos, uint8 bitPos) = position(tick);
        uint256 mask = 1 << bitPos;
        self[wordPos] &= ~mask;
    }

    /// @notice Check if a tick is active
    /// @param self The bitmap storage
    /// @param tick The tick to check
    /// @return active True if tick has orders
    function isTickActive(
        mapping(int16 => uint256) storage self,
        int24 tick
    ) internal view returns (bool) {
        (int16 wordPos, uint8 bitPos) = position(tick);
        uint256 mask = 1 << bitPos;
        return self[wordPos] & mask != 0;
    }

    /// @notice Find next active tick at or after the given tick
    /// @param self The bitmap storage
    /// @param tick Starting tick
    /// @param tickSpacing Tick spacing
    /// @return next Next active tick, or type(int24).max if none found
    function nextActiveTickGTE(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal view returns (int24 next) {
        // Round to tick spacing
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        tick = compressed * tickSpacing;

        (int16 wordPos, uint8 bitPos) = position(tick);

        // Create mask for bits >= bitPos
        uint256 mask = type(uint256).max << bitPos;
        uint256 masked = self[wordPos] & mask;

        // If there's an active bit in this word at or after current position
        if (masked != 0) {
            uint8 lsb = _leastSignificantBit(masked);
            return (int24(wordPos) * 256 + int24(uint24(lsb))) * tickSpacing;
        }

        // Search subsequent words
        wordPos++;
        while (wordPos < type(int16).max) {
            if (self[wordPos] != 0) {
                uint8 lsb = _leastSignificantBit(self[wordPos]);
                return (int24(wordPos) * 256 + int24(uint24(lsb))) * tickSpacing;
            }
            wordPos++;
        }

        // No active tick found
        return type(int24).max;
    }

    /// @notice Find next active tick at or before the given tick
    /// @param self The bitmap storage
    /// @param tick Starting tick
    /// @param tickSpacing Tick spacing
    /// @return prev Previous active tick, or type(int24).min if none found
    function nextActiveTickLTE(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal view returns (int24 prev) {
        // Round to tick spacing
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        tick = compressed * tickSpacing;

        (int16 wordPos, uint8 bitPos) = position(tick);

        // Create mask for bits <= bitPos
        uint256 mask = (1 << (bitPos + 1)) - 1;
        uint256 masked = self[wordPos] & mask;

        // If there's an active bit in this word at or before current position
        if (masked != 0) {
            uint8 msb = _mostSignificantBit(masked);
            return (int24(wordPos) * 256 + int24(uint24(msb))) * tickSpacing;
        }

        // Search previous words
        wordPos--;
        while (wordPos > type(int16).min) {
            if (self[wordPos] != 0) {
                uint8 msb = _mostSignificantBit(self[wordPos]);
                return (int24(wordPos) * 256 + int24(uint24(msb))) * tickSpacing;
            }
            wordPos--;
        }

        // No active tick found
        return type(int24).min;
    }

    /// @notice Find the least significant bit (rightmost set bit)
    /// @param x The value to search
    /// @return r The position of the LSB (0-255)
    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        require(x > 0, "TickBitmap: zero value");

        r = 0;

        if (x & type(uint128).max == 0) {
            r += 128;
            x >>= 128;
        }
        if (x & type(uint64).max == 0) {
            r += 64;
            x >>= 64;
        }
        if (x & type(uint32).max == 0) {
            r += 32;
            x >>= 32;
        }
        if (x & type(uint16).max == 0) {
            r += 16;
            x >>= 16;
        }
        if (x & type(uint8).max == 0) {
            r += 8;
            x >>= 8;
        }
        if (x & 0xf == 0) {
            r += 4;
            x >>= 4;
        }
        if (x & 0x3 == 0) {
            r += 2;
            x >>= 2;
        }
        if (x & 0x1 == 0) {
            r += 1;
        }
    }

    /// @notice Find the most significant bit (leftmost set bit)
    /// @param x The value to search
    /// @return r The position of the MSB (0-255)
    function _mostSignificantBit(uint256 x) private pure returns (uint8 r) {
        require(x > 0, "TickBitmap: zero value");

        r = 0;

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) {
            r += 1;
        }
    }
}
