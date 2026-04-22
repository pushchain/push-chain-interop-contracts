// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions } from "../libraries/Types.sol";

/**
 * @title  IVault
 * @notice Interface for ERC20 custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 */
interface IVault {
    // =========================
    //        V_1: EVENTS
    // =========================

    /// @notice                  Gateway updated event
    /// @param oldGateway        Previous Gateway address
    /// @param newGateway        New Gateway address
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    /// @notice                  CEAFactory updated event
    /// @param oldCEAFactory     Previous CEAFactory address
    /// @param newCEAFactory     New CEAFactory address
    event CEAFactoryUpdated(address indexed oldCEAFactory, address indexed newCEAFactory);

    /// @notice                  Universal tx finalized event
    /// @param subTxId           Gateway transaction identifier
    /// @param universalTxId     Universal transaction identifier
    /// @param pushAccount       Push Chain account (UEA) this transaction is attributed to
    /// @param recipient         Destination address on the external chain; address(0) means park in CEA
    /// @param token             Token address being sent
    /// @param amount            Amount of token being sent
    /// @param data              Calldata to be executed on target contract on external chain
    event UniversalTxFinalized(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed pushAccount,
        address recipient,
        address token,
        uint256 amount,
        bytes data
    );

    /// @notice                  Universal tx reverted event
    /// @param subTxId           Gateway transaction identifier
    /// @param universalTxId     Universal transaction identifier
    /// @param token             Token address being reverted
    /// @param amount            Amount of token being reverted
    /// @param revertInstruction Revert instruction containing revertRecipient and revertMsg
    event UniversalTxReverted(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    /// @notice                  Funds rescued from the vault via gateway routing
    /// @param subTxId           Gateway transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier
    /// @param token             Token address rescued (address(0) for native)
    /// @param amount            Amount rescued
    /// @param revertInstruction Revert settings containing recipient and message
    event FundsRescued(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    // =========================
    //  V_2: WITHDRAW & EXECUTION
    // =========================

    /// @notice                  Unified entry point for both withdrawals and executions (TSS-only)
    /// @dev                     Routes based on payload:
    ///                          - Empty payload (data.length == 0): Withdrawal path via CEA
    ///                          - Non-empty payload: Execution path via CEA.executeUniversalTx()
    ///                          Both paths use CEA (Chain Execution Account) as intermediary.
    /// @param subTxId           Gateway transaction identifier
    /// @param universalTxId     Universal transaction identifier from Push Chain
    /// @param pushAccount       Push Chain account (UEA) this transaction is attributed to
    /// @param recipient         Destination address on the external chain; address(0) means park in CEA
    /// @param token             Token address (address(0) for native)
    /// @param amount            Amount of token/native
    /// @param data              Calldata (empty for withdrawal, non-empty for execution)
    function finalizeUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address pushAccount,
        address recipient,
        address token,
        uint256 amount,
        bytes calldata data
    ) external payable;

    /// @notice                  TSS-only unified revert path for both native and ERC20 tokens.
    /// @dev                     Routes based on token:
    ///                          - token == address(0): native revert (TSS forwards msg.value)
    ///                          - token != address(0): ERC20 revert (Vault transfers to gateway)
    /// @param subTxId           Gateway transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier
    /// @param token             Token address (address(0) for native, ERC20 address otherwise)
    /// @param amount            Amount to refund on external chain
    /// @param revertInstruction Revert instruction containing revertRecipient and revertMsg
    function revertUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable;

    /// @notice                  TSS-only rescue path for funds locked in the vault.
    /// @dev                     Routes through Gateway for replay protection and event tracking.
    ///                          Enforces token support for ERC20 (unlike direct rescue).
    /// @param subTxId           Gateway transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier
    /// @param token             Token address (address(0) for native)
    /// @param amount            Amount to rescue
    /// @param revertInstruction Revert settings containing recipient and message
    function rescueFunds(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable;
}
