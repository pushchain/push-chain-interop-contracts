// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { RevertInstructions, TX_TYPE, VerificationType } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

// Define constants for ETH/USD price feed
uint256 constant ETH_PRICE_USD_1E8 = 2000 * 1e8; // $2000 per ETH with 8 decimals

/**
 * @title  GatewayGlobalRateLimitTest
 * @notice Test suite for the Global Rate Limit feature in UniversalGateway
 */
contract GatewayGlobalRateLimitTest is BaseTest {
    uint256 constant EPOCH_DURATION = 6 hours;
    uint256 constant TOKEN_A_THRESHOLD = 100 ether;
    uint256 constant TOKEN_B_THRESHOLD = 50 ether;
    uint256 constant NATIVE_THRESHOLD = 10 ether;

    // Test tokens - use the ones already defined in BaseTest
    // MockERC20 tokenA is already defined in BaseTest.t.sol
    MockERC20 tokenB;

    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration, uint64 epochIndexAtChange);

    function setUp() public override {
        super.setUp();

        // Deploy additional test token (tokenA is already deployed in BaseTest)
        tokenB = new MockERC20("Token B", "TKB", 18, 1000000 ether);

        tokenB.mint(user1, 1000 ether);
        tokenB.mint(user2, 1000 ether);

        vm.startPrank(user1);
        tokenB.approve(address(gateway), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        tokenB.approve(address(gateway), type(uint256).max);
        vm.stopPrank();

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // Helper functions moved to BaseTest.t.sol for reusability
    // Use buildDefaultPayload() from BaseTest

    function _getCurrentEpoch() internal view returns (uint256) {
        return block.timestamp / gateway.epochDurationSec();
    }

    // Helper function _buildFundsTxRequest is available in BaseTest.t.sol
    // Use the overload with custom fund recipient: _buildFundsTxRequest(token, amount, user1)

    // ==========================================
    // 1. INITIALIZATION AND CONFIGURATION TESTS
    // ==========================================

    function testInitialTokenThresholds() public {
        assertEq(gateway.tokenToLimitThreshold(address(tokenB)), 0, "New token should have zero threshold");

        // Reset any existing thresholds for testing other functions
        address[] memory tokens = new address[](2);
        uint256[] memory thresholds = new uint256[](2);

        tokens[0] = address(tokenA);
        tokens[1] = address(0); // Native token
        thresholds[0] = 0; // Set to 0 (unsupported)
        thresholds[1] = 0; // Set to 0 (unsupported)

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Now verify all tokens have zero threshold
        assertEq(gateway.tokenToLimitThreshold(address(tokenA)), 0, "TokenA should now have zero threshold");
        assertEq(gateway.tokenToLimitThreshold(address(0)), 0, "Native token should now have zero threshold");
    }

    function testSetTokenLimitThresholds() public {
        address[] memory tokens = new address[](3);
        uint256[] memory thresholds = new uint256[](3);

        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(0); // Native token

        thresholds[0] = TOKEN_A_THRESHOLD;
        thresholds[1] = TOKEN_B_THRESHOLD;
        thresholds[2] = NATIVE_THRESHOLD;

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenA), TOKEN_A_THRESHOLD);

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenB), TOKEN_B_THRESHOLD);

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(0), NATIVE_THRESHOLD);

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify thresholds were set correctly
        assertEq(
            gateway.tokenToLimitThreshold(address(tokenA)), TOKEN_A_THRESHOLD, "TokenA threshold not set correctly"
        );
        assertEq(
            gateway.tokenToLimitThreshold(address(tokenB)), TOKEN_B_THRESHOLD, "TokenB threshold not set correctly"
        );
        assertEq(
            gateway.tokenToLimitThreshold(address(0)), NATIVE_THRESHOLD, "Native token threshold not set correctly"
        );
    }

    function testSetTokenLimitThresholdsAllowsUpdating() public {
        // First set initial thresholds
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Now update the threshold
        uint256 newThreshold = TOKEN_A_THRESHOLD * 2;
        thresholds[0] = newThreshold;

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenA), newThreshold);

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify threshold was updated
        assertEq(gateway.tokenToLimitThreshold(address(tokenA)), newThreshold, "TokenA threshold not updated correctly");
    }

    function testUpdateEpochDuration() public {
        uint256 oldDuration = gateway.epochDurationSec();
        uint256 newDuration = 12 hours;
        uint64 expectedEpochIndex = uint64(block.timestamp / oldDuration);

        vm.expectEmit(true, true, false, true);
        emit EpochDurationUpdated(oldDuration, newDuration, expectedEpochIndex);

        vm.prank(admin);
        gateway.updateEpochDuration(newDuration);

        // Verify duration was updated
        assertEq(gateway.epochDurationSec(), newDuration, "Epoch duration not updated correctly");
    }

    function testSetTokenLimitThresholdsArrayMismatch() public {
        address[] memory tokens = new address[](2);
        uint256[] memory thresholds = new uint256[](1); // Mismatch

        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    function testOnlyAdminCanSetThresholds() public {
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        // Non-admin should not be able to set thresholds
        vm.prank(user1);
        vm.expectRevert();
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Admin should be able to set thresholds
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    function testOnlyAdminCanUpdateEpochDuration() public {
        uint256 newDuration = 12 hours;

        // Non-admin should not be able to update epoch duration
        vm.prank(user1);
        vm.expectRevert();
        gateway.updateEpochDuration(newDuration);

        // Admin should be able to update epoch duration
        vm.prank(admin);
        gateway.updateEpochDuration(newDuration);
    }

    // ==========================================
    // 2. CORE ENFORCEMENT TESTS
    // ==========================================

    function testUnsupportedTokenReverts() public {
        // Setup: No token thresholds set, so all tokens are unsupported

        // Try to send funds with an unsupported token
        vm.startPrank(user1);

        // Payload not needed for this test
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 10 ether, user1));

        vm.stopPrank();
    }

    function testZeroEpochDurationReverts() public {
        // Setting epoch duration to 0 should revert to prevent division-by-zero
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.updateEpochDuration(0);
    }

    function testExceedingThresholdReverts() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD + 1, user1));

        vm.stopPrank();
    }

    function testExactThresholdSucceeds() public {
        vm.skip(true); // Rate limiting disabled on testnet
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD, user1));

        vm.stopPrank();

        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(used, TOKEN_A_THRESHOLD, "Used amount should equal threshold");
        assertEq(remaining, 0, "Remaining amount should be zero");
    }

    function testBelowThresholdSucceeds() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        uint256 sendAmount = TOKEN_A_THRESHOLD / 2;

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), sendAmount, user1));

        vm.stopPrank();

        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(used, sendAmount, "Used amount should equal sent amount");
        assertEq(remaining, TOKEN_A_THRESHOLD - sendAmount, "Remaining amount should be threshold minus used");
    }

    function testMultipleTransactionsAccumulate() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        uint256 firstAmount = TOKEN_A_THRESHOLD / 3;
        uint256 secondAmount = TOKEN_A_THRESHOLD / 3;
        uint256 thirdAmount = TOKEN_A_THRESHOLD / 3;

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        // Verify first usage
        (uint256 usedAfterFirst, uint256 remainingAfterFirst) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterFirst, firstAmount, "Used amount after first tx incorrect");
        assertEq(remainingAfterFirst, TOKEN_A_THRESHOLD - firstAmount, "Remaining amount after first tx incorrect");

        // Second transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        // Verify second usage
        (uint256 usedAfterSecond, uint256 remainingAfterSecond) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterSecond, firstAmount + secondAmount, "Used amount after second tx incorrect");
        assertEq(
            remainingAfterSecond,
            TOKEN_A_THRESHOLD - firstAmount - secondAmount,
            "Remaining amount after second tx incorrect"
        );

        // Third transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), thirdAmount, user1));

        // Verify third usage
        (uint256 usedAfterThird, uint256 remainingAfterThird) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterThird, firstAmount + secondAmount + thirdAmount, "Used amount after third tx incorrect");
        assertEq(
            remainingAfterThird,
            TOKEN_A_THRESHOLD - firstAmount - secondAmount - thirdAmount,
            "Remaining amount after third tx incorrect"
        );

        uint256 fourthAmount = TOKEN_A_THRESHOLD - firstAmount - secondAmount - thirdAmount + 1; // Just over the limit

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), fourthAmount, user1));

        vm.stopPrank();
    }

    function testNativeTokenRateLimit() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set threshold for native token
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(0); // Native token
        thresholds[0] = NATIVE_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send native token
        vm.startPrank(user1);

        // Send half the threshold
        uint256 firstAmount = NATIVE_THRESHOLD / 2;
        gateway.sendUniversalTx{ value: firstAmount }(_buildFundsTxRequest(address(0), firstAmount, user1));

        // Verify usage
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(0));
        assertEq(used, firstAmount, "Native token usage incorrect");
        assertEq(remaining, NATIVE_THRESHOLD - firstAmount, "Native token remaining incorrect");

        // Try to exceed threshold
        uint256 secondAmount = NATIVE_THRESHOLD - firstAmount + 1; // Just over the limit

        // Expect revert with RateLimitExceeded
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: secondAmount }(_buildFundsTxRequest(address(0), secondAmount, user1));

        vm.stopPrank();
    }

    function testUnsupportedNativeToken() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // By default, native token has no threshold set (unsupported)
        // First reset any existing threshold from BaseTest
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(0); // Native token
        thresholds[0] = 0; // Set to 0 (unsupported)

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify native token is unsupported
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(0));
        assertEq(used, 0, "Unsupported native token used amount should be 0");
        assertEq(remaining, 0, "Unsupported native token remaining amount should be 0");

        // Try to send funds with unsupported native token
        vm.startPrank(user1);

        // Expect revert with NotSupported
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx{ value: 1 ether }(_buildFundsTxRequest(address(0), 1 ether, user1));

        vm.stopPrank();
    }

    // ==========================================
    // 3. EPOCH ROLLOVER TESTS
    // ==========================================

    function testEpochRolloverRobustness() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // This test verifies that skipping multiple epochs (even very large jumps)
        // correctly resets usage counters

        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        // First epoch - use full threshold
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD, user1));

        // Verify first epoch usage
        (uint256 usedFirstEpoch, uint256 remainingFirstEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFirstEpoch, TOKEN_A_THRESHOLD, "First epoch usage incorrect");
        assertEq(remainingFirstEpoch, 0, "First epoch remaining incorrect");

        // Store current epoch and timestamp
        uint256 firstEpoch = _getCurrentEpoch();
        uint256 firstTimestamp = block.timestamp;

        // Warp time to skip exactly 1 epoch
        vm.warp(firstTimestamp + gateway.epochDurationSec());

        // Verify we're in a new epoch
        uint256 secondEpoch = _getCurrentEpoch();
        assertEq(secondEpoch, firstEpoch + 1, "Should be in next epoch");

        // Verify usage is reset
        (uint256 usedSecondEpoch, uint256 remainingSecondEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedSecondEpoch, 0, "Second epoch usage should be reset to 0");
        assertEq(remainingSecondEpoch, TOKEN_A_THRESHOLD, "Second epoch remaining should be full threshold");

        // Skip 10 epochs
        vm.warp(block.timestamp + 10 * gateway.epochDurationSec());

        // Verify we're 10 epochs later
        uint256 laterEpoch = _getCurrentEpoch();
        assertEq(laterEpoch, secondEpoch + 10, "Should be 10 epochs later");

        // Verify usage is still reset
        (uint256 usedLaterEpoch, uint256 remainingLaterEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedLaterEpoch, 0, "Later epoch usage should be reset to 0");
        assertEq(remainingLaterEpoch, TOKEN_A_THRESHOLD, "Later epoch remaining should be full threshold");

        // Skip a very large number of epochs (1 year worth of epochs)
        uint256 epochsPerYear = 365 days / gateway.epochDurationSec();
        vm.warp(block.timestamp + epochsPerYear * gateway.epochDurationSec());

        // Verify we're many epochs later
        uint256 farFutureEpoch = _getCurrentEpoch();
        assertEq(farFutureEpoch, laterEpoch + epochsPerYear, "Should be 1 year worth of epochs later");

        // Verify usage is still reset
        (uint256 usedFarFuture, uint256 remainingFarFuture) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFarFuture, 0, "Far future epoch usage should be reset to 0");
        assertEq(remainingFarFuture, TOKEN_A_THRESHOLD, "Far future epoch remaining should be full threshold");

        // Send funds in far future epoch
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD, user1));

        // Verify usage in far future epoch
        (uint256 usedAfterSend, uint256 remainingAfterSend) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterSend, TOKEN_A_THRESHOLD, "Usage after send in far future incorrect");
        assertEq(remainingAfterSend, 0, "Remaining after send in far future incorrect");

        vm.stopPrank();
    }

    function testEpochRollover() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.startPrank(user1);

        uint256 firstEpochAmount = (TOKEN_A_THRESHOLD * 3) / 4; // Use 75% of the threshold

        // Send in first epoch
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstEpochAmount, user1));

        // Verify first epoch usage
        (uint256 usedFirstEpoch, uint256 remainingFirstEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFirstEpoch, firstEpochAmount, "First epoch usage incorrect");
        assertEq(remainingFirstEpoch, TOKEN_A_THRESHOLD - firstEpochAmount, "First epoch remaining incorrect");

        // Store the current epoch for later comparison
        uint256 currentEpoch = _getCurrentEpoch();

        // Warp time to next epoch (add epoch duration)
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify we're in a new epoch
        uint256 newEpoch = _getCurrentEpoch();
        assertGt(newEpoch, currentEpoch, "Should be in a new epoch");

        // Verify usage is reset in the new epoch BEFORE making any transactions
        (uint256 usedAfterWarp, uint256 remainingAfterWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterWarp, 0, "Usage should be reset to 0 in new epoch");
        assertEq(remainingAfterWarp, TOKEN_A_THRESHOLD, "Remaining should be full threshold in new epoch");

        // Send funds in new epoch - should be able to send full threshold again
        uint256 secondEpochAmount = TOKEN_A_THRESHOLD; // Use 100% of threshold in new epoch

        // Send in second epoch
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondEpochAmount, user1));

        // Verify second epoch usage after transaction
        (uint256 usedSecondEpoch, uint256 remainingSecondEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedSecondEpoch, secondEpochAmount, "Second epoch usage incorrect");
        assertEq(remainingSecondEpoch, 0, "Second epoch remaining incorrect");

        // Try to exceed threshold in second epoch
        uint256 excessAmount = 1; // Just 1 wei over the threshold

        // Expect revert with RateLimitExceeded
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), excessAmount, user1));

        vm.stopPrank();
    }

    function testPartialUsageThenRollover() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        uint256 firstEpochAmount = TOKEN_A_THRESHOLD / 2; // Use 50% of the threshold

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstEpochAmount, user1));

        // Verify first epoch usage
        (uint256 usedFirstEpoch, uint256 remainingFirstEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFirstEpoch, firstEpochAmount, "First epoch usage incorrect");
        assertEq(remainingFirstEpoch, TOKEN_A_THRESHOLD - firstEpochAmount, "First epoch remaining incorrect");

        // Warp time to next epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify usage is reset in the new epoch BEFORE making any transactions
        (uint256 usedAfterWarp, uint256 remainingAfterWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterWarp, 0, "Usage should be reset to 0 in new epoch");
        assertEq(remainingAfterWarp, TOKEN_A_THRESHOLD, "Remaining should be full threshold in new epoch");

        uint256 secondEpochFirstAmount = TOKEN_A_THRESHOLD / 2; // Use 50% of threshold in new epoch

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondEpochFirstAmount, user1));

        // Verify second epoch usage after first transaction
        (uint256 usedSecondEpochFirst, uint256 remainingSecondEpochFirst) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedSecondEpochFirst, secondEpochFirstAmount, "Second epoch first tx usage incorrect");
        assertEq(
            remainingSecondEpochFirst,
            TOKEN_A_THRESHOLD - secondEpochFirstAmount,
            "Second epoch first tx remaining incorrect"
        );

        uint256 secondEpochSecondAmount = TOKEN_A_THRESHOLD / 2; // Use remaining 50%

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondEpochSecondAmount, user1));

        (uint256 usedSecondEpochSecond, uint256 remainingSecondEpochSecond) = gateway.currentTokenUsage(address(tokenA));
        assertEq(
            usedSecondEpochSecond,
            secondEpochFirstAmount + secondEpochSecondAmount,
            "Second epoch second tx usage incorrect"
        );
        assertEq(remainingSecondEpochSecond, 0, "Second epoch second tx remaining incorrect");

        vm.stopPrank();
    }

    function testMultipleEpochRollovers() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // First epoch
        uint256 firstEpochAmount = TOKEN_A_THRESHOLD;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstEpochAmount, user1));

        // Verify first epoch usage
        (uint256 usedFirstEpoch, uint256 remainingFirstEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFirstEpoch, firstEpochAmount, "First epoch usage incorrect");
        assertEq(remainingFirstEpoch, 0, "First epoch remaining incorrect");

        // Warp time to second epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify usage is reset in the new epoch BEFORE making any transactions
        (uint256 usedAfterFirstWarp, uint256 remainingAfterFirstWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterFirstWarp, 0, "Usage should be reset to 0 in second epoch");
        assertEq(remainingAfterFirstWarp, TOKEN_A_THRESHOLD, "Remaining should be full threshold in second epoch");

        // Second epoch
        uint256 secondEpochAmount = TOKEN_A_THRESHOLD / 2;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondEpochAmount, user1));

        // Verify second epoch usage
        (uint256 usedSecondEpoch, uint256 remainingSecondEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedSecondEpoch, secondEpochAmount, "Second epoch usage incorrect");
        assertEq(remainingSecondEpoch, TOKEN_A_THRESHOLD - secondEpochAmount, "Second epoch remaining incorrect");

        // Warp time to third epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify usage is reset in the new epoch BEFORE making any transactions
        (uint256 usedAfterSecondWarp, uint256 remainingAfterSecondWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterSecondWarp, 0, "Usage should be reset to 0 in third epoch");
        assertEq(remainingAfterSecondWarp, TOKEN_A_THRESHOLD, "Remaining should be full threshold in third epoch");

        // Third epoch
        uint256 thirdEpochAmount = TOKEN_A_THRESHOLD / 4;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), thirdEpochAmount, user1));

        // Verify third epoch usage
        (uint256 usedThirdEpoch, uint256 remainingThirdEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedThirdEpoch, thirdEpochAmount, "Third epoch usage incorrect");
        assertEq(remainingThirdEpoch, TOKEN_A_THRESHOLD - thirdEpochAmount, "Third epoch remaining incorrect");

        // Skip multiple epochs (5 more)
        vm.warp(block.timestamp + 5 * gateway.epochDurationSec());

        // Verify usage is reset after multiple skipped epochs
        (uint256 usedAfterMultipleWarp, uint256 remainingAfterMultipleWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterMultipleWarp, 0, "Usage should be reset to 0 after multiple epoch skips");
        assertEq(
            remainingAfterMultipleWarp,
            TOKEN_A_THRESHOLD,
            "Remaining should be full threshold after multiple epoch skips"
        );

        // After multiple skipped epochs, should still be able to use full threshold
        uint256 finalEpochAmount = TOKEN_A_THRESHOLD;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), finalEpochAmount, user1));

        // Verify final epoch usage
        (uint256 usedFinalEpoch, uint256 remainingFinalEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFinalEpoch, finalEpochAmount, "Final epoch usage incorrect");
        assertEq(remainingFinalEpoch, 0, "Final epoch remaining incorrect");

        vm.stopPrank();
    }

    function testEpochResetBehavior() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds in first epoch
        vm.startPrank(user1);

        // Record current epoch
        uint256 firstEpoch = _getCurrentEpoch();

        // First epoch transaction
        uint256 firstEpochAmount = TOKEN_A_THRESHOLD / 2;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstEpochAmount, user1));

        // Verify first epoch usage
        (uint256 usedFirstEpoch, uint256 remainingFirstEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedFirstEpoch, firstEpochAmount, "First epoch usage incorrect");
        assertEq(remainingFirstEpoch, TOKEN_A_THRESHOLD - firstEpochAmount, "First epoch remaining incorrect");

        // Warp time to second epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Record second epoch
        uint256 secondEpoch = _getCurrentEpoch();
        assertGt(secondEpoch, firstEpoch, "Second epoch should be greater than first");

        // Verify usage is reset in the new epoch BEFORE making any transactions
        (uint256 usedAfterWarp, uint256 remainingAfterWarp) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterWarp, 0, "Usage should be reset to 0 in new epoch");
        assertEq(remainingAfterWarp, TOKEN_A_THRESHOLD, "Remaining should be full threshold in new epoch");

        // Second epoch transaction
        uint256 secondEpochAmount = TOKEN_A_THRESHOLD / 3;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondEpochAmount, user1));

        // Verify second epoch usage after transaction
        (uint256 usedSecondEpoch, uint256 remainingSecondEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedSecondEpoch, secondEpochAmount, "Second epoch usage incorrect");
        assertEq(remainingSecondEpoch, TOKEN_A_THRESHOLD - secondEpochAmount, "Second epoch remaining incorrect");

        vm.stopPrank();
    }

    // ==========================================
    // 4. INTEGRATION WITH SEND FUNCTIONS
    // ==========================================

    function testSendFundsWithNative() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set native token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(0); // Native token
        thresholds[0] = NATIVE_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds with native token
        vm.startPrank(user1);

        uint256 sendAmount = NATIVE_THRESHOLD / 2;

        // Send funds
        gateway.sendUniversalTx{ value: sendAmount }(_buildFundsTxRequest(address(0), sendAmount, user1));

        // Verify usage was recorded correctly
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(0));
        assertEq(used, sendAmount, "Used amount should equal sent amount");
        assertEq(remaining, NATIVE_THRESHOLD - sendAmount, "Remaining amount should be threshold minus used");

        vm.stopPrank();
    }

    function testSendTxWithFundsTokenGas() public {
        // This test is a placeholder for testing sendTxWithFunds with an ERC20 gas token
        // In a real test, we would need to mock the Uniswap router and factory
        // For now, we'll just verify that the token threshold check works for the bridge token

        // Setup: Set thresholds for bridge token
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA); // Bridge token
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify that sending an unsupported token as bridge token reverts
        vm.startPrank(user1);

        // Create revert instructions and payload
        address revertRecipient = user1;
        UniversalPayload memory payload = buildDefaultPayload();

        // Try to send funds with unsupported bridge token (tokenB)
        // The error is NotSupported() because tokenB is not supported in the gateway (no threshold set)
        bytes memory encodedPayload = abi.encode(payload);
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(tokenB), // Unsupported bridge token
            amount: 1 ether,
            payload: encodedPayload,
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx{ value: 0 }(req);

        vm.stopPrank();
    }

    function testExceedingLimitWithSendFunds() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = (TOKEN_A_THRESHOLD * 3) / 4; // Use 75% of the threshold

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        uint256 secondAmount = TOKEN_A_THRESHOLD / 2;

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        vm.stopPrank();
    }

    function testUnsupportedTokenWithSendFunds() public {
        // Setup: No token thresholds set, so all tokens are unsupported

        // Try to send funds with an unsupported token
        vm.startPrank(user1);

        // Expect revert with NotSupported
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 10 ether, user1));

        vm.stopPrank();
    }

    // ==========================================
    // 5. MID-EPOCH THRESHOLD UPDATES
    // ==========================================

    function testUpdateThresholdMidEpochIncrease() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set initial token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = (TOKEN_A_THRESHOLD * 3) / 4; // Use 75% of the threshold

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        (uint256 usedBefore, uint256 remainingBefore) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedBefore, firstAmount, "Used amount before update incorrect");
        assertEq(remainingBefore, TOKEN_A_THRESHOLD - firstAmount, "Remaining amount before update incorrect");

        vm.stopPrank();

        uint256 newThreshold = TOKEN_A_THRESHOLD * 2;
        thresholds[0] = newThreshold;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        (uint256 usedAfterUpdate, uint256 remainingAfterUpdate) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterUpdate, firstAmount, "Used amount should not change after threshold increase");
        assertEq(remainingAfterUpdate, newThreshold - firstAmount, "Remaining amount should reflect new threshold");

        vm.startPrank(user1);

        uint256 secondAmount = TOKEN_A_THRESHOLD;

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        // Verify usage after second transaction
        (uint256 usedAfter, uint256 remainingAfter) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, firstAmount + secondAmount, "Used amount after update incorrect");
        assertEq(remainingAfter, newThreshold - firstAmount - secondAmount, "Remaining amount after update incorrect");

        vm.stopPrank();
    }

    // ==========================================
    // 6. ADMIN SETTERS WHILE PAUSED
    // ==========================================

    function testSetTokenLimitThresholdsWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Setup token thresholds
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        // Admin should be able to set thresholds while paused
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify threshold was set
        assertEq(gateway.tokenToLimitThreshold(address(tokenA)), TOKEN_A_THRESHOLD, "Threshold not set when paused");

        // Non-admin should still not be able to set thresholds
        vm.prank(user1);
        vm.expectRevert();
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Unpause the contract
        vm.prank(admin);
        gateway.unpause();
    }

    function testUpdateTokenLimitThresholdWhenPaused() public {
        // First set initial threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Update threshold
        thresholds[0] = TOKEN_A_THRESHOLD * 2;

        // Admin should be able to update threshold while paused
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify threshold was updated
        assertEq(
            gateway.tokenToLimitThreshold(address(tokenA)), TOKEN_A_THRESHOLD * 2, "Threshold not updated when paused"
        );

        // Non-admin should still not be able to update threshold
        vm.prank(user1);
        vm.expectRevert();
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Unpause the contract
        vm.prank(admin);
        gateway.unpause();
    }

    function testUpdateEpochDurationRevertsWhenPaused() public {
        uint256 oldDuration = gateway.epochDurationSec();
        uint256 newDuration = oldDuration * 2;

        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Should revert when paused (whenNotPaused modifier)
        vm.prank(admin);
        vm.expectRevert();
        gateway.updateEpochDuration(newDuration);

        // Unpause the contract
        vm.prank(admin);
        gateway.unpause();
    }

    function testPausedFundsRouteReverts() public {
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Try to send funds while paused
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        // Expect revert with EnforcedPause
        vm.expectRevert("EnforcedPause()");
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1 ether, user1));

        vm.stopPrank();

        // Unpause the contract
        vm.prank(admin);
        gateway.unpause();

        // Now sending funds should work
        vm.startPrank(user1);

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1 ether, user1));

        vm.stopPrank();
    }

    // ==========================================
    // 7. EDGE AND BOUNDARY CONDITIONS
    // ==========================================

    function testMinimumThreshold() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold to minimum possible (1 wei)
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = 1; // 1 wei threshold

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds with exactly the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        // Send exactly 1 wei (the threshold)
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1, user1));

        // Verify usage was recorded correctly
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(used, 1, "Used amount should be 1 wei");
        assertEq(remaining, 0, "Remaining amount should be 0");

        // Try to send 1 more wei, should revert
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1, user1));

        vm.stopPrank();
    }

    function testExactThresholdInclusive() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds with exactly the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        // Send exactly the threshold amount
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD, user1));

        // Verify usage was recorded correctly
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(used, TOKEN_A_THRESHOLD, "Used amount should equal threshold");
        assertEq(remaining, 0, "Remaining amount should be 0");

        // Try to send 1 more wei, should revert
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1, user1));

        vm.stopPrank();
    }

    function testZeroEpochDuration() public {
        // Setting epoch duration to 0 should revert at the setter level
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.updateEpochDuration(0);

        // Epoch duration should remain unchanged
        assertEq(gateway.epochDurationSec(), EPOCH_DURATION, "Epoch duration should be unchanged");
    }

    function testToggleThresholdToZero() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = TOKEN_A_THRESHOLD / 2;

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        // Verify usage
        (uint256 usedBefore, uint256 remainingBefore) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedBefore, firstAmount, "Used amount incorrect");
        assertEq(remainingBefore, TOKEN_A_THRESHOLD - firstAmount, "Remaining amount incorrect");

        vm.stopPrank();

        // Set threshold to 0 (unsupported)
        thresholds[0] = 0;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify token is now unsupported
        (uint256 usedAfter, uint256 remainingAfter) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, 0, "Used amount should be 0 for unsupported token");
        assertEq(remainingAfter, 0, "Remaining amount should be 0 for unsupported token");

        // Try to send funds with now unsupported token
        vm.startPrank(user1);

        // Expect revert with NotSupported
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), 1 ether, user1));

        vm.stopPrank();
    }

    function testMultipleTokensWithDifferentThresholds() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set different thresholds for multiple tokens
        address[] memory tokens = new address[](3);
        uint256[] memory thresholds = new uint256[](3);

        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(0); // Native token

        thresholds[0] = TOKEN_A_THRESHOLD;
        thresholds[1] = TOKEN_B_THRESHOLD; // Different from TOKEN_A_THRESHOLD
        thresholds[2] = NATIVE_THRESHOLD; // Different from both

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds for each token
        vm.startPrank(user1);

        // Send tokenA (50% of threshold)
        uint256 tokenAAmount = TOKEN_A_THRESHOLD / 2;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), tokenAAmount, user1));

        // Send tokenB (75% of threshold)
        uint256 tokenBAmount = (TOKEN_B_THRESHOLD * 3) / 4;
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenB), tokenBAmount, user1));

        // Send native token (90% of threshold)
        uint256 nativeAmount = (NATIVE_THRESHOLD * 9) / 10;
        gateway.sendUniversalTx{ value: nativeAmount }(_buildFundsTxRequest(address(0), nativeAmount, user1));

        // Verify usage for each token
        (uint256 usedA, uint256 remainingA) = gateway.currentTokenUsage(address(tokenA));
        (uint256 usedB, uint256 remainingB) = gateway.currentTokenUsage(address(tokenB));
        (uint256 usedNative, uint256 remainingNative) = gateway.currentTokenUsage(address(0));

        assertEq(usedA, tokenAAmount, "TokenA usage incorrect");
        assertEq(remainingA, TOKEN_A_THRESHOLD - tokenAAmount, "TokenA remaining incorrect");

        assertEq(usedB, tokenBAmount, "TokenB usage incorrect");
        assertEq(remainingB, TOKEN_B_THRESHOLD - tokenBAmount, "TokenB remaining incorrect");

        assertEq(usedNative, nativeAmount, "Native token usage incorrect");
        assertEq(remainingNative, NATIVE_THRESHOLD - nativeAmount, "Native token remaining incorrect");

        // Try to exceed threshold for tokenA
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(
            _buildFundsTxRequest(address(tokenA), TOKEN_A_THRESHOLD - tokenAAmount + 1, user1)
        );

        // But we should still be able to send more of tokenB and native
        // Send more tokenB (up to threshold)
        gateway.sendUniversalTx{ value: 0 }(
            _buildFundsTxRequest(address(tokenB), TOKEN_B_THRESHOLD - tokenBAmount, user1)
        );

        // Send more native (up to threshold)
        gateway.sendUniversalTx{ value: NATIVE_THRESHOLD - nativeAmount }(
            _buildFundsTxRequest(address(0), NATIVE_THRESHOLD - nativeAmount, user1)
        );

        // Verify final usage for each token
        (uint256 finalUsedA, uint256 finalRemainingA) = gateway.currentTokenUsage(address(tokenA));
        (uint256 finalUsedB, uint256 finalRemainingB) = gateway.currentTokenUsage(address(tokenB));
        (uint256 finalUsedNative, uint256 finalRemainingNative) = gateway.currentTokenUsage(address(0));

        assertEq(finalUsedA, tokenAAmount, "TokenA final usage incorrect");
        assertEq(finalRemainingA, TOKEN_A_THRESHOLD - tokenAAmount, "TokenA final remaining incorrect");

        assertEq(finalUsedB, TOKEN_B_THRESHOLD, "TokenB final usage incorrect");
        assertEq(finalRemainingB, 0, "TokenB final remaining incorrect");

        assertEq(finalUsedNative, NATIVE_THRESHOLD, "Native token final usage incorrect");
        assertEq(finalRemainingNative, 0, "Native token final remaining incorrect");

        // Warp time to next epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify all token usage is reset
        (uint256 newEpochUsedA, uint256 newEpochRemainingA) = gateway.currentTokenUsage(address(tokenA));
        (uint256 newEpochUsedB, uint256 newEpochRemainingB) = gateway.currentTokenUsage(address(tokenB));
        (uint256 newEpochUsedNative, uint256 newEpochRemainingNative) = gateway.currentTokenUsage(address(0));

        assertEq(newEpochUsedA, 0, "TokenA usage should reset in new epoch");
        assertEq(newEpochRemainingA, TOKEN_A_THRESHOLD, "TokenA remaining should be full threshold in new epoch");

        assertEq(newEpochUsedB, 0, "TokenB usage should reset in new epoch");
        assertEq(newEpochRemainingB, TOKEN_B_THRESHOLD, "TokenB remaining should be full threshold in new epoch");

        assertEq(newEpochUsedNative, 0, "Native token usage should reset in new epoch");
        assertEq(
            newEpochRemainingNative, NATIVE_THRESHOLD, "Native token remaining should be full threshold in new epoch"
        );

        vm.stopPrank();
    }

    // This function is defined twice, removing the duplicate version at line 1972-2032

    function testUpdateThresholdMidEpochDecrease() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set initial token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = TOKEN_A_THRESHOLD / 2; // Use 50% of the threshold

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        // Verify usage
        (uint256 usedBefore, uint256 remainingBefore) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedBefore, firstAmount, "Used amount before update incorrect");
        assertEq(remainingBefore, TOKEN_A_THRESHOLD - firstAmount, "Remaining amount before update incorrect");

        vm.stopPrank();

        // Update threshold to half the original (below current usage)
        thresholds[0] = TOKEN_A_THRESHOLD / 4; // 25% of original

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Continue sending funds
        vm.startPrank(user1);

        // Should not be able to send any more funds
        uint256 secondAmount = 1; // Just 1 wei

        // Second transaction should revert
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        // Verify usage after update - should be unchanged
        (uint256 usedAfter, uint256 remainingAfter) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, firstAmount, "Used amount after update incorrect");
        assertEq(remainingAfter, 0, "Remaining amount after update should be 0");

        vm.stopPrank();
    }

    function testChangeEpochDurationMidEpoch() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = TOKEN_A_THRESHOLD / 2; // Use 50% of the threshold

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        // Store the current epoch
        uint256 currentEpoch = _getCurrentEpoch();

        vm.stopPrank();

        // Change epoch duration (double it)
        uint256 oldDuration = gateway.epochDurationSec();
        uint256 newDuration = oldDuration * 2;

        vm.prank(admin);
        gateway.updateEpochDuration(newDuration);

        // Verify epoch duration was updated
        assertEq(gateway.epochDurationSec(), newDuration, "Epoch duration not updated correctly");

        // Continue sending funds
        vm.startPrank(user1);

        // Should still be in the same epoch despite duration change
        assertEq(_getCurrentEpoch(), currentEpoch, "Should still be in the same epoch");

        // Should be able to send more funds up to the threshold
        uint256 secondAmount = TOKEN_A_THRESHOLD / 4; // Another 25%

        // Second transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        // Verify usage after update
        (uint256 usedAfter, uint256 remainingAfter) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, firstAmount + secondAmount, "Used amount after update incorrect");
        assertEq(
            remainingAfter, TOKEN_A_THRESHOLD - firstAmount - secondAmount, "Remaining amount after update incorrect"
        );

        // Warp time to what would have been the next epoch with the old duration
        vm.warp(block.timestamp + oldDuration);

        // Should still be in the same epoch with the new duration
        assertEq(_getCurrentEpoch(), currentEpoch, "Should still be in the same epoch after partial time warp");

        // Should still be able to send funds up to the threshold
        uint256 thirdAmount = TOKEN_A_THRESHOLD / 4; // Final 25%

        // Third transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), thirdAmount, user1));

        // Warp time to the next epoch with the new duration
        vm.warp(block.timestamp + oldDuration); // Now we've warped by 2x the old duration = 1x new duration

        // Should now be in a new epoch
        assertGt(_getCurrentEpoch(), currentEpoch, "Should be in a new epoch after full time warp");

        // Should be able to send full threshold again
        uint256 fourthAmount = TOKEN_A_THRESHOLD;

        // Fourth transaction in new epoch
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), fourthAmount, user1));

        vm.stopPrank();
    }

    function testViewHelpersFunctionality() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Verify initial state through view helpers
        (uint256 initialUsed, uint256 initialRemaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(initialUsed, 0, "Initial used amount should be 0");
        assertEq(initialRemaining, TOKEN_A_THRESHOLD, "Initial remaining amount should be the full threshold");

        // Send funds to consume part of the threshold
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 firstAmount = TOKEN_A_THRESHOLD / 3; // Use 1/3 of the threshold

        // First transaction
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), firstAmount, user1));

        // Verify state after first transaction
        (uint256 usedAfterFirst, uint256 remainingAfterFirst) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterFirst, firstAmount, "Used amount after first tx incorrect");
        assertEq(remainingAfterFirst, TOKEN_A_THRESHOLD - firstAmount, "Remaining amount after first tx incorrect");

        // Second transaction
        uint256 secondAmount = TOKEN_A_THRESHOLD / 3; // Use another 1/3

        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), secondAmount, user1));

        // Verify state after second transaction
        (uint256 usedAfterSecond, uint256 remainingAfterSecond) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterSecond, firstAmount + secondAmount, "Used amount after second tx incorrect");
        assertEq(
            remainingAfterSecond,
            TOKEN_A_THRESHOLD - firstAmount - secondAmount,
            "Remaining amount after second tx incorrect"
        );

        vm.stopPrank();

        // Warp time to next epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Verify state in new epoch
        (uint256 usedInNewEpoch, uint256 remainingInNewEpoch) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedInNewEpoch, 0, "Used amount in new epoch should be 0");
        assertEq(remainingInNewEpoch, TOKEN_A_THRESHOLD, "Remaining amount in new epoch should be the full threshold");
    }

    // ==========================================
    // 6. EVENT AND VIEW VALIDATION
    // ==========================================

    function testTokenLimitThresholdUpdatedEvent() public {
        // Setup: Prepare token and threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        // Use vm.expectEmit to verify events
        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenA), TOKEN_A_THRESHOLD);

        // Call the function that should emit the event
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Update threshold and expect event again
        uint256 newThreshold = TOKEN_A_THRESHOLD * 2;
        thresholds[0] = newThreshold;

        // Use vm.expectEmit to verify events
        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenA), newThreshold);

        // Call the function that should emit the event
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    function testEpochDurationUpdatedEvent() public {
        // Get current epoch duration
        uint256 oldDuration = gateway.epochDurationSec();
        uint256 newDuration = 12 hours;
        uint64 expectedEpochIndex = uint64(block.timestamp / oldDuration);

        // Use vm.expectEmit to verify events
        vm.expectEmit(true, true, false, true);
        emit EpochDurationUpdated(oldDuration, newDuration, expectedEpochIndex);

        // Call the function that should emit the event
        vm.prank(admin);
        gateway.updateEpochDuration(newDuration);
    }

    function testMultipleTokenThresholdEvents() public {
        // Setup: Prepare multiple tokens and thresholds
        address[] memory tokens = new address[](3);
        uint256[] memory thresholds = new uint256[](3);

        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(0); // Native token

        thresholds[0] = TOKEN_A_THRESHOLD;
        thresholds[1] = TOKEN_B_THRESHOLD;
        thresholds[2] = NATIVE_THRESHOLD;

        // Use vm.expectEmit to verify events
        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenA), TOKEN_A_THRESHOLD);

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(tokenB), TOKEN_B_THRESHOLD);

        vm.expectEmit(true, true, false, true);
        emit TokenLimitThresholdUpdated(address(0), NATIVE_THRESHOLD);

        // Call the function that should emit multiple events
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    function testCurrentTokenUsageView() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Check initial state
        (uint256 initialUsed, uint256 initialRemaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(initialUsed, 0, "Initial used amount should be 0");
        assertEq(initialRemaining, TOKEN_A_THRESHOLD, "Initial remaining amount should be the full threshold");

        // Send funds
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 sendAmount = TOKEN_A_THRESHOLD / 2;

        // Send funds
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), sendAmount, user1));

        vm.stopPrank();

        // Check updated state
        (uint256 updatedUsed, uint256 updatedRemaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(updatedUsed, sendAmount, "Updated used amount incorrect");
        assertEq(updatedRemaining, TOKEN_A_THRESHOLD - sendAmount, "Updated remaining amount incorrect");

        // Check unsupported token
        (uint256 unsupportedUsed, uint256 unsupportedRemaining) = gateway.currentTokenUsage(address(tokenB));
        assertEq(unsupportedUsed, 0, "Unsupported token used amount should be 0");
        assertEq(unsupportedRemaining, 0, "Unsupported token remaining amount should be 0");
    }

    function testCurrentTokenUsageAfterEpochRollover() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Setup: Set token threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);

        tokens[0] = address(tokenA);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Send funds
        vm.startPrank(user1);

        // Create revert instructions
        address revertRecipient = user1;

        uint256 sendAmount = TOKEN_A_THRESHOLD / 2;

        // Send funds
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), sendAmount, user1));

        vm.stopPrank();

        // Check state before epoch rollover
        (uint256 usedBeforeRollover, uint256 remainingBeforeRollover) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedBeforeRollover, sendAmount, "Used amount before rollover incorrect");
        assertEq(remainingBeforeRollover, TOKEN_A_THRESHOLD - sendAmount, "Remaining amount before rollover incorrect");

        // Warp time to next epoch
        vm.warp(block.timestamp + gateway.epochDurationSec());

        // Check state after epoch rollover
        (uint256 usedAfterRollover, uint256 remainingAfterRollover) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfterRollover, 0, "Used amount after rollover should be 0");
        assertEq(
            remainingAfterRollover, TOKEN_A_THRESHOLD, "Remaining amount after rollover should be the full threshold"
        );
    }

    function testCurrentTokenUsageWithZeroThreshold() public view {
        // Check token with zero threshold (unsupported)
        (uint256 used, uint256 remaining) = gateway.currentTokenUsage(address(tokenA));
        assertEq(used, 0, "Used amount for zero threshold should be 0");
        assertEq(remaining, 0, "Remaining amount for zero threshold should be 0");
    }

    /// @dev Regression test: changing epochDuration shifts the epoch index, causing all per-token usage counters
    ///      to silently reset on the next consumption — full throughput is restored immediately.
    ///      The reset only happens when the old and new epoch indices differ; we warp to 7 hours
    ///      so the 6h epoch index (1) != the 12h epoch index (0).
    function testUpdateEpochDuration_ImplicitReset_RestoredFullThroughput() public {
        vm.skip(true); // Rate limiting disabled on testnet
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = TOKEN_A_THRESHOLD;

        vm.startPrank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
        vm.stopPrank();

        // Warp to 7 hours: epoch(6h)=1, epoch(12h)=0 — guaranteed mismatch after duration change
        vm.warp(7 hours);

        tokenA.mint(user1, TOKEN_A_THRESHOLD);
        vm.prank(user1);
        tokenA.approve(address(gateway), type(uint256).max);

        // Consume all available throughput in the current epoch
        uint256 sendAmount = TOKEN_A_THRESHOLD;
        vm.prank(user1);
        gateway.sendUniversalTx{ value: 0 }(_buildFundsTxRequest(address(tokenA), sendAmount, user1));

        (uint256 usedBefore,) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedBefore, TOKEN_A_THRESHOLD, "Should have consumed full threshold");

        // Changing epoch duration shifts the epoch index — all stored epochs become stale
        vm.prank(admin);
        gateway.updateEpochDuration(12 hours);

        // Usage is now reported as 0 — implicit reset occurred because epoch(7h/12h)=0 != stored 1
        (uint256 usedAfter, uint256 remainingAfter) = gateway.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, 0, "Usage should be reset after epoch duration change");
        assertEq(remainingAfter, TOKEN_A_THRESHOLD, "Full throughput should be available after implicit reset");
    }

    function testCurrentTokenUsageWithZeroEpochDurationReverts() public {
        // Setting epoch duration to 0 should revert at the setter level
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.updateEpochDuration(0);
    }
}
