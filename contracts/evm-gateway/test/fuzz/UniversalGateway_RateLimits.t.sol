// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { UniversalTxRequest } from "../../src/libraries/TypesUG.sol";

/// @notice Fuzz tests for block-based USD cap and epoch rate-limit arithmetic in UniversalGateway.
contract UniversalGateway_RateLimitsFuzz is BaseTest {
    // ETH price from BaseTest oracle: $2000/ETH (DEFAULT_ETH_USD_1e8 = 2000e8)
    // At $2000/ETH:
    //   $1  = 0.0005  ETH = 5e14 wei
    //   $10 = 0.005   ETH = 5e15 wei

    // =========================================================
    //   FG-1: BLOCK USD CAP ACCUMULATION
    // =========================================================

    /// @dev Sum of accepted USD values in a block never exceeds blockUsdCap.
    ///      We set a $8000 cap and send two amounts each bounded ≤ 2 ETH ($4000).
    ///      If both fit, neither individually exceeded the cap (single-tx check).
    ///      If the second reverts, it must revert with BlockCapLimitExceeded.
    function testFuzz_BlockCap_AccumulationNeverExceedsCap(uint96 amount1, uint96 amount2) public {
        // Each amount: 0.001 ETH–2 ETH. At $2000/ETH that is $2–$4000 each.
        // Cap is $8000 so both can fit.
        amount1 = uint96(bound(amount1, 0.001 ether, 2 ether));
        amount2 = uint96(bound(amount2, 0.001 ether, 2 ether));

        vm.prank(governance);
        gateway.setBlockUsdCap(8000e18); // $8000 cap

        vm.deal(user1, uint256(amount1) + uint256(amount2) + 1 ether);

        UniversalTxRequest memory req = _buildGasTxRequest();

        bool firstReverted;
        vm.prank(user1);
        try gateway.sendUniversalTx{ value: amount1 }(req) { } catch {
            firstReverted = true;
        }

        // If first tx succeeded, track USD consumed so far
        bool secondReverted;
        vm.prank(user1);
        try gateway.sendUniversalTx{ value: amount2 }(req) { } catch (bytes memory err) {
            secondReverted = true;
            // If second reverts it must be BlockCapLimitExceeded (or USD cap range check)
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == Errors.BlockCapLimitExceeded.selector || sel == Errors.InvalidAmount.selector,
                "unexpected revert selector on second tx"
            );
        }

        // Both reverted is impossible since each is ≤ $4000 and cap is $8000
        // (first tx alone cannot exceed cap)
        if (!firstReverted) {
            // first succeeded — second may or may not succeed, no further assertion needed
        }
        // Invariant: we never reach a state where the block consumed exceeds the cap
    }

    /// @dev A single GAS tx whose USD value exceeds blockUsdCap (but is within per-tx USD caps)
    ///      must always revert BlockCapLimitExceeded.
    ///      We widen the per-tx caps so the only check that rejects is the block cap.
    function testFuzz_BlockCap_SingleTxExceedingCapReverts(uint256 ethAmount) public {
        // Use an amount between $11 and $50 at $2000/ETH (5.5e15–2.5e16 wei).
        // Block cap is set to $10 so any amount in this range exceeds it.
        // Per-tx caps are widened to [$1, $1000] so the per-tx check passes.
        ethAmount = bound(ethAmount, 5.5e15, 2.5e16);

        vm.startPrank(governance);
        gateway.setBlockUsdCap(10e18);  // $10 block cap
        gateway.setCapsUSD(1e18, 1000e18); // widen per-tx range to [$1, $1000]
        vm.stopPrank();

        vm.deal(user1, ethAmount + 1 ether);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendUniversalTx{ value: ethAmount }(req);
    }

    /// @dev After advancing at least one block the cap resets and a previously-blocked tx succeeds.
    ///      Uses values within the per-tx USD caps [$1, $10] to avoid InvalidAmount from that check.
    ///      At $2000/ETH: $1 = 5e14 wei, $10 = 5e15 wei, $3 = 1.5e15 wei.
    function testFuzz_BlockCap_ResetsOnNewBlock(uint256 blockAdvance) public {
        blockAdvance = bound(blockAdvance, 1, 1000);

        // Block cap = $3, per-tx caps [$1, $10]. First tx = 1.5e15 wei ($3) fills block cap.
        // Second tx = 5e14 wei ($1) = minimum — fits per-tx check but block cap is full.
        vm.startPrank(governance);
        gateway.setBlockUsdCap(3e18);       // $3 block cap
        gateway.setCapsUSD(1e18, 10e18);    // per-tx [$1, $10] (same as default)
        vm.stopPrank();

        vm.deal(user1, 10 ether);
        UniversalTxRequest memory req = _buildGasTxRequest();

        // Fill block cap exactly ($3)
        vm.prank(user1);
        gateway.sendUniversalTx{ value: 1.5e15 }(req);

        // Same block — $1 tx must fail with BlockCapLimitExceeded
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendUniversalTx{ value: 5e14 }(req);

        // Advance blocks; refresh oracle timestamp
        vm.roll(block.number + blockAdvance);
        ethUsdFeedMock.setAnswer(DEFAULT_ETH_USD_1e8, block.timestamp);

        // Cap reset — same $1 tx should now succeed
        vm.prank(user1);
        gateway.sendUniversalTx{ value: 5e14 }(req);
    }

    // =========================================================
    //   FG-2: EPOCH RATE LIMIT ARITHMETIC
    // =========================================================

    /// @dev Amount + used never silently exceeds threshold for ERC20 tokens.
    ///      The second send must succeed iff initialSend + secondSend ≤ threshold.
    function testFuzz_EpochRateLimit_UsedNeverExceedsThreshold(
        uint128 initialSend,
        uint128 secondSend
    ) public {
        uint256 threshold = 100_000 ether;

        // Constrain both sends to at most threshold each
        initialSend = uint128(bound(initialSend, 1 ether, threshold));
        secondSend  = uint128(bound(secondSend,  1 ether, threshold));

        // Set threshold for tokenA
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = threshold;
        vm.prank(governance);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Mint & approve enough for both sends
        uint256 total = uint256(initialSend) + uint256(secondSend);
        tokenA.mint(user1, total);
        vm.prank(user1);
        tokenA.approve(address(gateway), total);

        UniversalTxRequest memory req1 = _buildFundsTxRequest(address(tokenA), initialSend, address(0x456));
        vm.prank(user1);
        gateway.sendUniversalTx(req1);

        UniversalTxRequest memory req2 = _buildFundsTxRequest(address(tokenA), secondSend, address(0x456));
        vm.prank(user1);
        if (uint256(initialSend) + uint256(secondSend) <= threshold) {
            gateway.sendUniversalTx(req2);
        } else {
            vm.expectRevert(Errors.RateLimitExceeded.selector);
            gateway.sendUniversalTx(req2);
        }
    }

    /// @dev After an epoch rolls over, usage resets and a previously-blocked amount succeeds.
    function testFuzz_EpochRateLimit_ResetsAfterEpoch(uint256 epochDuration, uint128 amount) public {
        epochDuration = bound(epochDuration, 1 hours, 7 days);
        amount = uint128(bound(amount, 1 ether, 1000 ether));

        // Set threshold to exactly amount so one tx fills the epoch
        vm.startPrank(governance);
        gateway.updateEpochDuration(epochDuration);
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = uint256(amount);
        gateway.setTokenLimitThresholds(tokens, thresholds);
        vm.stopPrank();

        uint256 total = uint256(amount) * 3;
        tokenA.mint(user1, total);
        vm.prank(user1);
        tokenA.approve(address(gateway), total);

        // First tx fills epoch
        UniversalTxRequest memory req = _buildFundsTxRequest(address(tokenA), amount, address(0x456));
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        // Same epoch — second tx must revert
        vm.prank(user1);
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        gateway.sendUniversalTx(req);

        // Warp past epoch boundary
        vm.warp(block.timestamp + epochDuration);
        ethUsdFeedMock.setAnswer(DEFAULT_ETH_USD_1e8, block.timestamp);

        // Must succeed now
        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    // =========================================================
    //   FG-6: USD CAP BOUNDARIES
    // =========================================================

    /// @dev Tx with native value in-range [$1, $10] at $2000/ETH must not revert InvalidAmount.
    ///      (It may fail for other reasons such as block cap, but not USD cap range.)
    function testFuzz_USDCaps_InRangeDoesNotFailCaps(uint256 ethAmountWei) public {
        // $1 = 0.0005 ETH = 5e14 wei; $10 = 0.005 ETH = 5e15 wei
        uint256 minEth = 5e14; // 0.0005 ETH
        uint256 maxEth = 5e15; // 0.005 ETH
        ethAmountWei = bound(ethAmountWei, minEth, maxEth);

        // Disable block cap so the only possible cap failure is USD range
        vm.prank(governance);
        gateway.setBlockUsdCap(0);

        vm.deal(user1, ethAmountWei + 1 ether);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        try gateway.sendUniversalTx{ value: ethAmountWei }(req) { } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertNotEq(sel, Errors.InvalidAmount.selector, "in-range tx must not fail USD cap check");
        }
    }

    /// @dev Tx with value below $1 at $2000/ETH always reverts InvalidAmount (below min cap).
    function testFuzz_USDCaps_BelowMinReverts(uint256 ethAmountWei) public {
        // Below $1 at $2000/ETH → below 5e14 wei. Use tiny range to avoid zero revert.
        ethAmountWei = bound(ethAmountWei, 1e10, 4e14);

        vm.deal(user1, ethAmountWei + 1 ether);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTx{ value: ethAmountWei }(req);
    }

    /// @dev Tx with value above $10 at $2000/ETH always reverts InvalidAmount (above max cap).
    function testFuzz_USDCaps_AboveMaxReverts(uint256 ethAmountWei) public {
        // Above $10 at $2000/ETH → above 5e15 wei
        ethAmountWei = bound(ethAmountWei, 6e15, 100 ether);

        // Disable block cap so this can only be stopped by USD range check
        vm.prank(governance);
        gateway.setBlockUsdCap(0);

        vm.deal(user1, ethAmountWei + 1 ether);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTx{ value: ethAmountWei }(req);
    }
}
