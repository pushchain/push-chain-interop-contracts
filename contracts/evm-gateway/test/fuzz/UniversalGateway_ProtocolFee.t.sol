// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { UniversalTxRequest } from "../../src/libraries/TypesUG.sol";

/// @notice Fuzz tests for protocol fee (inboundFee) extraction and accumulation in UniversalGateway.
contract UniversalGateway_ProtocolFeeFuzz is BaseTest {
    // GAS tx: non-empty payload, no funds, native value in [$1, $10] at $2000/ETH.
    // $1 = 5e14 wei; $10 = 5e15 wei. Use 3e15 ($6) as a safe mid-range value.
    uint256 constant GAS_AMOUNT = 3e15;

    // =========================================================
    //   FG-3: PROTOCOL FEE ACCUMULATION INVARIANT
    // =========================================================

    /// @dev totalProtocolFeesCollected increments exactly by inboundFee per accepted tx.
    function testFuzz_ProtocolFee_AccumulatesCorrectly(uint64 feeWei, uint8 txCount) public {
        feeWei  = uint64(bound(feeWei,  0, 0.01 ether));
        txCount = uint8(bound(txCount, 1, 10));

        vm.prank(admin);
        gateway.setProtocolFee(uint256(feeWei));

        uint256 before = gateway.totalProtocolFeesCollected();

        for (uint8 i = 0; i < txCount; i++) {
            uint256 totalSend = GAS_AMOUNT + uint256(feeWei);
            vm.deal(user1, totalSend + 1);
            UniversalTxRequest memory req = _buildGasTxRequest();
            vm.prank(user1);
            gateway.sendUniversalTx{ value: totalSend }(req);
        }

        uint256 afterCollected = gateway.totalProtocolFeesCollected();
        assertEq(
            afterCollected - before,
            uint256(feeWei) * uint256(txCount),
            "accumulated fees must equal feeWei * txCount"
        );
    }

    /// @dev Any msg.value strictly below inboundFee must revert InsufficientProtocolFee.
    function testFuzz_ProtocolFee_InsufficientValueReverts(uint64 feeWei, uint64 sentWei) public {
        feeWei  = uint64(bound(feeWei,  1, 0.05 ether));
        sentWei = uint64(bound(sentWei, 0, uint256(feeWei) - 1));

        vm.prank(admin);
        gateway.setProtocolFee(uint256(feeWei));

        vm.deal(user1, uint256(sentWei) + 1);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        gateway.sendUniversalTx{ value: sentWei }(req);
    }

    /// @dev When fee is 0, totalProtocolFeesCollected never increases regardless of tx count.
    function testFuzz_ProtocolFee_ZeroFee_AccumulatorUnchanged(uint8 txCount) public {
        txCount = uint8(bound(txCount, 1, 10));

        vm.prank(admin);
        gateway.setProtocolFee(0);

        uint256 before = gateway.totalProtocolFeesCollected();

        for (uint8 i = 0; i < txCount; i++) {
            vm.deal(user1, GAS_AMOUNT + 1);
            UniversalTxRequest memory req = _buildGasTxRequest();
            vm.prank(user1);
            gateway.sendUniversalTx{ value: GAS_AMOUNT }(req);
        }

        assertEq(
            gateway.totalProtocolFeesCollected(),
            before,
            "accumulator must not change when fee is zero"
        );
    }

    /// @dev Fee is correctly deducted before routing: post-fee native value hits USD cap check.
    ///      If the fee is so large that msg.value - fee < min cap threshold, tx reverts InvalidAmount.
    function testFuzz_ProtocolFee_FeeDeductedBeforeCapCheck(uint64 feeWei) public {
        // Fee larger than the entire send → post-fee value is 0 → GAS_AND_PAYLOAD with 0 native is fine.
        // Fee smaller than send: post-fee value must still satisfy USD caps.
        feeWei = uint64(bound(feeWei, 0, GAS_AMOUNT));

        vm.prank(admin);
        gateway.setProtocolFee(uint256(feeWei));

        // Disable block cap so fee is the only variable
        vm.prank(governance);
        gateway.setBlockUsdCap(0);

        uint256 totalSend = GAS_AMOUNT + uint256(feeWei);
        vm.deal(user1, totalSend + 1);
        UniversalTxRequest memory req = _buildGasTxRequest();
        vm.prank(user1);
        // Should succeed: post-fee value = GAS_AMOUNT = $6 which is in [$1, $10]
        gateway.sendUniversalTx{ value: totalSend }(req);

        assertEq(
            gateway.totalProtocolFeesCollected(),
            uint256(feeWei),
            "single tx must collect exactly feeWei"
        );
    }
}
