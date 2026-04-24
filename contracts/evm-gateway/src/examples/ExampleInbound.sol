// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUniversalGateway } from "../interfaces/IUniversalGateway.sol";
import { UniversalTxRequest } from "../libraries/TypesUG.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  ExampleInbound
 * @notice Reference integration showing how a contract on an external EVM chain triggers
 *         inbound Universal Transactions into Push Chain via `UniversalGateway`. Deploy
 *         this on any supported external chain (Sepolia, Base, Arbitrum, BSC, ...).
 *
 *         QUICK START
 *         -----------
 *         Native deposit to a specific Push Chain address (FUNDS, no payload):
 *
 *             uint256 fee   = inbound.inboundFee();
 *             uint256 total = fee + 0.1 ether;
 *             inbound.sendFundsNative{ value: total }(pushRecipient, 0.1 ether, revertRcp);
 *
 *         ERC20 deposit (caller must `approve(inbound, amount)` first):
 *
 *             inbound.sendFundsToken{ value: inbound.inboundFee() }(
 *                 usdc, 100e6, pushRecipient, revertRcp
 *             );
 *
 *         FUNCTIONS AT A GLANCE
 *         ---------------------
 *         | Function                    | TX_TYPE              | Destination on Push     |
 *         |-----------------------------|----------------------|-------------------------|
 *         | sendFundsNative             | FUNDS (native)       | caller-chosen recipient |
 *         | sendFundsToken              | FUNDS (ERC20)        | caller-chosen recipient |
 *         | sendGas                     | GAS                  | this contract's UEA     |
 *         | sendGasAndPayload           | GAS_AND_PAYLOAD      | this contract's UEA     |
 *         | sendFundsAndPayloadNative   | FUNDS_AND_PAYLOAD    | this contract's UEA     |
 *         | sendFundsAndPayloadToken    | FUNDS_AND_PAYLOAD    | this contract's UEA     |
 *
 *         Rule of thumb: if the function takes a `recipient` argument, Push Chain honors
 *         it as the destination. Otherwise the result always credits THIS contract's UEA
 *         (the "integrator pattern"). That's because Push Chain only honors `req.recipient`
 *         from non-CEA callers for pure `TX_TYPE.FUNDS`; every other TX_TYPE routes to
 *         `msg.sender`'s UEA, which from a wrapper contract means the wrapper itself.
 *
 *         FEE / msg.value CHEAT SHEET
 *         ---------------------------
 *         Every inbound call pays a flat `INBOUND_FEE` (native, in wei) to the gateway.
 *         Read it from `GATEWAY.INBOUND_FEE()` or the `inboundFee()` helper below.
 *
 *             sendFundsNative             →  msg.value = INBOUND_FEE + amount
 *             sendFundsToken              →  msg.value = INBOUND_FEE                 (exact)
 *             sendGas                     →  msg.value = INBOUND_FEE + topUp
 *             sendGasAndPayload           →  msg.value = INBOUND_FEE + extraGas
 *             sendFundsAndPayloadNative   →  msg.value = INBOUND_FEE + amount
 *             sendFundsAndPayloadToken    →  msg.value = INBOUND_FEE                 (exact)
 */
