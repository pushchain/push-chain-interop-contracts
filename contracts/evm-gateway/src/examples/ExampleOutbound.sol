// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUniversalGateway } from "../interfaces/IUniversalGateway.sol";
import { IUniversalGatewayPC } from "../interfaces/IUniversalGatewayPC.sol";
import { Multicall, VerificationType } from "../libraries/Types.sol";
import { UniversalTxRequest, UniversalPayload } from "../libraries/TypesUG.sol";
import { UniversalOutboundTxRequest } from "../libraries/TypesUGPC.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  ExampleOutbound
 * @notice Reference integration for triggering outbound Universal Transactions from
 *         Push Chain. Deploys on Push Chain and wires to the `UniversalGatewayPC`
 *         predeploy (`0x00000000000000000000000000000000000000C1`) automatically.
 *
 *         This contract demonstrates three patterns:
 *
 *             (1) sendOutbound              — plain outbound: Push -> external chain.
 *                                             Can bridge funds, execute payloads, or both.
 *
 *             (2) sendRoundtrip             — outbound whose multicall payload, once
 *                                             executed by the destination CEA, triggers
 *                                             an inbound back to Push Chain.
 *
 *             (3) sendMultiHopRoundtrip     — chain N roundtrips: Push -> A -> Push
 *                                             -> B -> Push -> ..., each hop's return
 *                                             leg carrying the remaining itinerary.
 *
 *         FEE MODEL
 *         ---------
 *         Every outbound pays:
 *           - `protocolFee`   (native PC, forwarded to VaultPC)
 *           - `gasFee`        (native PC, swapped to the destination gas PRC20 via
 *                              UniversalCore; swap is exactOutput for `gasFee`)
 *         Callers quote both via
 *
 *             (gasToken, gasFee, protocolFee, gasPrice, ns) =
 *                 UniversalCore(outbound.UGPC().UNIVERSAL_CORE())
 *                     .getOutboundTxGasAndFees(token, gasLimit);
 *
 *         `msg.value` must cover `protocolFee + gasFee`. Any surplus is refunded by
 *         UniversalCore to `msg.sender` (this contract); use `sweepNative` to recover
 *         dust. `gasLimit` must be >= `UniversalCore.BASE_GAS_LIMIT` (otherwise
 *         UniversalCore reverts with `GasLimitBelowBase`).
 *
 *         PRC20 ALLOWANCES
 *         ----------------
 *         For any call with `amount > 0`, the caller must first `approve(this, amount)`
 *         on the PRC20 — this contract pulls tokens in, then re-approves UGPC.
 *
 *         IDENTITY MODEL (important for roundtrip / multi-hop)
 *         ----------------------------------------------------
 *         UGPC emits the outbound with `Sender = msg.sender` (= this contract). Push
 *         Chain's outbound pipeline (`create_outbound.go:75`) propagates that as
 *         `OutboundTx.Sender`, and the Vault derives the destination-chain CEA from it:
 *
 *             destinationCEA = CEAFactory.getCEAForPushAccount(address(this))
 *
 *         So the destination CEA is permanently mapped to THIS contract. On the return
 *         leg, `sendUniversalTxFromCEA`'s anti-spoof enforces
 *         `req.recipient == CEAFactory.getPushAccountForCEA(CEA) == address(this)` —
 *         meaning every return-inbound credits THIS contract's Push-side UEA, not the
 *         EOA that originally kicked off the flow. For per-user accounting, keep a
 *         `(user => nonce)` map and post-process the inbound events.
 */
