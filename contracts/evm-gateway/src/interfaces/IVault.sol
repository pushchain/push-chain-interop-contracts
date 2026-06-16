// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions } from "../libraries/Types.sol";

/**
 * @title  IVault
 * @notice Interface for the external-chain token custody vault managed by TSS.
 * @dev    Handles two outbound finalization flows via a single entry point (finalizeUniversalTx):
 *         - PRC20 path: unlocks tokens the Vault already holds and routes through CEA.
 *         - PC20 path: detected when `data` starts with PC_20_SELECTOR (0x50433230). Mints
 *           wrapped ERC-20 tokens via PC20Factory instead of transferring from Vault.
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

    /// @notice                  Tokens migrated from this vault to a new vault
    /// @param newVault          Destination vault address
    /// @param tokens            Array of ERC20 token addresses migrated
    /// @param amounts           Array of amounts transferred (parallel to tokens)
    /// @param nativeAmount      Amount of native ETH transferred (0 if none)
    event TokensMigrated(
        address indexed newVault,
        address[] tokens,
        uint256[] amounts,
        uint256 nativeAmount
    );

    // =========================
    //  V_2: WITHDRAW & EXECUTION
    // =========================

    /// @notice                  Unified entry point for PRC20 withdrawals/executions and PC20 exports.
    /// @dev                     Routes based on the `data` parameter:
    ///                          - If `data` starts with PC_20_SELECTOR: PC20 export path.
    ///                            `token` is the Push Chain sourceAsset. `data` layout:
    ///                            [PC_20_SELECTOR (4 B)][abi.encode(name, symbol, decimals, userData)]
    ///                            Replay protection via isPC20Executed. msg.value must be 0.
    ///                          - Otherwise: PRC20 path. Routes through CEA for token transfer
    ///                            and/or execution. msg.value used for native token path.
    /// @param subTxId           Gateway transaction identifier
    /// @param universalTxId     Universal transaction identifier from Push Chain
    /// @param pushAccount       Push Chain account (UEA) this transaction is attributed to
    /// @param recipient         Destination address on the external chain; address(0) means park in CEA
    /// @param token             PRC20: token address (address(0) for native). PC20: sourceAsset address.
    /// @param amount            PRC20: amount to unlock/transfer. PC20: amount to mint.
    /// @param data              PRC20: Multicall calldata. PC20: PC_20_SELECTOR-prefixed metadata.
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

    // =========================
    //  V_2b: PC20 EVENTS & ADMIN
    // =========================

    /// @notice Emitted when a PC20 export is finalized (wrapped ERC-20 minted on this chain).
    event PC20ExportFinalized(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed pushAccount,
        address recipient,
        address sourceAsset,
        uint256 amount,
        bytes userData
    );

    event PC20FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    function updatePC20Factory(address newFactory) external;

    // =========================
    //    V_3: MIGRATION
    // =========================

    /// @notice Migrates ERC20 balances and any native ETH to a new vault.
    /// @dev    MUST be called while BOTH this vault AND the gateway are paused.
    /// @param newVault Destination vault address
    /// @param tokens   Caller-supplied list of ERC20 token addresses to sweep
    function migrateTokens(address newVault, address[] calldata tokens) external;
}
