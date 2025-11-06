// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title OrderBookTypes
/// @notice Data structures for high-precision order book
library OrderBookTypes {

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum number of uint256 words for bitmap
    /// @dev 100 words = 25,600 price points (100 * 256 bits)
    /// Changed from 40 to 100 for 2.5x capacity (minimal gas increase)
    uint256 constant MAX_BITMAP_WORDS = 100;

    /// @notice Maximum number of price points supported
    uint256 constant MAX_PRICE_POINTS = MAX_BITMAP_WORDS * 256;

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Order book price range configuration
    /// @dev Defines the min/max price and precision for the order book
    struct Config {
        uint256 minPrice;         // Minimum price (e.g., 2000e18 = $2,000)
        uint256 maxPrice;         // Maximum price (e.g., 3000e18 = $3,000)
        uint256 priceIncrement;   // Price increment (e.g., 0.01e18 = $0.01)
        uint256 numPricePoints;   // Total number of price points
    }

    /*//////////////////////////////////////////////////////////////
                            ORDER STRUCTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice Individual limit order
    /// @dev Packed into 2 storage slots for gas efficiency
    struct Order {
        address maker;           // Order creator (160 bits)
        uint32 orderId;          // Local order ID within price level (32 bits)
        uint64 reserved;         // Reserved for future use (64 bits)
        uint128 amount;          // Total order size (128 bits)
        uint128 filled;          // Amount already filled (128 bits)
        // Slot 0: 160 + 32 + 64 = 256 bits (fully packed!)
        // Slot 1: 128 + 128 = 256 bits (fully packed!)
    }

    /*//////////////////////////////////////////////////////////////
                            BOOK STRUCTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice Complete order book state
    /// @dev Contains sell and buy sides with bitmaps and Fenwick trees
    /// @dev Config is now stored in TickBooks.sharedConfig (saves ~88k gas per tick!)
    struct Book {
        // Sell side (asks)
        uint256[MAX_BITMAP_WORDS] sellBitmap;    // Bitmap of price levels with orders
        uint256[MAX_BITMAP_WORDS] sellFenwick;   // Fenwick tree for fast lookups
        mapping(uint256 => Order[]) sellOrders;  // Orders at each price level

        // Buy side (bids)
        uint256[MAX_BITMAP_WORDS] buyBitmap;
        uint256[MAX_BITMAP_WORDS] buyFenwick;
        mapping(uint256 => Order[]) buyOrders;

        // State
        uint256 marketPriceIndex;  // Current market price index (synced with pool)
        bool initialized;          // Whether this book has been initialized

        // Lazy bitmap update optimization
        mapping(uint256 => bool) sellDirty;  // Sell price levels needing Fenwick update
        mapping(uint256 => bool) buyDirty;   // Buy price levels needing Fenwick update
        uint256[] sellDirtyList;             // List of dirty sell price indices
        uint256[] buyDirtyList;              // List of dirty buy price indices
    }

    /*//////////////////////////////////////////////////////////////
                            MATCH RESULT
    //////////////////////////////////////////////////////////////*/

    /// @notice Result from matching a market order
    struct MatchResult {
        uint128 amountFilled;      // Total amount filled
        uint128 amountRemaining;   // Amount not filled
        uint256 totalCost;         // Total cost in quote currency
        uint256 avgPrice;          // Average execution price
        uint256 ordersMatched;     // Number of orders matched

        // Per-order fill tracking (for maker rebates)
        uint256[] filledOrderIds;  // Global order IDs that were filled
        uint128[] filledAmounts;   // Amount filled for each order
        uint256[] fillPrices;      // Execution price for each fill
        address[] makers;          // Maker address for each filled order
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event OrderPlaced(
        uint256 indexed globalOrderId,
        address indexed maker,
        uint256 price,
        uint128 amount,
        bool isBuy
    );

    event OrderFilled(
        uint256 indexed globalOrderId,
        address indexed maker,
        address indexed taker,
        uint128 amountFilled,
        uint256 price
    );

    event OrderCancelled(
        uint256 indexed globalOrderId,
        address indexed maker,
        uint128 amountRemaining
    );

    event PriceLevelCleared(
        uint256 indexed priceIndex,
        bool isBuy
    );

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error PriceOutOfRange(uint256 price);
    error InvalidAmount();
    error InvalidPriceIncrement();
    error OrderNotFound();
    error NotOrderMaker();
    error OrderAlreadyFilled();
    error InsufficientLiquidity();
    error InvalidConfiguration();
}

/*//////////////////////////////////////////////////////////////
                    GLOBAL ORDER ID LIBRARY
//////////////////////////////////////////////////////////////*/

/// @title GlobalOrderIdLibrary
/// @notice Encodes/decodes global order IDs to avoid storage costs
/// @dev Encoding scheme (256 bits total):
///      - poolId: 160 bits [255:96]
///      - tick: 24 bits [95:72] (stored as uint24, converted to/from int24)
///      - priceIndex: 32 bits [71:40]
///      - localOrderId: 32 bits [39:8]
///      - isBuy: 8 bits [7:0]
library GlobalOrderIdLibrary {

    /// @notice Encode order components into a global order ID
    /// @param poolId The pool ID
    /// @param tick The tick containing the order
    /// @param priceIndex The price level index within the tick
    /// @param localOrderId The local order ID within the price level
    /// @param isBuy Whether this is a buy order
    /// @return globalOrderId The encoded global order ID
    function encode(
        PoolId poolId,
        int24 tick,
        uint256 priceIndex,
        uint32 localOrderId,
        bool isBuy
    ) internal pure returns (uint256 globalOrderId) {
        // Convert PoolId to bytes32, then to uint160
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        uint160 poolIdUint = uint160(uint256(poolIdBytes));

        // Convert int24 tick to uint24 for packing
        uint24 tickUint = int24ToUint24(tick);

        // Pack all components
        globalOrderId = (uint256(poolIdUint) << 96)
                      | (uint256(tickUint) << 72)
                      | ((priceIndex & 0xFFFFFFFF) << 40)
                      | ((uint256(localOrderId) & 0xFFFFFFFF) << 8)
                      | (isBuy ? 1 : 0);
    }

    /// @notice Decode a global order ID into its components
    /// @param globalOrderId The global order ID to decode
    /// @return poolId The pool ID
    /// @return tick The tick containing the order
    /// @return priceIndex The price level index within the tick
    /// @return localOrderId The local order ID within the price level
    /// @return isBuy Whether this is a buy order
    function decode(uint256 globalOrderId) internal pure returns (
        PoolId poolId,
        int24 tick,
        uint256 priceIndex,
        uint32 localOrderId,
        bool isBuy
    ) {
        // Extract poolId (top 160 bits)
        uint160 poolIdUint = uint160(globalOrderId >> 96);
        poolId = PoolId.wrap(bytes32(uint256(poolIdUint)));

        // Extract tick (next 24 bits)
        uint24 tickUint = uint24((globalOrderId >> 72) & 0xFFFFFF);
        tick = uint24ToInt24(tickUint);

        // Extract priceIndex (next 32 bits)
        priceIndex = uint256((globalOrderId >> 40) & 0xFFFFFFFF);

        // Extract localOrderId (next 32 bits)
        localOrderId = uint32((globalOrderId >> 8) & 0xFFFFFFFF);

        // Extract isBuy (bottom 8 bits)
        isBuy = (globalOrderId & 0xFF) == 1;
    }

    /// @notice Convert int24 to uint24 for packing
    /// @param value The int24 value
    /// @return The uint24 representation
    function int24ToUint24(int24 value) internal pure returns (uint24) {
        // Add offset to make all values positive
        // int24 range: -8,388,608 to 8,388,607
        // After offset: 0 to 16,777,215 (fits in uint24)
        return uint24(uint256(int256(value) + 8388608));
    }

    /// @notice Convert uint24 back to int24
    /// @param value The uint24 value
    /// @return The int24 representation
    function uint24ToInt24(uint24 value) internal pure returns (int24) {
        // Subtract offset to restore original value
        return int24(int256(uint256(value)) - 8388608);
    }
}
