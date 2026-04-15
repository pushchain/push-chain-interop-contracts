// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions, TX_TYPE } from "../libraries/Types.sol";
import { UniversalTxRequest, UniversalTokenTxRequest } from "../libraries/TypesUG.sol";

interface IUniversalGateway {
    // ==============================
    //       UG_1: EVENTS
    // ==============================

    /// @notice                  Caps updated event
    /// @param minCapUsd         Minimum cap in USD
    /// @param maxCapUsd         Maximum cap in USD
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);

    /// @notice                  Epoch duration updated event
    /// @param oldDuration       Previous epoch duration
    /// @param newDuration       New epoch duration
    /// @param epochIndexAtChange Epoch index at the time of the change — all per-token usage
    ///                          counters whose stored epoch differs from this value will be treated
    ///                          as reset on the next consumption. Off-chain monitors can use this
    ///                          field to detect the implicit rate-limit reset.
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration, uint64 epochIndexAtChange);

    /// @notice                  Token limit threshold updated event
    /// @param token             Token address
    /// @param newThreshold      New threshold
    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);

    /// @notice                  Universal transaction event that originates from external chain.
    /// @param sender            Sender of the tx on external chain
    /// @param recipient         Recipient address on Push Chain: address(0) = sender's UEA
    /// @param token             Token address being sent
    /// @param amount            Amount of token being sent
    /// @param payload           Payload for arbitrary call on Push Chain (empty for funds-only)
    /// @param revertRecipient   Address to receive funds if the tx is reverted
    /// @param txType            Transaction type (TX_TYPE enum)
    /// @param signatureData     Signature data for signedVerification
    /// @param fromCEA           True if the tx originated from a CEA via sendUniversalTxFromCEA
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

    /// @notice                  Vault updated event
    /// @param oldVault          Previous Vault address
    /// @param newVault          New Vault address
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice                  Uniswap V3 factory / router updated event.
    /// @param oldFactory        Previous Uniswap V3 factory address
    /// @param newFactory        New Uniswap V3 factory address
    /// @param oldRouter         Previous Uniswap V3 router address
    /// @param newRouter         New Uniswap V3 router address
    event UniswapV3ConfigUpdated(
        address indexed oldFactory, address indexed newFactory, address oldRouter, address newRouter
    );

    /// @notice                  Protocol fee updated event
    /// @param newFee            New protocol fee in wei
    event ProtocolFeeUpdated(uint256 newFee);

    /// @notice                  Revert withdraw event: for withdrawals/actions during a revert
    /// @param subTxId           Gateway transaction identifier
    /// @param universalTxId     Universal transaction identifier
    /// @param to                Recipient address on external chain
    /// @param token             Token address being reverted
    /// @param amount            Amount of token being reverted
    /// @param revertInstruction Revert settings configuration
    event RevertUniversalTx(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed to,
        address token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    /// @notice                  Funds rescued via gateway routing
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

    // ==============================
    //  UG_2: UNIVERSAL TRANSACTION
    // ==============================

    /// @notice                  Initiate a Universal Transaction using native token as gas.
    /// @dev                     Primary entrypoint for all inbound universal transactions that:
    ///                          - Fund a user's UEA on Push Chain with native gas, and/or
    ///                          - Bridge funds (native or ERC20) to Push Chain, and/or
    ///                          - Execute an arbitrary payload via the user's UEA on Push Chain.
    ///
    ///                          TX_TYPE is inferred automatically from the request structure:
    ///
    ///                              1. TX_TYPE.GAS
    ///                                  - No payload, no funds, msg.value > 0
    ///
    ///                              2. TX_TYPE.GAS_AND_PAYLOAD
    ///                                  - payload present, no funds
    ///                                  - msg.value MAY be 0 (payload-only) or > 0
    ///
    ///                              3. TX_TYPE.FUNDS
    ///                                  - funds present, no payload:
    ///                                      a) Native: req.token == address(0), msg.value == req.amount
    ///                                      b) ERC20:  req.token != address(0), msg.value == 0
    ///
    ///                              4. TX_TYPE.FUNDS_AND_PAYLOAD
    ///                                  - funds present, payload present:
    ///                                      a) No batching (ERC20 funds, no native)
    ///                                      b) Native batching (native funds + native gas)
    ///                                      c) ERC20 + native gas batching
    ///
    ///                          Rate-limit behavior:
    ///                          - GAS / GAS_AND_PAYLOAD: instant route via _sendTxWithGas
    ///                            (checkUSDCaps + _checkBlockUSDCap)
    ///                          - FUNDS / FUNDS_AND_PAYLOAD: standard route via _sendTxWithFunds
    ///                            (_consumeRateLimit per-token epoch)
    /// @param req               UniversalTxRequest struct
    function sendUniversalTx(UniversalTxRequest calldata req) external payable;

    /// @notice                  Initiate a Universal Transaction using an ERC20 token as gas.
    /// @dev                     Extends sendUniversalTx(UniversalTxRequest) by allowing the caller
    ///                          to pay gas in any supported ERC20 (gasToken) instead of native ETH.
    ///                          The fundamental flow remains exactly the same.
    /// @param reqToken          UniversalTokenTxRequest struct
    function sendUniversalTx(UniversalTokenTxRequest calldata reqToken) external payable;

    /// @notice                  Initiate a Universal Transaction from a CEA (Chain Execution Account).
    /// @dev                     Called by a CEA to send transactions to its linked UEA on Push Chain.
    ///                          Validates CEA identity via CEAFactory, resolves the mapped UEA, and
    ///                          routes with fromCEA=true so Push Chain routes to the correct UEA.
    ///
    ///                          All TX_TYPEs are supported (inferred automatically):
    ///                              1. GAS: instant route, USD caps apply
    ///                              2. GAS_AND_PAYLOAD: instant route, USD caps apply when msg.value > 0
    ///                              3. FUNDS: standard route, epoch rate-limits apply
    ///                              4. FUNDS_AND_PAYLOAD: standard route, gas batching allowed
    ///
    ///                          Strict validations:
    ///                          - msg.sender must be a valid CEA per CEAFactory.isCEA()
    ///                          - req.recipient must match the mapped UEA (anti-spoof)
    /// @param req               UniversalTxRequest struct
    function sendUniversalTxFromCEA(UniversalTxRequest calldata req) external payable;

    // ==============================
    //  UG_3: REVERT HANDLING PATHS
    // ==============================

    /// @notice                  Revert universal transaction (Vault-only). Handles both native and ERC20.
    /// @param subTxId           Gateway transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier
    /// @param token             Token address (address(0) for native)
    /// @param amount            Amount to revert
    /// @param revertInstruction Revert settings
    function revertUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable;

    /// @notice                  Rescue funds routed through the gateway (Vault-only)
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

    // ==============================
    //    UG_4: PUBLIC HELPERS
    // ==============================

    /// @notice                  Checks if a token is supported by the gateway.
    /// @param token             Token address to check
    /// @return                  True if the token is supported, false otherwise
    function isSupportedToken(address token) external view returns (bool);

    /// @notice                  Computes the min and max deposit amounts in native ETH (wei) from USD caps.
    /// @dev                     Uses the current ETH/USD price from getEthUsdPrice().
    /// @return minValue         Minimum native amount (in wei) allowed by MIN_CAP_UNIVERSAL_TX_USD
    /// @return maxValue         Maximum native amount (in wei) allowed by MAX_CAP_UNIVERSAL_TX_USD
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue);

    /// @notice                  Returns both the total token amount used and remaining in the current epoch.
    /// @param token             Token address to query (use address(0) for native)
    /// @return used             Amount already consumed in the current epoch (token's natural units)
    /// @return remaining        Amount still available to send in this epoch (0 if exceeded or unsupported)
    function currentTokenUsage(address token) external view returns (uint256 used, uint256 remaining);

    /// @notice                  Flat protocol fee in native token (wei). 0 = disabled.
    function INBOUND_FEE() external view returns (uint256);

    /// @notice                  Running total of protocol fees collected (native, in wei).
    function totalProtocolFeesCollected() external view returns (uint256);
}
