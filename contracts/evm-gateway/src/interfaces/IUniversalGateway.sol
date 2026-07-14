// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions, TX_TYPE } from "../libraries/Types.sol";
import { UniversalTxRequest, UniversalTokenTxRequest, PC20BurnRequest } from "../libraries/TypesUG.sol";

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

    /// @notice                  PC20 burn event for inbound path (burn wrapper, unlock on Push Chain)
    /// @param sender            User who burned the wrapper tokens
    /// @param sourceAsset       Original PC20 asset address on Push Chain
    /// @param wrapper           PC20Wrapper address burned on this chain
    /// @param amount            Amount of wrapper tokens burned
    /// @param recipient         Push Chain recipient (bytes for cross-VM compat)
    /// @param payload           Optional execution payload on Push Chain
    /// @param revertRecipient   Address to receive re-minted tokens if unlock fails
    /// @param feeCollected      Protocol fee collected in native currency
    event PC20UniversalTx(
        address indexed sender,
        address indexed sourceAsset,
        address indexed wrapper,
        uint256 amount,
        bytes   recipient,
        bytes   payload,
        address revertRecipient,
        uint256 feeCollected
    );

    /// @notice                  PC20 burn reverted — wrapper tokens re-minted
    /// @param subTxId           Transaction identifier (replay protection)
    /// @param universalTxId     Universal transaction identifier for event correlation
    /// @param sourceAsset       Original PC20 asset address on Push Chain
    /// @param amount            Amount of wrapper tokens re-minted
    /// @param revertRecipient   Address that received re-minted wrapper tokens
    event PC20BurnReverted(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed sourceAsset,
        uint256 amount,
        address revertRecipient
    );

    /// @notice                  PC20 burn rescued — wrapper tokens re-minted (user-initiated)
    /// @param subTxId           Transaction identifier (replay protection)
    /// @param universalTxId     Universal transaction identifier for event correlation
    /// @param sourceAsset       Original PC20 asset address on Push Chain
    /// @param amount            Amount of wrapper tokens re-minted
    /// @param rescueRecipient   Address that received re-minted wrapper tokens
    event PC20BurnRescued(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed sourceAsset,
        uint256 amount,
        address rescueRecipient
    );

    /// @notice                  PC20Factory updated event
    /// @param oldFactory        Previous PC20Factory address
    /// @param newFactory        New PC20Factory address
    event PC20FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
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

    /// @notice                  Revert a PC20 burn by re-minting wrapper tokens (TSS-only).
    /// @dev                     Called when Push-side unlock fails after wrapper burn.
    /// @param subTxId           Transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier for event correlation
    /// @param sourceAsset       Original PC20 asset address on Push Chain
    /// @param amount            Amount of wrapper tokens to re-mint
    /// @param revertRecipient   Address to receive re-minted wrapper tokens
    function revertPC20Burn(
        bytes32 subTxId,
        bytes32 universalTxId,
        address sourceAsset,
        uint256 amount,
        address revertRecipient
    ) external;

    /// @notice                  Rescue burned PC20 wrapper tokens by re-minting (TSS-only).
    /// @dev                     Called when user initiates rescue on Push Chain after
    ///                          TSS failed to process the original burn event.
    /// @param subTxId           Transaction identifier (for replay protection)
    /// @param universalTxId     Universal transaction identifier for event correlation
    /// @param sourceAsset       Original PC20 asset address on Push Chain
    /// @param amount            Amount of wrapper tokens to re-mint
    /// @param rescueRecipient   Address to receive re-minted wrapper tokens
    function rescuePC20Burn(
        bytes32 subTxId,
        bytes32 universalTxId,
        address sourceAsset,
        uint256 amount,
        address rescueRecipient
    ) external;

    // ==============================
    //  UG_3b: PC20 BURN (INBOUND)
    // ==============================

    /// @notice                  Burn wrapped PC20 tokens to unlock originals on Push Chain.
    /// @dev                     Permissionless. No rate limiting (burns reduce supply).
    ///                          No approval needed (factory calls OZ _burn internally).
    /// @param req               PC20BurnRequest struct
    function sendPC20UniversalTx(PC20BurnRequest calldata req) external payable;

    /// @notice                  Update the PC20Factory address.
    /// @param newFactory        New PC20Factory address
    function updatePC20Factory(address newFactory) external;

    // ==============================
    //    UG_4: PUBLIC HELPERS
    // ==============================

    /// @notice                  Checks if a token is supported by the gateway.
    /// @param token             Token address to check
    /// @return                  True if the token is supported, false otherwise
    function isSupportedToken(address token) external view returns (bool);

    /// @notice                  Computes the min and max deposit amounts in native ETH (wei) from USD caps.
    /// @dev                     Uses the current ETH/USD price from getEthUsdPrice().
    /// @return minValue         Minimum native amount (in wei) allowed by minCapUniversalTxUsd
    /// @return maxValue         Maximum native amount (in wei) allowed by maxCapUniversalTxUsd
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue);

    /// @notice                  Returns both the total token amount used and remaining in the current epoch.
    /// @param token             Token address to query (use address(0) for native)
    /// @return used             Amount already consumed in the current epoch (token's natural units)
    /// @return remaining        Amount still available to send in this epoch (0 if exceeded or unsupported)
    function currentTokenUsage(address token) external view returns (uint256 used, uint256 remaining);

    /// @notice                  Flat protocol fee in native token (wei). 0 = disabled.
    function inboundFee() external view returns (uint256);

    /// @notice                  Running total of protocol fees collected (native, in wei).
    function totalProtocolFeesCollected() external view returns (uint256);

    /// @notice                  Whether the gateway is currently paused.
    function paused() external view returns (bool);
}
