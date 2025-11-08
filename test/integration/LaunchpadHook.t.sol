// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {LaunchpadHook} from "src/dojima/experimental/LaunchpadHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {MockERC20} from "../utils/Setup.sol";

contract LaunchpadHookTest is Test {
    LaunchpadHook hook;
    MockERC20 token;

    address constant POOL_MANAGER = 0xa96Ffc4e09A887Abe2Ce6dBb711754d2cb533E1f; // RISE testnet
    address creator = address(0x1);
    address buyer1 = address(0x2);
    address buyer2 = address(0x3);

    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant GRADUATION_THRESHOLD = 50 ether; // 50 ETH
    uint256 constant BASE_PRICE = 0.0001 ether; // 0.0001 ETH per token
    uint256 constant PRICE_INCREMENT = 0.00000001 ether; // Small increment per token

    function setUp() public {
        // Fork RISE testnet for testing
        vm.createSelectFork("https://testnet.riselabs.xyz");

        // Deploy hook
        hook = new LaunchpadHook(ICLPoolManager(POOL_MANAGER));

        // Deploy test token
        token = new MockERC20("Test Token", "TEST", 18);

        // Mint tokens to creator
        token.mint(creator, TOTAL_SUPPLY);
    }

    function testLaunchToken() public {
        vm.startPrank(creator);

        // Approve hook to spend tokens
        token.approve(address(hook), TOTAL_SUPPLY);

        // Launch token
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );

        assertEq(launchpadId, 1, "First launchpad should have ID 1");

        // Verify launchpad data
        LaunchpadHook.Launchpad memory launchpad = hook.getLaunchpad(launchpadId);

        assertEq(launchpad.token, address(token), "Token address mismatch");
        assertEq(launchpad.creator, creator, "Creator mismatch");
        assertEq(launchpad.totalSupply, TOTAL_SUPPLY, "Total supply mismatch");
        assertEq(launchpad.sold, 0, "Initial sold should be 0");
        assertEq(launchpad.raised, 0, "Initial raised should be 0");
        assertEq(launchpad.graduationThreshold, GRADUATION_THRESHOLD, "Graduation threshold mismatch");
        assertEq(launchpad.graduated, false, "Should not be graduated");
        assertEq(launchpad.basePrice, BASE_PRICE, "Base price mismatch");
        assertEq(launchpad.priceIncrement, PRICE_INCREMENT, "Price increment mismatch");

        // Verify tokens transferred to hook
        assertEq(token.balanceOf(address(hook)), TOTAL_SUPPLY, "Hook should hold all tokens");
        assertEq(token.balanceOf(creator), 0, "Creator should have 0 tokens");

        vm.stopPrank();
    }

    function testBuyTokens() public {
        // Launch token first
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Buy tokens
        uint256 ethAmount = 1 ether;
        vm.deal(buyer1, ethAmount);

        vm.startPrank(buyer1);
        uint256 tokensBefore = token.balanceOf(buyer1);

        hook.buyTokens{value: ethAmount}(launchpadId, 0);

        uint256 tokensAfter = token.balanceOf(buyer1);
        uint256 tokensReceived = tokensAfter - tokensBefore;

        assertGt(tokensReceived, 0, "Should receive tokens");

        // Verify launchpad state updated
        LaunchpadHook.Launchpad memory launchpad = hook.getLaunchpad(launchpadId);
        assertEq(launchpad.sold, tokensReceived, "Sold amount should match");
        assertEq(launchpad.raised, ethAmount, "Raised amount should match");

        vm.stopPrank();
    }

    function testPriceIncreasesWithSales() public {
        // Launch token
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Get initial price
        uint256 initialPrice = hook.getCurrentPrice(launchpadId);
        assertEq(initialPrice, BASE_PRICE, "Initial price should be base price");

        // Buy some tokens
        uint256 ethAmount = 0.1 ether;
        vm.deal(buyer1, ethAmount);
        vm.prank(buyer1);
        hook.buyTokens{value: ethAmount}(launchpadId, 0);

        // Price should have increased
        uint256 newPrice = hook.getCurrentPrice(launchpadId);
        assertGt(newPrice, initialPrice, "Price should increase after sales");
    }

    function testMultipleBuyers() public {
        // Launch token
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Buyer 1
        vm.deal(buyer1, 1 ether);
        vm.prank(buyer1);
        hook.buyTokens{value: 0.5 ether}(launchpadId, 0);
        uint256 buyer1Tokens = token.balanceOf(buyer1);

        // Buyer 2
        vm.deal(buyer2, 1 ether);
        vm.prank(buyer2);
        hook.buyTokens{value: 0.5 ether}(launchpadId, 0);
        uint256 buyer2Tokens = token.balanceOf(buyer2);

        // Both should have tokens
        assertGt(buyer1Tokens, 0, "Buyer 1 should have tokens");
        assertGt(buyer2Tokens, 0, "Buyer 2 should have tokens");

        // Buyer 1 should have more tokens (bought at lower price)
        assertGt(buyer1Tokens, buyer2Tokens, "Earlier buyer should get more tokens");
    }

    function testCannotBuyAfterGraduation() public {
        // Launch token
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Buy enough to trigger graduation
        vm.deal(buyer1, GRADUATION_THRESHOLD + 1 ether);
        vm.prank(buyer1);
        hook.buyTokens{value: GRADUATION_THRESHOLD}(launchpadId, 0);

        // Verify graduated
        LaunchpadHook.Launchpad memory launchpad = hook.getLaunchpad(launchpadId);
        assertTrue(launchpad.graduated, "Should be graduated");

        // Try to buy more - should revert
        vm.deal(buyer2, 1 ether);
        vm.prank(buyer2);
        vm.expectRevert(LaunchpadHook.AlreadyGraduated.selector);
        hook.buyTokens{value: 1 ether}(launchpadId, 0);
    }

    function testCannotBuyWithZeroETH() public {
        // Launch token
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Try to buy with 0 ETH
        vm.prank(buyer1);
        vm.expectRevert(LaunchpadHook.InsufficientPayment.selector);
        hook.buyTokens{value: 0}(launchpadId, 0);
    }

    function testSlippageProtection() public {
        // Launch token
        vm.startPrank(creator);
        token.approve(address(hook), TOTAL_SUPPLY);
        uint256 launchpadId = hook.launchToken(
            address(token),
            TOTAL_SUPPLY,
            GRADUATION_THRESHOLD,
            BASE_PRICE,
            PRICE_INCREMENT
        );
        vm.stopPrank();

        // Try to buy with high minTokensOut (will fail)
        vm.deal(buyer1, 1 ether);
        vm.prank(buyer1);
        vm.expectRevert(LaunchpadHook.InsufficientPayment.selector);
        hook.buyTokens{value: 0.1 ether}(launchpadId, 1_000_000 ether); // Unrealistic expectation
    }

    function testHookBitmap() public {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        assertEq(bitmap, 0x0020, "Should only have beforeInitialize hook");
    }
}
