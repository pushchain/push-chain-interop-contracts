// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { TX_TYPE } from "../libraries/Types.sol";
import { UniversalOutboundTxRequest } from "../libraries/TypesUGPC.sol";

/**
 * @title  IUniversalGatewayPC
 * @notice Interface for the Push Chain outbound gateway.
 * @dev    Covers both PRC20 outbound (burn-and-unlock) and PC20 export (lock-and-wrap) flows
 *         through a single sendUniversalTxOutbound entry point. PC20 exports are identified by
 *         a PC_20_SELECTOR prefix in the request payload (see TypesUGPC.sol).
 */
interface IUniversalGatewayPC {
    // ==============================
    //      UGPC_1: EVENTS
    // ==============================

    /// @notice                  Emitted for every outbound transaction — PRC20 and PC20 alike.
    /// @param subTxId           Unique sub-transaction identifier.
    /// @param sender            EVM sender on Push Chain.
    /// @param chainNamespace    Target chain (CAIP-2). For PRC20: resolved from the token contract.
    ///                          For PC20: decoded from the payload's destChainNamespace field.
    /// @param token             PRC20 or PC20 token address on Push Chain.
    /// @param recipient         Raw destination address on the target chain (bytes for SVM compat);
    ///                          bytes("") means park funds in the caller's CEA.
    /// @param amount            Amount burned (PRC20) or locked (PC20) on Push Chain.
    /// @param gasToken          PRC20 gas coin used to pay cross-chain execution fees.
    /// @param gasFee            Amount of gasToken charged on the external chain.
    /// @param gasLimit          Gas limit used for fee quote on the external chain.
    /// @param payload           Calldata or PC20-encoded payload (starts with PC_20_SELECTOR for PC20).
    /// @param protocolFee       Flat protocol fee in native PC (from UniversalCore).
    /// @param revertRecipient   Address to receive funds in case of revert.
    /// @param txType            Inferred transaction type. PC20 always emits FUNDS_AND_PAYLOAD.
    /// @param gasPrice          Gas price on the external chain (wei per gas unit).
    event UniversalTxOutbound(
        bytes32 indexed subTxId,
        address indexed sender,
        string  chainNamespace,
        address indexed token,
        bytes   recipient,
        uint256 amount,
        address gasToken,
        uint256 gasFee,
        uint256 gasLimit,
        bytes   payload,
        uint256 protocolFee,
        address revertRecipient,
        TX_TYPE txType,
        uint256 gasPrice
    );

    /// @notice                  Emitted when VaultPC address is updated
    /// @param oldVaultPC        Previous VaultPC address
    /// @param newVaultPC        New VaultPC address
    event VaultPCUpdated(address indexed oldVaultPC, address indexed newVaultPC);

    /// @notice                       Emitted when UniversalCore address is updated
    /// @param oldUniversalCore       Previous UniversalCore address
    /// @param newUniversalCore       New UniversalCore address
    event UniversalCoreUpdated(address indexed oldUniversalCore, address indexed newUniversalCore);

    /// @notice                  Emitted when a user initiates a rescue-funds request on Push Chain.
    /// @param universalTxId     Universal transaction identifier of the stuck funds
    /// @param prc20             PRC20 token whose source-chain counterpart is locked
    /// @param chainNamespace    Source chain namespace
    /// @param sender            User who initiated the rescue on Push Chain
    /// @param txType            Always TX_TYPE.RESCUE_FUNDS
    /// @param gasFee            Gas fee charged (in gas-token units)
    /// @param gasPrice          Gas price on the external chain
    /// @param gasLimit          Gas limit used for fee calculation
    event RescueFundsOnSourceChain(
        bytes32 indexed universalTxId,
        address indexed prc20,
        string  chainNamespace,
        address indexed sender,
        TX_TYPE txType,
        uint256 gasFee,
        uint256 gasPrice,
        uint256 gasLimit
    );

    /// @notice                  Emitted when VaultPC20 address is updated
    event VaultPC20Updated(
        address indexed oldVaultPC20,
        address indexed newVaultPC20
    );

    /// @notice                  Emitted when outbound epoch duration is updated
    event OutboundEpochDurationUpdated(
        uint256 oldDuration,
        uint256 newDuration
    );

    /// @notice                  Emitted when outbound rate limit bps is set for a token
    event OutboundLimitBpsUpdated(
        address indexed token,
        uint256 bps
    );

    // ==============================
    //    UGPC_2: OUTBOUND TX
    // ==============================

    /// @notice                  Send a universal outbound transaction from Push Chain to an external chain.
    /// @dev                     Unified entry point for PRC20 outbound and PC20 export flows.
    ///                          - **PRC20 path**: TX_TYPE inferred from amount/payload. gasPrice override
    ///                            supported. Tokens are burned via _burnPRC20.
    ///                          - **PC20 path**: Detected when payload starts with PC_20_SELECTOR
    ///                            (see TypesUGPC.sol). Tokens are locked in VaultPC20; TX_TYPE is always
    ///                            FUNDS_AND_PAYLOAD. gasPrice override is not supported.
    ///                          When req.maxPCForGas > 0, the gateway caps native PC forwarded to the gas
    ///                          swap at that amount and refunds any excess to msg.sender before the swap.
    /// @param req               UniversalOutboundTxRequest struct containing all transaction parameters.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable;

    /// @notice                  Initiate a rescue-funds request on Push Chain. TSS will release
    ///                          the locked funds on the source chain's Vault.
    /// @param universalTxId     Universal transaction identifier of the stuck funds
    /// @param prc20             PRC20 token whose source-chain counterpart is locked
    function rescueFundsOnSourceChain(bytes32 universalTxId, address prc20) external payable;

    // ==============================
    //    UGPC_3: VIEW FUNCTIONS
    // ==============================

    /// @notice                  Returns the UniversalCore contract address.
    /// @return                  Address of the UniversalCore contract.
    function universalCore() external view returns (address);

    // ==============================
    //    UGPC_4: PC20 ADMIN
    // ==============================

    /// @notice                  Update the VaultPC20 contract address used for PC20 token custody.
    /// @param _vaultPC20        New VaultPC20 address.
    function updateVaultPC20(address _vaultPC20) external;

    // ==============================
    //  UGPC_5: OUTBOUND RATE LIMIT
    // ==============================

    /// @notice                  Set the epoch duration for outbound rate limiting.
    /// @param newDurationSec    New epoch duration in seconds (0 = disabled).
    function updateOutboundEpochDuration(
        uint256 newDurationSec
    ) external;

    /// @notice                  Set the outbound rate limit for a token in basis points
    ///                          of totalSupply per epoch.
    /// @param token             Token address.
    /// @param bps               Basis points (0 = no limit, max 10_000 = 100%).
    function updateOutboundLimitBps(
        address token,
        uint256 bps
    ) external;

    /// @notice                  Returns the current epoch usage for a token.
    /// @param token             Token address.
    /// @return epoch            Current epoch index.
    /// @return used             Amount consumed in the current epoch.
    function getOutboundEpochUsage(
        address token
    ) external view returns (uint64 epoch, uint192 used);

    /// @notice                  Returns the outbound epoch duration in seconds.
    function outboundEpochDurationSec() external view returns (uint256);

    /// @notice                  Returns the outbound rate limit bps for a token.
    function outboundLimitBps(address token) external view returns (uint256);
}