contract ExampleInbound {
    using SafeERC20 for IERC20;

    IUniversalGateway public immutable GATEWAY;

    error ZeroAddress();
    error InvalidAmount();
    error EmptyPayload();

    constructor(address gateway) {
        if (gateway == address(0)) revert ZeroAddress();
        GATEWAY = IUniversalGateway(gateway);
    }

    // ============================================================
    //   GROUP A — FUNDS: deliver to an arbitrary Push address
    // ============================================================

    /// @notice Bridge native funds to a specific Push Chain address. No payload.
    /// @dev    Use when: you want to send native (ETH/BNB/etc.) from this chain and
    ///         have it arrive as the matching PRC20 on a Push Chain address you choose.
    ///         Push Chain treats `recipient` as a raw EVM address and `depositPRC20`
    ///         goes straight there — no UEA derivation, no payload execution.
    ///
    ///         Requirements: `msg.value == INBOUND_FEE + amount`.
    /// @param recipient       Push Chain destination. Any EVM address — a UEA
    ///                        (derivable off-chain via `FactoryV1.getUEAForOrigin`) or a
    ///                        plain account. MUST be non-zero.
    /// @param amount          Native amount to bridge (in wei). MUST be > 0.
    /// @param revertRecipient Where funds are returned on the source chain if the
    ///                        Push-side deposit fails. MUST be non-zero.
    function sendFundsNative(
        address recipient,
        uint256 amount,
        address revertRecipient
    ) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        if (revertRecipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: recipient,
            token: address(0),
            amount: amount,
            payload: bytes(""),
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    /// @notice Bridge a supported ERC20 to a specific Push Chain address. No payload.
    /// @dev    Use when: you want to send an ERC20 (USDC, USDT, ...) from this chain
    ///         to a Push Chain address you choose.
    ///
    ///         Requirements:
    ///           - Caller has approved this contract for `amount` of `token` beforehand.
    ///           - `msg.value == INBOUND_FEE` exactly (no surplus, no deficit).
    ///
    ///         Why strict msg.value? Any surplus native would be routed by the gateway
    ///         as a separate gas leg to `recipient = address(0)`, which Push Chain maps
    ///         to the sender's (this wrapper's) UEA — not the end user's. Users who
    ///         want to top up their own UEA should call `sendGas` from their own EOA.
    /// @param token           Source-chain ERC20. MUST be supported on the gateway and non-zero.
    /// @param amount          Amount to bridge (natural units). MUST be > 0.
    /// @param recipient       Push Chain destination (EVM address). MUST be non-zero.
    /// @param revertRecipient Where tokens are returned on the source chain on Push-side
    ///                        failure. MUST be non-zero.
    function sendFundsToken(
        address token,
        uint256 amount,
        address recipient,
        address revertRecipient
    ) external payable {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (revertRecipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (msg.value != GATEWAY.INBOUND_FEE()) revert InvalidAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(GATEWAY), amount);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: recipient,
            token: token,
            amount: amount,
            payload: bytes(""),
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    // ============================================================
    //   GROUP B — GAS / PAYLOAD: credit THIS contract's UEA
    // ============================================================
    //
    // These entrypoints don't accept a `recipient` parameter because Push Chain
    // ignores or normalizes it for these TX_TYPEs when the caller is a non-CEA
    // contract. Everything lands on the UEA mapped to THIS contract's
    // (chainNamespace, chainId, address(this)). Treat them as the "integrator
    // pattern" — the contract is acting on its own behalf on Push Chain.

    /// @notice Top up THIS contract's UEA on Push Chain with native gas.
    /// @dev    Use when: this contract needs native PC on its Push-side UEA to
    ///         run future `sendGasAndPayload` / `sendFundsAndPayload*` calls whose
    ///         UEA executions consume gas. Standalone gas deposit, no payload.
    ///
    ///         Requirements: `msg.value == INBOUND_FEE + topUp` (topUp = the amount
    ///         you want credited to the UEA as gas, in native).
    /// @param revertRecipient Where funds are returned on source chain on failure.
    function sendGas(address revertRecipient) external payable {
        if (revertRecipient == address(0)) revert ZeroAddress();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    /// @notice Execute a payload via THIS contract's UEA on Push Chain (no funds bridged).
    /// @dev    Use when: this contract wants to call another Push Chain contract (e.g.
    ///         a DEX, a vault, any PRC20-denominated action) through its UEA — no new
    ///         bridge amount required, just the arbitrary call.
    ///
    ///         `payload` is an ABI-encoded `UniversalPayload` tuple that the UEA will
    ///         execute. Any surplus native above `INBOUND_FEE` is credited as extra gas
    ///         to the same UEA (useful to top it up in the same tx).
    ///
    ///         Requirements:
    ///           - `payload.length > 0` (empty is rejected both locally and on Push).
    ///           - `msg.value >= INBOUND_FEE`. `extraGas = msg.value - INBOUND_FEE`
    ///             lands as additional native gas on the UEA.
    /// @param payload         Non-empty ABI-encoded UniversalPayload.
    /// @param revertRecipient Source-chain refund address on failure.
    function sendGasAndPayload(bytes calldata payload, address revertRecipient) external payable {
        if (revertRecipient == address(0)) revert ZeroAddress();
        if (payload.length == 0) revert EmptyPayload();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: payload,
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    /// @notice Bridge native funds AND execute a payload via THIS contract's UEA.
    /// @dev    Use when: you want to deposit native into this contract's UEA on
    ///         Push Chain AND have the UEA immediately execute a call (atomic
    ///         deposit-and-act).
    ///
    ///         Requirements:
    ///           - `amount > 0`, `payload.length > 0`.
    ///           - `msg.value == INBOUND_FEE + amount`.
    /// @param amount          Native amount to bridge (becomes PRC20 credited to UEA).
    /// @param payload         Non-empty ABI-encoded UniversalPayload.
    /// @param revertRecipient Source-chain refund address on failure.
    function sendFundsAndPayloadNative(
        uint256 amount,
        bytes calldata payload,
        address revertRecipient
    ) external payable {
        if (revertRecipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (payload.length == 0) revert EmptyPayload();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: amount,
            payload: payload,
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    /// @notice Bridge ERC20 funds AND execute a payload via THIS contract's UEA.
    /// @dev    Use when: ERC20 equivalent of `sendFundsAndPayloadNative`. Deposit
    ///         USDC/USDT/etc. into this contract's Push-side UEA AND run a call
    ///         through the UEA in one shot.
    ///
    ///         Requirements:
    ///           - Caller approved this contract for `amount` of `token`.
    ///           - `amount > 0`, `payload.length > 0`.
    ///           - `msg.value == INBOUND_FEE` exactly (no surplus — same reason as
    ///             `sendFundsToken`).
    /// @param token           Source-chain ERC20. Supported + non-zero.
    /// @param amount          Amount to bridge (natural units). > 0.
    /// @param payload         Non-empty ABI-encoded UniversalPayload.
    /// @param revertRecipient Source-chain refund address on failure.
    function sendFundsAndPayloadToken(
        address token,
        uint256 amount,
        bytes calldata payload,
        address revertRecipient
    ) external payable {
        if (token == address(0)) revert ZeroAddress();
        if (revertRecipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (payload.length == 0) revert EmptyPayload();
        if (msg.value != GATEWAY.INBOUND_FEE()) revert InvalidAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(GATEWAY), amount);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
        GATEWAY.sendUniversalTx{ value: msg.value }(req);
    }

    /// @notice Current flat `INBOUND_FEE` (native, in wei) required by the gateway.
    /// @dev    Handy when computing `msg.value` off-chain:
    ///         `total = inbound.inboundFee() + <amount or topUp>`.
    function inboundFee() external view returns (uint256) {
        return GATEWAY.INBOUND_FEE();
    }
}