contract ExampleOutbound {
    using SafeERC20 for IERC20;

    /// @notice Production CEAs (push-chain-core-contracts) require this 4-byte prefix at
    ///         the start of a multicall payload. Without it, the CEA routes the payload
    ///         into its single-call path and the multicall never executes.
    ///         Source: `push-chain-core-contracts/src/libraries/Types.sol:57`.
    bytes4 public constant MULTICALL_SELECTOR = bytes4(keccak256("UEA_MULTICALL"));

    /// @notice Well-known predeploy address of `UniversalGatewayPC` on Push Chain.
    ///         Same across all Push Chain networks.
    IUniversalGatewayPC public immutable UGPC = IUniversalGatewayPC(0x00000000000000000000000000000000000000C1);

    error ZeroAddress();
    error CEAUnderfunded();
    error NativeTransferFailed();

    // ============================================================
    //   (1) PLAIN OUTBOUND — Push -> external chain
    // ============================================================

    /// @notice Send a plain outbound tx. UGPC infers TX_TYPE from `amount` and `payload`:
    ///             FUNDS              — amount > 0, payload.length == 0
    ///             FUNDS_AND_PAYLOAD  — amount > 0, payload.length >  0
    ///             GAS_AND_PAYLOAD    — amount == 0, payload.length > 0
    ///             (amount == 0 && payload.length == 0 is rejected by UGPC.)
    ///
    /// @dev    Quick start (native bridge from Push to an EVM address on Sepolia):
    ///
    ///             pETH.approve(outbound, 0.1 ether);
    ///             outbound.sendOutbound{ value: quotedMsgValue }(
    ///                 pETH,                              // PRC20 token
    ///                 0.1 ether,                         // bridge amount (burned on Push)
    ///                 abi.encodePacked(aliceOnSepolia),  // 20-byte EVM address
    ///                 bytes(""),                         // no payload -> FUNDS
    ///                 0,                                 // UGPC uses BASE_GAS_LIMIT
    ///                 revertRcp
    ///             );
    ///
    ///         Multicall payload (destination-chain execution via the caller's CEA):
    ///
    ///             Multicall[] memory calls = ...;
    ///             bytes memory p = outbound.encodeMulticallPayload(calls);  // prepends selector
    ///             outbound.sendOutbound{ value: msgValue }(
    ///                 token, amount, bytes(""), p, gasLimit, revertRcp
    ///             );
    ///
    ///         `recipient = bytes("")` parks funds in THIS contract's CEA on the
    ///         destination chain (useful when the payload itself dispatches the funds).
    /// @param token            PRC20 on Push Chain. Non-zero.
    /// @param amount           Burn/bridge amount on Push. 0 for payload-only.
    /// @param recipient        Raw destination bytes (EVM: 20-byte packed address; SVM: pubkey bytes;
    ///                         empty: park in caller's CEA).
    /// @param payload          Raw bytes delivered to the destination CEA. For multicall, prepend
    ///                         `MULTICALL_SELECTOR` via `encodeMulticallPayload`.
    /// @param gasLimit         Destination-chain gas limit. Must be >= `BASE_GAS_LIMIT`; 0 is treated
    ///                         as a request and will revert inside UniversalCore's quote — prefer
    ///                         passing `BASE_GAS_LIMIT` or higher explicitly.
    /// @param revertRecipient  Push-side address credited if the outbound cannot be finalized.
    function sendOutbound(
        address token,
        uint256 amount,
        bytes calldata recipient,
        bytes calldata payload,
        uint256 gasLimit,
        address revertRecipient
    ) external payable {
        if (token == address(0)) revert ZeroAddress();
        if (revertRecipient == address(0)) revert ZeroAddress();

        if (amount > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).forceApprove(address(UGPC), amount);
        }

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: recipient,
            token: token,
            amount: amount,
            gasLimit: gasLimit,
            payload: payload,
            revertRecipient: revertRecipient
        });

        UGPC.sendUniversalTxOutbound{ value: msg.value }(req);
    }

    // ============================================================
    //   (2) ROUNDTRIP — Push -> external -> Push
    // ============================================================

    /// @notice Parameters describing the return inbound leg (external chain -> Push).
    /// @param externalGateway       `UniversalGateway` address on the destination chain.
    /// @param returnToken           Token for the return bridge — `address(0)` for native,
    ///                              else an ERC20 address on the destination chain.
    /// @param returnAmount          Return-leg bridge amount (0 allowed → payload-only return).
    /// @param returnPayload         Optional ABI-encoded `UniversalPayload` executed by THIS
    ///                              contract's UEA on Push Chain on arrival.
    /// @param returnRevertRecipient Destination-chain address refunded if the return leg fails.
    /// @param inboundFee            Destination gateway's `INBOUND_FEE` (wei). Quote via
    ///                              `UniversalGateway(externalGateway).INBOUND_FEE()` off-chain.
    /// @param nativeValueForCall    Native forwarded with the return-leg gateway call. MUST
    ///                              cover `inboundFee + (returnAmount if returnToken == 0)`.
    struct ReturnLeg {
        address externalGateway;
        address returnToken;
        uint256 returnAmount;
        bytes   returnPayload;
        address returnRevertRecipient;
        uint256 inboundFee;
        uint256 nativeValueForCall;
    }

    /// @notice Send an outbound whose destination-chain execution immediately triggers
    ///         an inbound back to Push Chain.
    /// @dev    Flow:
    ///             1. Burn `outboundAmount` of `outboundToken` on Push.
    ///             2. TSS unlocks `outboundAmount` of native on the destination chain into
    ///                THIS contract's CEA (via `Vault.finalizeUniversalTx`).
    ///             3. CEA runs a single-step multicall: `sendUniversalTxFromCEA{value:
    ///                nativeValueForCall}(inboundReq)` on the destination gateway.
    ///             4. Destination gateway emits `UniversalTx(fromCEA=true, recipient=this)`.
    ///             5. Push Chain honors `recipient` under `isCEA=true` and lands funds +
    ///                payload back on THIS contract's UEA.
    ///
    /// @dev    Invariants (enforced / relied on):
    ///           - `outboundAmount >= nativeValueForCall` (CEA needs native balance on
    ///             destination to pay the return-leg gateway `value`).
    ///           - `outboundToken` MUST be the PRC20 whose destination-chain counterpart is
    ///             NATIVE (e.g. pETH for Ethereum, pBNB for BSC). If it corresponds to an
    ///             ERC20 on the destination, the Vault transfers ERC20 (not native) to the
    ///             CEA and the return-leg `value` will fail. Workaround: pre-fund the CEA
    ///             with native via a prior outbound.
    ///           - Inbound leg's `recipient = address(this)` — only value accepted by
    ///             `sendUniversalTxFromCEA`'s anti-spoof check.
    ///           - Outbound's payload is built as `MULTICALL_SELECTOR || abi.encode(calls)`
    ///             so the production CEA dispatches it to its multicall path.
    /// @param outboundToken           PRC20 to burn on Push (must map to destination native — see above).
    /// @param outboundAmount          Amount to burn on Push. `>= nativeValueForCall`.
    /// @param destinationCEA          Destination-chain recipient bytes. Empty bytes means
    ///                                "park in caller's CEA" — the usual choice since the
    ///                                multicall dispatches the funds itself.
    /// @param outboundGasLimit        Destination-chain gas limit. Must be >= `BASE_GAS_LIMIT`.
    /// @param outboundRevertRecipient Push-side address refunded if the outbound cannot be finalized.
    /// @param ret                     See `ReturnLeg` for the return-inbound parameters.
    function sendRoundtrip(
        address outboundToken,
        uint256 outboundAmount,
        bytes calldata destinationCEA,
        uint256 outboundGasLimit,
        address outboundRevertRecipient,
        ReturnLeg calldata ret
    ) external payable {
        if (outboundToken == address(0)) revert ZeroAddress();
        if (outboundRevertRecipient == address(0)) revert ZeroAddress();
        if (ret.externalGateway == address(0)) revert ZeroAddress();
        if (ret.returnRevertRecipient == address(0)) revert ZeroAddress();
        // Note: `destinationCEA = bytes("")` is valid and means "park funds in this
        // contract's CEA on the destination chain" (per UGPC semantics). We do NOT
        // reject empty bytes here.

        // The CEA needs enough destination-chain native to pay for the return call's `value`.
        // `value` covers the destination gateway's INBOUND_FEE plus the native bridge amount
        // (when the return leg bridges native). Callers quote this via the destination chain's
        // `UniversalGateway.INBOUND_FEE()` and the desired `returnAmount`.
        if (outboundAmount < ret.nativeValueForCall) revert CEAUnderfunded();

        // Pull the PRC20 to burn on Push.
        IERC20(outboundToken).safeTransferFrom(msg.sender, address(this), outboundAmount);
        IERC20(outboundToken).forceApprove(address(UGPC), outboundAmount);

        // Build the inbound request the CEA will submit back to Push Chain.
        // `recipient = address(this)` because the CEA's mapped UEA is this contract.
        UniversalTxRequest memory inboundReq = UniversalTxRequest({
            recipient: address(this),
            token: ret.returnToken,
            amount: ret.returnAmount,
            payload: ret.returnPayload,
            revertRecipient: ret.returnRevertRecipient,
            signatureData: bytes("")
        });

        bytes memory callData = abi.encodeCall(IUniversalGateway.sendUniversalTxFromCEA, (inboundReq));

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({
            to: ret.externalGateway,
            value: ret.nativeValueForCall,
            data: callData
        });

        // Prefix with MULTICALL_SELECTOR so the CEA routes to its multicall path
        // (see push-chain-core-contracts CEA `_isMulticall`/`_decodeCalls`).
        bytes memory multicallPayload = bytes.concat(MULTICALL_SELECTOR, abi.encode(calls));

        UniversalOutboundTxRequest memory outReq = UniversalOutboundTxRequest({
            recipient: destinationCEA,
            token: outboundToken,
            amount: outboundAmount,
            gasLimit: outboundGasLimit,
            payload: multicallPayload,
            revertRecipient: outboundRevertRecipient
        });

        UGPC.sendUniversalTxOutbound{ value: msg.value }(outReq);
    }

    // ============================================================
    //   RESCUE (passthrough) & UTILITIES
    // ============================================================

    /// @notice Ask TSS to rescue funds locked on the source chain's Vault.
    /// @dev    Thin passthrough to `UGPC.rescueFundsOnSourceChain`. Caller pays gas in
    ///         native PC via `msg.value` (no protocol fee, no PRC20 burn).
    /// @param universalTxId The universal tx id of the stuck funds.
    /// @param prc20         PRC20 whose source-chain counterpart is locked.
    function rescueOnSourceChain(bytes32 universalTxId, address prc20) external payable {
        UGPC.rescueFundsOnSourceChain{ value: msg.value }(universalTxId, prc20);
    }

    /// @notice Sweep native PC dust (e.g. UniversalCore refunds) to `to`.
    /// @dev    Demo: ungated — anyone can trigger the sweep to any `to`. For production,
    ///         gate behind `Ownable` or a role.
    function sweepNative(address payable to) external {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = to.call{ value: bal }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @notice Receive hook so UniversalCore refunds (unused PC) can land on this contract.
    receive() external payable { }

    /// @notice Prepend `MULTICALL_SELECTOR` to an ABI-encoded `Multicall[]`.
    /// @dev    Production CEAs require this 4-byte prefix to route the payload to their
    ///         multicall path. Without it the CEA falls into the single-call path and
    ///         the multicall never executes. Use this when you build payloads for
    ///         `sendOutbound` by hand.
    function encodeMulticallPayload(Multicall[] calldata calls) external pure returns (bytes memory) {
        return bytes.concat(MULTICALL_SELECTOR, abi.encode(calls));
    }
}
