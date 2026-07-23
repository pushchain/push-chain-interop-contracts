// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { RevertInstructions, VerificationType } from "../../src/libraries/Types.sol";
import { UniversalTxRequest, UniversalPayload } from "../../src/libraries/TypesUG.sol";

/// @notice Fuzz tests for TX_TYPE inference and replay protection in UniversalGateway.
contract UniversalGateway_TxRoutingFuzz is BaseTest {
    // =========================================================
    //   FG-4: TX_TYPE INFERENCE — BOOLEAN COMBINATIONS
    // =========================================================

    /// @dev No payload + no funds + no native value → always reverts InvalidInput.
    function testFuzz_FetchTxType_NoPayload_NoFunds_NoValue_Reverts(bytes32 salt) public {
        // salt unused — just ensures forge generates a unique test run per input
        (salt);
        vm.deal(user1, 1 ether);
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTx{ value: 0 }(req);
    }

    /// @dev Non-empty payload + zero amount + any native value → GAS_AND_PAYLOAD (never InvalidInput).
    function testFuzz_FetchTxType_PayloadOnly_NeverInvalidInput(uint8 payloadLen, uint96 nativeValue) public {
        payloadLen = uint8(bound(payloadLen, 1, 200));
        nativeValue = uint96(bound(nativeValue, 0, 5 ether));

        bytes memory payload = abi.encode(
            UniversalPayload({
                to: address(0x123),
                value: 0,
                data: new bytes(payloadLen),
                gasLimit: 100_000,
                maxFeePerGas: 0,
                maxPriorityFeePerGas: 0,
                nonce: 0,
                deadline: 0,
                vType: VerificationType.signedVerification
            })
        );

        vm.deal(user1, uint256(nativeValue) + 1 ether);
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        try gateway.sendUniversalTx{ value: nativeValue }(req) { }
        catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertNotEq(sel, Errors.InvalidInput.selector, "payload-only must not revert InvalidInput");
        }
    }

    /// @dev Native FUNDS: msg.value == amount must not be rejected as InvalidInput.
    function testFuzz_FetchTxType_NativeFunds_ValidAmountNotInvalidInput(uint96 amount) public {
        amount = uint96(bound(amount, 1, 5 ether));

        vm.deal(user1, uint256(amount) + 1 ether);
        UniversalTxRequest memory req = _buildFundsTxRequest(address(0), amount, address(0x456));
        vm.prank(user1);
        try gateway.sendUniversalTx{ value: amount }(req) { }
        catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertNotEq(sel, Errors.InvalidInput.selector, "native funds with matching value must not be InvalidInput");
        }
    }

    /// @dev Native FUNDS: msg.value < amount always reverts with InvalidInput or InvalidAmount.
    ///      When sentValue == 0: _fetchTxType sees hasNativeValue=false for a native FUNDS tx → InvalidInput.
    ///      When sentValue > 0 but < amount: _sendTxWithFunds validates amount == nativeValue → InvalidAmount.
    function testFuzz_FetchTxType_NativeFunds_ValueLessThanAmount_Reverts(uint96 amount, uint96 shortfall) public {
        amount = uint96(bound(amount, 1, 5 ether));
        shortfall = uint96(bound(shortfall, 1, amount));
        uint256 sentValue = uint256(amount) - uint256(shortfall);

        vm.deal(user1, uint256(amount) + 1 ether);
        UniversalTxRequest memory req = _buildFundsTxRequest(address(0), amount, address(0x456));
        vm.prank(user1);
        try gateway.sendUniversalTx{ value: sentValue }(req) {
            revert("expected revert but call succeeded");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == Errors.InvalidInput.selector || sel == Errors.InvalidAmount.selector,
                "must revert InvalidInput or InvalidAmount"
            );
        }
    }

    /// @dev Native GAS: pure gas top-up (no payload, no amount) with value > 0 succeeds type-check.
    ///      Any revert must not be InvalidInput.
    function testFuzz_FetchTxType_GasOnly_NotInvalidInput(uint96 nativeValue) public {
        nativeValue = uint96(bound(nativeValue, 1, 10 ether));

        vm.deal(user1, uint256(nativeValue) + 1 ether);
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        try gateway.sendUniversalTx{ value: nativeValue }(req) { }
        catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertNotEq(sel, Errors.InvalidInput.selector, "gas-only tx must not revert InvalidInput");
        }
    }

    // =========================================================
    //   FG-5: REPLAY PROTECTION (isExecuted)
    // =========================================================

    // gateway.revertUniversalTx has onlyRole(VAULT_ROLE).
    // BaseTest._deployGateway sets vault = address(this), so the test contract has VAULT_ROLE.
    // We fund address(this) and send the native value with each call so the gateway can forward it.

    /// @dev Any subTxId used once for revertUniversalTx cannot be reused.
    function testFuzz_ReplayProtection_DoubleRevert_Reverts(bytes32 subTxId) public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount * 3);

        // Use makeAddr to get an EOA that can receive ETH (avoids precompile addresses like 0x9)
        RevertInstructions memory cfg =
            RevertInstructions({ revertRecipient: makeAddr("revertRecipient"), revertMsg: bytes("") });

        // First call: marks isExecuted[subTxId] = true
        gateway.revertUniversalTx{ value: amount }(subTxId, bytes32(0), address(0), amount, cfg);

        // Second call with same subTxId must revert PayloadExecuted
        vm.expectRevert(Errors.PayloadExecuted.selector);
        gateway.revertUniversalTx{ value: amount }(subTxId, bytes32(0), address(0), amount, cfg);
    }

    /// @dev A subTxId used for revertUniversalTx cannot subsequently be used for rescueFunds.
    function testFuzz_ReplayProtection_RevertThenRescue_Reverts(bytes32 subTxId) public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount * 3);

        RevertInstructions memory cfg =
            RevertInstructions({ revertRecipient: makeAddr("revertRecipient"), revertMsg: bytes("") });

        // First: revert marks isExecuted[subTxId] = true
        gateway.revertUniversalTx{ value: amount }(subTxId, bytes32(0), address(0), amount, cfg);

        // Rescue with same subTxId must fail
        vm.expectRevert(Errors.PayloadExecuted.selector);
        gateway.rescueFunds{ value: amount }(subTxId, bytes32(0), address(0), amount, cfg);
    }

    /// @dev Distinct subTxIds are independent — first revert does not block second.
    function testFuzz_ReplayProtection_DistinctSubTxIds_IndependentlySucceed(bytes32 subTxId1, bytes32 subTxId2)
        public
    {
        vm.assume(subTxId1 != subTxId2);

        uint256 amount = 1 ether;
        vm.deal(address(this), amount * 3);

        RevertInstructions memory cfg =
            RevertInstructions({ revertRecipient: makeAddr("revertRecipient"), revertMsg: bytes("") });

        gateway.revertUniversalTx{ value: amount }(subTxId1, bytes32(0), address(0), amount, cfg);

        // Different subTxId must succeed independently
        gateway.revertUniversalTx{ value: amount }(subTxId2, bytes32(0), address(0), amount, cfg);
    }
}
