// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { TX_TYPE } from "../libraries/Types.sol";
import { UniversalOutboundTxRequest } from "../libraries/TypesUGPC.sol";

/**
 * @title  IUniversalGatewayPC
 * @notice Interface for UniversalGatewayPC contract
 * @dev    Defines all public functions and events for the Push Chain outbound gateway
 */
interface IUniversalGatewayPC {
    // ==============================
    //      UGPC_1: EVENTS
    // ==============================

    /// @notice                  Single event covering both flows (funds-only and funds+payload).
    /// @param subTxId           Unique sub-transaction identifier
    /// @param sender            EVM sender on Push Chain (burn initiator)
    /// @param chainNamespace    Origin chain namespace string, fetched from PRC20
    /// @param token             PRC20 token address being withdrawn (represents origin ERC20/native)
    /// @param recipient         Raw destination address on the source chain (bytes for SVM compat);
    ///                          bytes("") means park funds in the caller's CEA
    /// @param amount            Amount burned on Push Chain
    /// @param gasToken          PRC20 gas coin used to pay cross-chain execution fees
    /// @param gasFee            Amount of gasToken charged on external chain
    /// @param gasLimit          Gas limit used for fee quote on external chain
    /// @param payload           Optional payload for arbitrary call on origin chain (empty for funds-only)
    /// @param protocolFee       Flat protocol fee portion (as defined by PRC20)
    /// @param revertRecipient   Address to receive funds in case of revert
    /// @param txType            Inferred transaction type
    /// @param gasPrice          Gas price on the external chain (wei per gas unit)
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

    // ==============================
    //    UGPC_2: OUTBOUND TX
    // ==============================

    /// @notice                  Send a universal outbound transaction from Push Chain to origin chain.
    /// @dev                     Unified function for all outbound transaction types
    ///                          (FUNDS, FUNDS_AND_PAYLOAD, GAS_AND_PAYLOAD).
    ///                          TX_TYPE is automatically inferred based on the presence of payload and amount.
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
    function UNIVERSAL_CORE() external view returns (address);
}
