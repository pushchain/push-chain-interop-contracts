// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions, TX_TYPE } from "../../libraries/Types.sol";
import { UniversalTxRequest, UniversalTokenTxRequest } from "../../libraries/TypesUG.sol";

interface IUniversalGatewayV0 {
    // =========================
    //           EVENTS
    // =========================

    /// @notice                      Caps updated event
    /// @param minCapUsd             Minimum cap in USD
    /// @param maxCapUsd             Maximum cap in USD
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);

    /// @notice                      Rate-limit / config events
    /// @param oldDuration           Previous epoch duration: Duration of the epoch before the update.
    /// @param newDuration           New epoch duration: Duration of the epoch after the update.
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice                     Token limit threshold updated event
    /// @param token                Token address
    /// @param newThreshold         New threshold
    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);

    /// @notice                     Universal transaction event that originates from external chain.
    /// @param sender               Sender of the tx on external chain
    /// @param recipient            Recipient address on Push Chain: for address(0), recipient = sender's UEA on Push Chain.
    /// @param token                Token address being sent
    /// @param amount               Amount of token being sent
    /// @param payload              Payload for arbitrary call on Push Chain: for funds-only tx, payload is empty.
    /// @param revertRecipient      Address to receive funds if the tx is reverted on Push Chain.
    /// @param txType               Transaction type: TX_TYPE enum
    /// @param signatureData        Signature data: for signedVerification, signatureData is the signature of the sender.
    /// @param fromCEA              True if the tx was initiated by a CEA contract.
    event UniversalTx(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes payload,
        address revertRecipient,
        TX_TYPE txType,
        bytes signatureData,
        bool fromCEA
    );

    /// @notice         Universal tx execution event
    event UniversalTxExecuted(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed originCaller,
        address target,
        address token,
        uint256 amount,
        bytes data
    );

    /// @notice                     Revert withdraw event: For withdrwals/actions during a revert
    /// @param subTxId                 Unique transaction identifier
    /// @param to                   Recipient address on external chain
    /// @param token                Token address being reverted
    /// @param amount               Amount of token being reverted
    /// @param revertInstruction    Revert settings configuration
    event RevertUniversalTx(
        bytes32 subTxId,
        bytes32 indexed universalTxId,
        address indexed to,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    /// @notice Emitted when funds are rescued from source chain
    event FundsRescued(
        bytes32 subTxId,
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    /// @notice Emitted when the Vault address is updated
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice                      Protocol fee updated event
    /// @param newFee                New protocol fee in wei
    event ProtocolFeeUpdated(uint256 newFee);

    // =========================
    //  UG_1: UNIVERSAL TRANSACTION
    // =========================
    /**
     * @notice                 Initiate a Universal Transaction using the chain's native token as gas (if any).
     *
     * @dev                    Primary entrypoint for all inbound universal transactions that:
     *                         - Fund a user's UEA on Push Chain with native gas, and/or
     *                         - Bridge funds (native or ERC20) to Push Chain, and/or
     *                         - Execute an arbitrary payload via the user's UEA on Push Chain.
     *
     *                         The function accepts a single `UniversalTxRequest` which describes: ( see /libraries/Types.sol for more details)
     *
     *                         Based on the UniversalTxRequest, the request is classified into one of four
     *                         supported transaction classes:
     *
     *                             1. TX_TYPE.GAS
     *                                 - No payload, no funds, msg.value > 0
     *                                 - Pure gas top-up to the caller's UEA on Push Chain.
     *
     *                             2. TX_TYPE.GAS_AND_PAYLOAD
     *                                 - payload present, no funds
     *                                 - msg.value MAY be 0 (payload-only, using pre-funded UEA gas)
     *                                   or > 0 (payload + fresh gas).
     *
     *                             3. TX_TYPE.FUNDS
     *                                 - funds present, no payload:
     *                                     a) Native funds:
     *                                         - req.token == address(0)
     *                                         - msg.value == req.amount
     *                                     b) ERC20 funds:
     *                                         - req.token != address(0)
     *                                         - msg.value == 0
     *
     *                             4. TX_TYPE.FUNDS_AND_PAYLOAD
     *                                 - funds present, payload present:
     *                                     a) No batching (ERC20 funds, no native):
     *                                     b) Native batching (native funds + native gas):
     *                                     c) ERC20 + native gas batching:
     *
     *                         Routing & rate-limit behavior:
     *                         --------------------------------
     *                         - GAS / GAS_AND_PAYLOAD:
     *                             - Routed to the "instant" Fee Abstraction path via `_sendTxWithGas`.
     *                             - Enforces Rate Limit Checks:
     *                                 - `_checkUSDCaps`      (min/max USD caps per transaction)
     *                                 - `_checkBlockUSDCap`  (per-block USD budget)
     *
     *                         - FUNDS / FUNDS_AND_PAYLOAD:
     *                             - Routed to the Universal Transaction path via `_sendTxWithFunds`.
     *                             - Enforces per-token epoch rate-limits via `_consumeRateLimit(token, amount)`
     *
     * @param req              UniversalTxRequest struct
     */
    function sendUniversalTx(UniversalTxRequest calldata req) external payable;

    /**
     * @notice                 Initiate a Universal Transaction using an ERC20 token as gas input.
     *
     * @dev                    This overload extends `sendUniversalTx(UniversalTxRequest)` by allowing the
     *                         caller to pay "gas" in any supported ERC20 (`gasToken`) instead of native ETH.
     *
     * @dev                    Note that the fundamental flow remains exactly same as sendUniversalTx(UniversalTxRequest)
     *
     * @param reqToken        UniversalTokenTxRequest struct
     */
    function sendUniversalTx(UniversalTokenTxRequest calldata reqToken) external payable;

    // =========================
    //  UG_2: REVERT HANDLING PATHS
    // =========================

    /// @notice             Revert universal transaction (native or ERC20) to the recipient specified in revertInstruction
    /// @param subTxId      unique transaction identifier (for replay protection)
    /// @param universalTxId universal transaction identifier
    /// @param token        token address (address(0) for native)
    /// @param amount       amount to revert
    /// @param revertCFG    revert settings
    function revertUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertCFG
    ) external payable;

    /// @notice             Rescue funds locked in source chain Vault
    /// @param subTxId      unique transaction identifier (for replay protection)
    /// @param universalTxId universal transaction identifier
    /// @param token        token address (address(0) for native)
    /// @param amount       amount to rescue
    /// @param revertCFG    revert settings
    function rescueFunds(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertCFG
    ) external payable;

    // =========================
    //  UG_3: PUBLIC HELPERS
    // =========================

    ///@notice                     Checks if a token is supported by the gateway.
    ///@param token                Token address to check
    ///@return                     True if the token is supported, false otherwise
    function isSupportedToken(address token) external view returns (bool);

    ///@notice             Flat protocol fee in native token (wei). 0 = disabled.
    function INBOUND_FEE() external view returns (uint256);

    ///@notice             Running total of protocol fees collected (native, in wei).
    function totalProtocolFeesCollected() external view returns (uint256);

    /// @notice            Set the flat protocol fee (in wei). Set to 0 to disable.
    /// @param fee         New protocol fee in wei
    function setInboundFee(uint256 fee) external;
}
