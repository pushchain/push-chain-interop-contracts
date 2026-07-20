// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  UniversalGateway
 * @notice Universal Gateway for EVM chains.
 *         Acts as a gateway for all supported external chains to bridge funds and payloads to Push Chain.
 *
 * @dev    Transaction Types: 4 types supported (see ./libraries/Types.sol):
 *         1. GAS_TX: Fund UEAs on Push Chain with gas deposits.
 *         2. GAS_AND_PAYLOAD_TX: Fund UEAs + execute payloads through UEAs.
 *         3. FUNDS_TX: Move large-ticket funds to any recipient on Push Chain.
 *         4. FUNDS_AND_PAYLOAD_TX: Move funds + execute payloads.
 *
 * @dev    Authorization model:
 *         1. Revert / rescue paths (revertUniversalTx, rescueFunds) are gated by VAULT_ROLE.
 *            TSS authorization is enforced upstream in the Vault contract (Vault holds the
 *            TSS_ROLE and is the sole holder of VAULT_ROLE here). UniversalGateway itself
 *            does not manage a TSS_ROLE; it only tracks tssAddress as the native-fee /
 *            deposit recipient.
 *         2. The token support list (tokenToLimitThreshold) is managed by DEFAULT_ADMIN_ROLE and
 *            is used for rate-limiting and bridge-support validation of ERC20 funds via
 *            _consumeRateLimit and _handleDeposits. It is NOT used to validate gas tokens in
 *            sendUniversalTx(UniversalTokenTxRequest); gas token validation is limited to
 *            non-zero and swap-related constraints.
 *
 * @dev    Rate-Limit Checks:
 *         - Instant route (GAS / GAS_AND_PAYLOAD): checkUSDCaps + _checkBlockUSDCap
 *         - Standard route (FUNDS / FUNDS_AND_PAYLOAD): _consumeRateLimit (per-token epoch)
 *
 * @dev    Chainlink Oracle is used for ETH/USD price feed.
 */

import { Errors } from "./libraries/Errors.sol";
import { ICEAFactory } from "./interfaces/ICEAFactory.sol";
import { IUniversalGateway } from "./interfaces/IUniversalGateway.sol";
import { IWETH } from "./interfaces/IWETH.sol";
import { RevertInstructions, TX_TYPE, EpochUsage, PC_20_SELECTOR, PRC_20_SELECTOR } from "./libraries/Types.sol";
import { UniversalTxRequest, UniversalTokenTxRequest } from "./libraries/TypesUG.sol";
import { IPC20Factory } from "./interfaces/IPC20Factory.sol";
import { PC20Wrapper } from "./PC20Wrapper.sol";

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { ISwapRouter as ISwapRouterV3 } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract UniversalGateway is
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IUniversalGateway
{
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant UG_ADMIN_ROLE = keccak256("UG_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice Minimum permitted value for chainlinkStalePeriod. Prevents admin from disabling
    ///         oracle freshness validation by setting the period to 0 or an absurdly small value.
    uint256 public constant MIN_CHAINLINK_STALE_PERIOD = 10 minutes;

    /// @notice Upper bound for inboundFee. Prevents admin from configuring an absurdly high flat
    ///         protocol fee that would DoS or grief users.
    uint256 public constant MAX_INBOUND_FEE = 0.05 ether;

    /// @notice MUTABLE — admin-updatable via updateTSS.
    address public tssAddress;
    /// @notice MUTABLE — admin-updatable via updateVault.
    address public vault;

    /// @notice Rate-Limiting CAPS and States
    /// @dev MUTABLE — admin-updatable via setBlockUsdCap.
    uint256 public blockUsdCap;
    uint256 public epochDurationSec;
    uint256 private _lastBlockNumber;
    /// @dev Storage slot preserved from previous `_consumedUSDinBlock` (pre-converted USD total).
    ///      Semantic changed to raw native-wei consumed in the current block; USD is computed
    ///      at check time against the current oracle price to avoid mixed-price accounting
    ///      across intra-block oracle updates.
    uint256 private _consumedWeiInBlock;
    /// @dev MUTABLE — admin-updatable via setCapsUSD.
    uint256 public minCapUniversalTxUsd;
    /// @dev MUTABLE — admin-updatable via setCapsUSD.
    uint256 public maxCapUniversalTxUsd;
    mapping(address => uint256) public tokenToLimitThreshold;
    mapping(address => EpochUsage) private _usage;

    /// @notice Uniswap V3 factory & router (chain-specific)
    /// @dev MUTABLE — set in initialize only.
    ///      (No runtime setter currently, but the slot is storage and upgradable.)
    address public weth;
    ISwapRouterV3 public uniV3Router;
    IUniswapV3Factory public uniV3Factory;
    uint256 public defaultSwapDeadlineSec;
    uint24[3] public v3FeeOrder;

    /// @notice Chainlink Oracle Configs
    uint256 public chainlinkStalePeriod;
    uint8 public chainlinkEthUsdDecimals;
    AggregatorV3Interface public ethUsdFeed;
    uint256 public l2SequencerGracePeriodSec;
    AggregatorV3Interface public l2SequencerFeed;

    mapping(bytes32 => bool) public isExecuted;

    /// @notice MUTABLE — admin-updatable via setCEAFactory.
    address public ceaFactory;

    /// @notice MUTABLE — admin-updatable via setInboundFee.
    uint256 public inboundFee;

    uint256 public totalProtocolFeesCollected;

    IPC20Factory public pc20Factory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param admin             DEFAULT_ADMIN_ROLE holder
    /// @param pauser            PAUSER_ROLE holder
    /// @param tss               Initial TSS address
    /// @param vaultAddress      Vault contract address
    /// @param minCapUsd         Min USD cap (1e18 decimals)
    /// @param maxCapUsd         Max USD cap (1e18 decimals)
    /// @param factory           UniswapV3 factory
    /// @param router            UniswapV3 router
    /// @param wethAddress       WETH address
    function initialize(
        address admin,
        address pauser,
        address tss,
        address vaultAddress,
        uint256 minCapUsd,
        uint256 maxCapUsd,
        address factory,
        address router,
        address wethAddress
    ) external initializer {
        if (
            admin == address(0) || pauser == address(0) || tss == address(0) || vaultAddress == address(0)
                || wethAddress == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlDefaultAdminRules_init(1 days, admin);

        _setRoleAdmin(UG_ADMIN_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(VAULT_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(UG_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(VAULT_ROLE, vaultAddress);

        tssAddress = tss;
        vault = vaultAddress;
        minCapUniversalTxUsd = minCapUsd;
        maxCapUniversalTxUsd = maxCapUsd;

        weth = wethAddress;
        if ((factory == address(0)) != (router == address(0))) {
            revert Errors.ZeroAddress();
        }
        if (factory != address(0)) {
            uniV3Factory = IUniswapV3Factory(factory);
            uniV3Router = ISwapRouterV3(router);
        }
        // Default swap deadline window (industry common ~10 minutes)
        defaultSwapDeadlineSec = 10 minutes;
        // Set a sane default for Chainlink staleness (can be tuned by admin)
        chainlinkStalePeriod = 1 hours;
        // Default epoch duration for global funds rate limit (Axelar-style)
        epochDurationSec = 6 hours;
    }

    // ==============================
    //     UG_1: ADMIN ACTIONS
    // ==============================
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    function paused() public view override(PausableUpgradeable, IUniversalGateway) returns (bool) {
        return super.paused();
    }

    /// @notice                Allows the admin to update the TSS address.
    /// @dev                   TSS authorization in UG is enforced via the
    ///                        `tssAddress` state variable (used as the native-fee / deposit
    ///                        recipient). No `TSS_ROLE` role is managed here; TSS role
    ///                        enforcement for outbound operations lives in the Vault contract.
    /// @param newTSS          New TSS address.
    function updateTSS(address newTSS) external onlyRole(OPERATOR_ROLE) {
        if (newTSS == address(0)) revert Errors.ZeroAddress();
        tssAddress = newTSS;
    }

    /// @notice                Allows the admin to update the Vault address
    /// @param newVault        New Vault address
    function updateVault(address newVault) external onlyRole(OPERATOR_ROLE) {
        if (newVault == address(0)) revert Errors.ZeroAddress();
        address old = vault;

        // transfer role
        if (hasRole(VAULT_ROLE, old)) _revokeRole(VAULT_ROLE, old);
        _grantRole(VAULT_ROLE, newVault);

        vault = newVault;
        emit VaultUpdated(old, newVault);
    }

    /// @notice                Allows the admin to set the USD cap ranges
    /// @param minCapUsd       Minimum USD cap
    /// @param maxCapUsd       Maximum USD cap
    function setCapsUSD(uint256 minCapUsd, uint256 maxCapUsd) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        if (minCapUsd > maxCapUsd) revert Errors.InvalidCapRange();

        minCapUniversalTxUsd = minCapUsd;
        maxCapUniversalTxUsd = maxCapUsd;
        emit CapsUpdated(minCapUsd, maxCapUsd);
    }

    /// @notice                Set the per-block USD cap for GAS routes (1e18 = $1). 0 disables.
    /// @param cap1e18         Per-block USD cap scaled to 1e18
    function setBlockUsdCap(uint256 cap1e18) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        blockUsdCap = cap1e18;
    }

    /// @notice                Set the default swap deadline window (used when caller passes deadline = 0)
    /// @param deadlineSec     Number of seconds to add to block.timestamp
    function setDefaultSwapDeadline(uint256 deadlineSec) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        if (deadlineSec == 0) revert Errors.InvalidAmount();
        defaultSwapDeadlineSec = deadlineSec;
    }

    /// @notice                Allows the admin to set the Uniswap V3 factory and router.
    /// @dev                   Renamed from setRouters. The previous
    ///                        plural name implied multi-router support that does not exist.
    /// @param factory         New Uniswap V3 factory address
    /// @param router          New Uniswap V3 router address
    function updateUniswapV3Config(address factory, address router) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (factory == address(0) || router == address(0)) revert Errors.ZeroAddress();
        address oldFactory = address(uniV3Factory);
        address oldRouter = address(uniV3Router);
        uniV3Factory = IUniswapV3Factory(factory);
        uniV3Router = ISwapRouterV3(router);
        emit UniswapV3ConfigUpdated(oldFactory, factory, oldRouter, router);
    }

    /// @notice                Set limit thresholds for a batch of tokens (0 disables support)
    /// @param tokens          Tokens to set limit thresholds for
    /// @param thresholds      Limit thresholds for the tokens
    function setTokenLimitThresholds(address[] calldata tokens, uint256[] calldata thresholds)
        external
        onlyRole(UG_ADMIN_ROLE)
    {
        if (tokens.length != thresholds.length) revert Errors.InvalidInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenToLimitThreshold[tokens[i]] = thresholds[i];
            emit TokenLimitThresholdUpdated(tokens[i], thresholds[i]);
        }
    }

    /// @notice                Update the epoch duration (hard reset schedule)
    /// @dev                   Changing the epoch duration shifts the epoch index globally
    ///                        (`block.timestamp / epochDurationSec`). All per-token usage counters
    ///                        whose stored epoch no longer matches the new index will be silently
    ///                        reset to zero on the next rate-limit consumption — restoring full
    ///                        throughput for every token. Admins must treat this as an implicit
    ///                        rate-limit reset across the board. The emitted `epochIndexAtChange`
    ///                        value records the old epoch index at the moment of the update so the
    ///                        reset is auditable on-chain.
    /// @param newDurationSec  New epoch duration in seconds
    function updateEpochDuration(uint256 newDurationSec) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        if (newDurationSec == 0) revert Errors.InvalidInput();
        uint256 old = epochDurationSec;
        uint64 epochIndexAtChange = uint64(block.timestamp / old);
        epochDurationSec = newDurationSec;
        emit EpochDurationUpdated(old, newDurationSec, epochIndexAtChange);
    }

    /// @notice                Allows the admin to set the fee order for the Uniswap V3 router
    /// @param a               First fee tier
    /// @param b               Second fee tier
    /// @param c               Third fee tier
    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        v3FeeOrder = [a, b, c];
    }

    /// @notice                Set the Chainlink ETH/USD feed (and cache its decimals)
    /// @param feed            Chainlink ETH/USD feed address
    function setEthUsdFeed(address feed) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        if (feed == address(0)) revert Errors.ZeroAddress();
        AggregatorV3Interface f = AggregatorV3Interface(feed);
        // Will revert if not a contract or not a valid aggregator when decimals() is called by non-aggregator contracts.
        uint8 dec = f.decimals();
        ethUsdFeed = f;
        chainlinkEthUsdDecimals = dec;
    }

    /// @notice                Configure the maximum allowed data staleness for Chainlink reads.
    /// @dev                   Must be >= MIN_CHAINLINK_STALE_PERIOD to prevent accidental or
    ///                        intentional disabling of freshness validation.
    /// @param stalePeriodSec  latestRoundData().updatedAt must be within this many seconds
    function setChainlinkStalePeriod(uint256 stalePeriodSec) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        if (stalePeriodSec < MIN_CHAINLINK_STALE_PERIOD) revert Errors.InvalidInput();
        chainlinkStalePeriod = stalePeriodSec;
    }

    /// @notice                Set (or clear) the Chainlink L2 sequencer uptime feed for rollups
    /// @dev                   Set to address(0) on L1s / chains without a sequencer feed.
    /// @param feed            Chainlink L2 sequencer uptime feed address
    function setL2SequencerFeed(address feed) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        l2SequencerFeed = AggregatorV3Interface(feed);
    }

    /// @notice                Configure the grace window after sequencer comes back up
    /// @param gracePeriodSec  If > 0, require block.timestamp - sequencer.updatedAt > gracePeriodSec
    function setL2SequencerGracePeriod(uint256 gracePeriodSec) external onlyRole(UG_ADMIN_ROLE) whenNotPaused {
        l2SequencerGracePeriodSec = gracePeriodSec;
    }

    /// @notice                Set the CEAFactory address for CEA identity validation
    /// @param newFactory      New CEAFactory address
    function updateCEAFactory(address newFactory) external onlyRole(OPERATOR_ROLE) {
        if (newFactory == address(0)) revert Errors.ZeroAddress();
        ceaFactory = newFactory;
    }

    /// @inheritdoc IUniversalGateway
    function updatePC20Factory(address newFactory) external onlyRole(OPERATOR_ROLE) {
        if (newFactory == address(0)) revert Errors.ZeroAddress();
        address old = address(pc20Factory);
        pc20Factory = IPC20Factory(newFactory);
        emit PC20FactoryUpdated(old, newFactory);
    }

    /// @notice                Set the flat protocol fee (in wei). 0 disables.
    /// @dev                   Must be <= MAX_INBOUND_FEE to prevent misconfiguration or governance
    ///                        abuse.
    /// @param fee             New protocol fee in wei
    function setInboundFee(uint256 fee) external onlyRole(UG_ADMIN_ROLE) {
        if (fee > MAX_INBOUND_FEE) revert Errors.InvalidInput();
        inboundFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    // ==============================
    //   UG_2: UNIVERSAL TRANSACTION
    // ==============================

    /// @inheritdoc IUniversalGateway
    function sendUniversalTx(UniversalTxRequest calldata req) external payable nonReentrant whenNotPaused {
        if (_isCallerCEA()) revert Errors.InvalidInput();
        _routeUniversalTx(req, _msgSender(), msg.value, false);
    }

    /// @inheritdoc IUniversalGateway
    function sendUniversalTx(UniversalTokenTxRequest calldata reqToken) external payable nonReentrant whenNotPaused {
        if (_isCallerCEA()) revert Errors.InvalidInput();
        if (msg.value != 0) revert Errors.InvalidInput();
        // Validate token-as-gas parameters
        if (reqToken.gasToken == address(0)) revert Errors.InvalidInput();
        if (reqToken.gasAmount == 0) revert Errors.InvalidAmount();
        if (reqToken.amountOutMinETH == 0) revert Errors.InvalidAmount();

        // Swap token to native
        uint256 nativeValue =
            _swapToNative(reqToken.gasToken, reqToken.gasAmount, reqToken.amountOutMinETH, reqToken.deadline);

        // Build UniversalTxRequest from token request
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: reqToken.recipient,
            token: reqToken.token,
            amount: reqToken.amount,
            payload: reqToken.payload,
            revertRecipient: reqToken.revertRecipient,
            signatureData: reqToken.signatureData
        });

        _routeUniversalTx(req, _msgSender(), nativeValue, false);
    }

    /// @inheritdoc IUniversalGateway
    function sendUniversalTxFromCEA(UniversalTxRequest calldata req) external payable nonReentrant whenNotPaused {
        if (ceaFactory == address(0)) revert Errors.InvalidInput();
        if (!_isCallerCEA()) revert Errors.InvalidInput();

        address mappedUEA = ICEAFactory(ceaFactory).getPushAccountForCEA(_msgSender());
        if (mappedUEA == address(0)) revert Errors.InvalidInput();

        if (req.recipient != mappedUEA) revert Errors.InvalidRecipient();

        _routeUniversalTx(req, _msgSender(), msg.value, true);
    }

    // ==============================
    //  UG_2b: PC20 BURN (INBOUND)
    // ==============================

    /// @dev PC20 inbound burn path. Called from _routeUniversalTx when req.token
    ///      is a PC20 wrapper. Burns wrapper tokens and emits UniversalTx with
    ///      PC_20_SELECTOR-prefixed payload so cosmos can distinguish PC20 from PRC20.
    ///      When nativeValue > 0 (excess ETH after fee), routes it as a standard
    ///      FUNDS transfer to the caller's UEA via _sendTxWithFunds.
    function _routePC20Tx(UniversalTxRequest memory req, address caller, uint256 nativeValue, bool fromCEA) private {
        if (req.amount == 0) revert Errors.ZeroAmount();

        address sourceAsset = PC20Wrapper(req.token).SOURCE_ASSET();

        pc20Factory.burnFrom(sourceAsset, caller, req.amount);

        bytes memory prefixedPayload = abi.encodePacked(
            PC_20_SELECTOR, req.payload
        );

        _emitUniversalTx(
            caller,
            req.recipient,
            req.token,
            req.amount,
            prefixedPayload,
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            req.signatureData,
            fromCEA
        );

        // Route excess native value as a standard FUNDS transfer to caller's UEA
        if (nativeValue > 0) {
            UniversalTxRequest memory nativeReq = UniversalTxRequest({
                recipient: req.recipient,
                token: address(0),
                amount: nativeValue,
                payload: bytes(""),
                revertRecipient: req.revertRecipient,
                signatureData: req.signatureData
            });
            TX_TYPE nativeTxType = _fetchTxType(nativeReq, nativeValue);
            _sendTxWithFunds(nativeReq, nativeValue, nativeTxType, fromCEA);
        }
    }

    // ==============================
    //  UG_2.1: TX INTERNAL HELPERS
    // ==============================

    /// @dev                    Internal helper to deposit for TX_TYPE.GAS or TX_TYPE.GAS_AND_PAYLOAD.
    ///                         Handles rate-limit checks for the instant tx route.
    ///                         Recipient address(0) attributes funds to the caller's UEA on Push Chain.
    /// @param _txType          TX_TYPE.GAS or TX_TYPE.GAS_AND_PAYLOAD
    /// @param _caller          Caller address
    /// @param _recipient       Recipient address (mapped UEA when fromCEA, address(0) otherwise)
    /// @param _gasAmount       Gas amount
    /// @param _payload         Payload
    /// @param _revertRecipient Revert recipient address
    /// @param _signatureData   Signature data
    /// @param _fromCEA         True if originated from a CEA via sendUniversalTxFromCEA
    function _sendTxWithGas(
        TX_TYPE _txType,
        address _caller,
        address _recipient,
        uint256 _gasAmount,
        bytes memory _payload,
        address _revertRecipient,
        bytes memory _signatureData,
        bool _fromCEA
    ) private {
        if (_gasAmount > 0) {
            checkUSDCaps(_gasAmount);
            _checkBlockUSDCap(_gasAmount);
            _handleDeposits(address(0), _gasAmount);
        }

        _emitUniversalTx(
            _caller, _recipient, address(0), _gasAmount, _payload, _revertRecipient, _txType, _signatureData, _fromCEA
        );
    }

    /// @dev                    Internal helper to deposit for TX_TYPE.FUNDS or TX_TYPE.FUNDS_AND_PAYLOAD.
    ///                         Handles rate-limit checks for the standard tx route.
    ///                         Recipient address(0) attributes funds to the caller's UEA on Push Chain.
    /// @param _req             UniversalTxRequest struct
    /// @param nativeValue      Native value (msg.value)
    /// @param txType           TX_TYPE.FUNDS or TX_TYPE.FUNDS_AND_PAYLOAD
    /// @param fromCEA          True if called via sendUniversalTxFromCEA
    function _sendTxWithFunds(UniversalTxRequest memory _req, uint256 nativeValue, TX_TYPE txType, bool fromCEA)
        private
    {
        // Case 1: For TX_TYPE = FUNDS

        if (txType == TX_TYPE.FUNDS) {
            address tokenForFunds;
            // Case 1.1: Token to bridge is Native Token -> address(0)
            // req.amount = desired bridge amount (fee is additive: msg.value = req.amount + inboundFee).
            // nativeValue is post-fee (= msg.value - inboundFee = req.amount).
            if (_req.token == address(0)) {
                if (_req.amount != nativeValue) revert Errors.InvalidAmount();
                tokenForFunds = address(0);
            }
            // Case 1.2: Token to bridge is ERC20 Token -> _req.token
            // Post-fee nativeValue is routed as a gas top-up (e.g. from _swapToNative or batched native).
            // If nativeValue == 0 (no gas), only the ERC20 bridge proceeds.
            else {
                if (nativeValue > 0) {
                    address gasRecipient = fromCEA ? _req.recipient : address(0);
                    _sendTxWithGas(
                        TX_TYPE.GAS,
                        _msgSender(),
                        gasRecipient,
                        nativeValue,
                        bytes(""),
                        _req.revertRecipient,
                        _req.signatureData,
                        fromCEA
                    );
                }
                tokenForFunds = _req.token;
            }

            _consumeRateLimit(tokenForFunds, _req.amount);
            _handleDeposits(tokenForFunds, _req.amount);

            _emitUniversalTx(
                _msgSender(),
                _req.recipient,
                tokenForFunds,
                _req.amount,
                _req.payload,
                _req.revertRecipient,
                txType,
                _req.signatureData,
                fromCEA
            );
        }

        // Case 2: For TX_TYPE = FUNDS_AND_PAYLOAD
        // Note: Two possible routes for TX_TYPE.FUNDS_AND_PAYLOAD:
        //       - Case 2.1: No Batching (nativeValue == 0): user already has UEA with PC token ( gas ) on Push to execute payloads
        //           -> user already has UEA with native PC tokens on Push Chain.
        //           -> user can directly move _req.amount for _req.token to Push Chain.
        //       - Case 2.2: Batching of Gas + Funds_and_Payload (nativeValue > 0): with token == native_token
        //           -> user refils UEA's gas and also bridges native token.
        //           -> Split Needed: Native token is split between gasAmount and bridge amount ( nativeValue >= _req.amount )
        //           -> _sendTxWithGas is used to send gasAmount
        //           -> _sendTxWithFunds is used to send bridgeAmount
        //       - Case 2.3: Batching of Gas + Funds_and_Payload (nativeValue > 0): with token != native_token
        //            -> user refils UEA's gas and also bridges ERC20 token.
        //            -> No Split Needed: gasAmount is used via native_token, and bridgeAmount is used via ERC20 token.
        //            -> _sendTxWithGas is used to send gasAmount
        //            -> _sendTxWithFunds is used to send bridgeAmount
        if (txType == TX_TYPE.FUNDS_AND_PAYLOAD) {
            address tokenForFundsAndPayload;
            // When fromCEA, the gas leg must emit recipient=req.recipient (mapped UEA) so Push Chain
            // routes the gas to the correct UEA instead of deploying a new one for the CEA address.
            // address(0) recipient: Push Chain attributes funds to the sender's UEA
            address gasRecipient = fromCEA ? _req.recipient : address(0);
            // Case 2.1: No Batching ( nativeValue == 0 ): user already has UEA with PC token ( gas ) on Push to execute payloads
            if (nativeValue == 0) {
                if (_req.token == address(0)) revert Errors.InvalidAmount();

                tokenForFundsAndPayload = _req.token;
            }
            // Case 2.2: Batching of Gas + Funds_and_Payload (nativeValue > 0): with token == native_token
            else if (_req.token == address(0)) {
                if (nativeValue < _req.amount) revert Errors.InvalidAmount();

                uint256 gasAmount = nativeValue - _req.amount;

                if (gasAmount > 0) {
                    _sendTxWithGas(
                        TX_TYPE.GAS,
                        _msgSender(),
                        gasRecipient,
                        gasAmount,
                        bytes(""),
                        _req.revertRecipient,
                        _req.signatureData,
                        fromCEA
                    );
                }
                tokenForFundsAndPayload = address(0);
            }
            // Case 2.3: Batching of Gas + Funds_and_Payload (nativeValue > 0): with token != native_token
            // _req.token != address(0) is implied by the prior branches (Case 2.1 handles
            // nativeValue == 0; Case 2.2 handles nativeValue > 0 && _req.token == address(0)).
            else {
                uint256 gasAmount = nativeValue;
                // Send Gas to caller's UEA via instant route
                _sendTxWithGas(
                    TX_TYPE.GAS,
                    _msgSender(),
                    gasRecipient,
                    gasAmount,
                    bytes(""),
                    _req.revertRecipient,
                    _req.signatureData,
                    fromCEA
                );

                tokenForFundsAndPayload = _req.token;
            }

            _consumeRateLimit(tokenForFundsAndPayload, _req.amount);
            _handleDeposits(tokenForFundsAndPayload, _req.amount);

            // fromCEA: emit req.recipient (mapped UEA); normal: address(0) → Push Chain attributes to sender's UEA
            address fundsAndPayloadRecipient = fromCEA ? _req.recipient : address(0);
            _emitUniversalTx(
                _msgSender(),
                fundsAndPayloadRecipient,
                tokenForFundsAndPayload,
                _req.amount,
                _req.payload,
                _req.revertRecipient,
                txType,
                _req.signatureData,
                fromCEA
            );
        }
    }

    /// @dev                    Internal helper to emit the UniversalTx event.
    /// @param sender           Sender address
    /// @param recipient        Recipient address
    /// @param token            Token address
    /// @param amount           Amount
    /// @param payload          Payload
    /// @param revertRecipient  Revert recipient address
    /// @param txType           TX_TYPE
    /// @param signatureData    Signature data
    /// @param fromCEA          True if originated from a CEA
    function _emitUniversalTx(
        address sender,
        address recipient,
        address token,
        uint256 amount,
        bytes memory payload,
        address revertRecipient,
        TX_TYPE txType,
        bytes memory signatureData,
        bool fromCEA
    ) private {
        emit UniversalTx({
            sender: sender,
            recipient: recipient,
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: revertRecipient,
            txType: txType,
            signatureData: signatureData,
            fromCEA: fromCEA
        });
    }

    // ==============================
    //  UG_3: REVERT HANDLING PATHS
    // ==============================

    /// @inheritdoc IUniversalGateway
    function revertUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable nonReentrant whenNotPaused onlyRole(VAULT_ROLE) {
        _validateRevertParams(subTxId, amount, token, revertInstruction.revertRecipient);

        if (token == address(0)) {
            (bool ok,) = payable(revertInstruction.revertRecipient).call{ value: amount }("");
            if (!ok) revert Errors.WithdrawFailed();
        } else {
            IERC20(token).safeTransfer(revertInstruction.revertRecipient, amount);
        }

        emit RevertUniversalTx(
            subTxId, universalTxId, revertInstruction.revertRecipient, token, amount, revertInstruction
        );
    }

    /// @inheritdoc IUniversalGateway
    function rescueFunds(
        bytes32 subTxId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external payable nonReentrant whenNotPaused onlyRole(VAULT_ROLE) {
        _validateRevertParams(subTxId, amount, token, revertInstruction.revertRecipient);

        if (token == address(0)) {
            (bool ok,) = payable(revertInstruction.revertRecipient).call{ value: amount }("");
            if (!ok) revert Errors.WithdrawFailed();
        } else {
            IERC20(token).safeTransfer(revertInstruction.revertRecipient, amount);
        }

        emit FundsRescued(subTxId, universalTxId, token, amount, revertInstruction);
    }

    /// @dev Validates common revert/rescue parameters and marks subTxId as executed.
    function _validateRevertParams(bytes32 subTxId, uint256 amount, address token, address revertRecipient) private {
        if (isExecuted[subTxId]) revert Errors.PayloadExecuted();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0) revert Errors.InvalidAmount();
        // Validate msg.value for both paths: native requires msg.value == amount; ERC20 forbids
        // native value entirely.
        if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
        }

        isExecuted[subTxId] = true;
    }

    // ==============================
    //    UG_4: PUBLIC HELPERS
    // ==============================

    /// @inheritdoc IUniversalGateway
    function isSupportedToken(address token) public view returns (bool) {
        return tokenToLimitThreshold[token] != 0;
    }

    /// @inheritdoc IUniversalGateway
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue) {
        (uint256 ethUsdPrice,) = getEthUsdPrice(); // ETH price in USD (1e18 scaled)
        minValue = (minCapUniversalTxUsd * 1e18) / ethUsdPrice;
        maxValue = (maxCapUniversalTxUsd * 1e18) / ethUsdPrice;
    }

    /// @notice                 Returns the ETH/USD price scaled to 1e18 (i.e., USD with 18 decimals).
    /// @dev                    Reads Chainlink AggregatorV3, applies safety checks,
    ///                         then rescales from the feed's native decimals (typically 8) to 1e18.
    ///                         Output: price1e18 = USD(1e18) per 1 ETH (e.g., ETH = $4,400 → 4_400e18).
    /// @return price1e18       ETH price in USD scaled to 1e18
    /// @return chainlinkDecimals  The decimals of the underlying Chainlink feed (e.g., 8)
    function getEthUsdPrice() public view returns (uint256, uint8) {
        if (address(ethUsdFeed) == address(0)) revert Errors.InvalidInput(); // feed not set

        // Optional L2 sequencer-uptime enforcement for rollups
        if (address(l2SequencerFeed) != address(0)) {
            (, // roundId (unused)
                int256 status, // 0 = UP, 1 = DOWN
                ,
                uint256 sequencerUpdatedAt,
                /* uint80 answeredInRound */
            ) = l2SequencerFeed.latestRoundData();

            // Revert if sequencer is DOWN
            if (status == 1) revert Errors.InvalidData();

            // Revert if still within grace period after sequencer came back UP
            if (l2SequencerGracePeriodSec != 0 && block.timestamp - sequencerUpdatedAt <= l2SequencerGracePeriodSec) {
                revert Errors.InvalidData();
            }
        }

        (uint80 roundId, int256 priceInUSD,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();

        // Basic oracle safety checks
        if (priceInUSD <= 0) revert Errors.InvalidData();
        if (answeredInRound < roundId) revert Errors.InvalidData();
        if (chainlinkStalePeriod != 0 && block.timestamp - updatedAt > chainlinkStalePeriod) {
            revert Errors.InvalidData();
        }

        uint8 dec = chainlinkEthUsdDecimals;
        if (dec == 0) {
            try ethUsdFeed.decimals() returns (uint8 feedDecimals) {
                dec = feedDecimals;
            } catch {
                // If feed doesn't support decimals(), assume standard Chainlink ETH/USD format (8 decimals)
                dec = 8;
            }
        }
        // Scale priceInUSD (decimals = dec) to 1e18
        uint256 scale;
        unchecked {
            // dec is expected to be <= 18 for feeds; if >18, this will underflow so guard:
            if (dec > 18) revert Errors.InvalidData();
            scale = 10 ** uint256(18 - dec);
        }
        return (uint256(priceInUSD) * scale, dec);
    }

    /// @notice                 Converts an ETH amount (in wei) to USD with 18 decimals via Chainlink price.
    /// @dev                    Uses getEthUsdPrice which returns USD(1e18) per ETH.
    /// @param amountWei        Amount of ETH in wei to convert
    /// @return usd1e18         USD value scaled to 1e18
    function quoteEthAmountInUsd1e18(uint256 amountWei) public view returns (uint256 usd1e18) {
        if (amountWei == 0) return 0;
        (uint256 px1e18,) = getEthUsdPrice(); // will validate freshness and positivity
        // Note: amountWei is 1e18-based (wei), price is scaled to 1e18 above.
        usd1e18 = (amountWei * px1e18) / 1e18;
    }

    /// @inheritdoc IUniversalGateway
    function currentTokenUsage(address token) public view returns (uint256 used, uint256 remaining) {
        uint256 thr = tokenToLimitThreshold[token];
        if (thr == 0) return (0, 0);

        uint256 _epochDuration = epochDurationSec;
        if (_epochDuration == 0) return (0, 0);

        uint64 current = uint64(block.timestamp / _epochDuration);
        EpochUsage storage e = _usage[token];
        uint256 u = (e.epoch == current) ? uint256(e.used) : 0;

        used = u;
        remaining = u >= thr ? 0 : (thr - u);
    }

    // ==============================
    //   UG_5: INTERNAL HELPERS
    // ==============================

    /// @dev Returns true if the caller is a CEA deployed by the configured factory.
    ///      Returns false when ceaFactory is not set, preserving backward compatibility.
    ///      Used by sendUniversalTxFromCEA and sendUniversalTx to enforce CEA identity.
    function _isCallerCEA() private view returns (bool) {
        if (ceaFactory == address(0)) return false;
        return ICEAFactory(ceaFactory).isCEA(_msgSender());
    }

    /// @dev Returns true when token is a PC20 wrapper deployed by the factory.
    function _isPC20Wrapper(address token) private view returns (bool) {
        if (address(pc20Factory) == address(0)) return false;
        return pc20Factory.isPC20Wrapper(token);
    }

    /// @dev                    Check if the amount is within the USD cap range.
    ///                         Cap ranges are defined in the initializer or updated by the admin.
    /// @param amount           Amount to check
    function checkUSDCaps(uint256 amount) public view {
        uint256 usdValue = quoteEthAmountInUsd1e18(amount);
        if (usdValue < minCapUniversalTxUsd) revert Errors.InvalidAmount();
        if (usdValue > maxCapUniversalTxUsd) revert Errors.InvalidAmount();
    }

    /// @dev                    Handle deposits of native ETH or ERC20 tokens.
    ///                         If token is address(0): Forward native ETH to TSS.
    ///                         Otherwise: Lock ERC20 in the Vault contract for bridging.
    /// @param token            Token address (address(0) for native ETH)
    /// @param amount           Amount to deposit
    function _handleDeposits(address token, uint256 amount) internal {
        if (token == address(0)) {
            // Handle native ETH deposit to TSS
            (bool ok,) = payable(tssAddress).call{ value: amount }("");
            if (!ok) revert Errors.DepositFailed();
        } else {
            // Handle ERC20 token deposit to Vault.
            // Balance-before/after check rejects fee-on-transfer tokens: if the Vault receives
            // fewer tokens than `amount`, accounting/rate-limiting upstream would be wrong and
            // the revert/rescue paths would later break.
            if (tokenToLimitThreshold[token] == 0) revert Errors.NotSupported();
            uint256 balBefore = IERC20(token).balanceOf(vault);
            IERC20(token).safeTransferFrom(_msgSender(), vault, amount);
            uint256 received = IERC20(token).balanceOf(vault) - balBefore;
            if (received != amount) revert Errors.InvalidAmount();
        }
    }

    /// @dev                    Enforce per-block USD budget for GAS routes.
    ///                         blockUsdCap is denominated in USD(1e18). When 0, the feature is disabled.
    ///                         Resets the window when a new block is observed.
    /// @dev                    Accumulates raw native wei per block and converts the
    ///                         running total to USD at the current oracle price on each check.
    ///                         This avoids summing USD values computed from different oracle rounds
    ///                         within the same block (mixed-price accounting).
    /// @param amountWei        Native amount (in wei) to account against the current block's USD budget
    function _checkBlockUSDCap(uint256 amountWei) private {
        uint256 cap = blockUsdCap;
        if (cap == 0) return;

        if (block.number != _lastBlockNumber) {
            _lastBlockNumber = block.number;
            _consumedWeiInBlock = 0;
        }

        uint256 newWei = _consumedWeiInBlock + amountWei;
        uint256 usdTotal = quoteEthAmountInUsd1e18(newWei);
        if (usdTotal > cap) revert Errors.BlockCapLimitExceeded();

        _consumedWeiInBlock = newWei;
    }

    /// @dev                    Enforce and consume the per-token epoch rate limit.
    ///                         For a token, if threshold is 0, it is unsupported.
    ///                         epoch.used is reset to 0 when a new epoch starts (no rollover).
    /// @param token            Token address to consume rate limit
    /// @param amount           Amount of token to consume rate limit
    function _consumeRateLimit(address token, uint256 amount) private {
        uint256 threshold = tokenToLimitThreshold[token];
        if (threshold == 0) revert Errors.NotSupported();

        uint256 _epochDuration = epochDurationSec;
        if (_epochDuration == 0) revert Errors.InvalidData();

        uint64 current = uint64(block.timestamp / _epochDuration);
        EpochUsage storage e = _usage[token];

        if (e.epoch != current) {
            e.epoch = current;
            e.used = 0;
        }

        unchecked {
            uint256 newUsed = uint256(e.used) + amount; // natural units
            if (newUsed > threshold) revert Errors.RateLimitExceeded();
            e.used = uint192(newUsed);
        }
    }

    /// @dev                    Swap any ERC20 to native via a direct Uniswap v3 pool to WETH.
    ///                         - If tokenIn == WETH: unwrap to native and return.
    ///                         - Else: swap via exactInputSingle, unwrap, return ETH out.
    ///                         - Slippage and deadline are enforced; caps are enforced elsewhere.
    ///                         - If deadline == 0, replaced with block.timestamp + defaultSwapDeadlineSec.
    /// @param tokenIn          ERC-20 being paid as gas token
    /// @param amountIn         Amount of tokenIn to pull and swap
    /// @param amountOutMinETH  Min acceptable native (ETH) out (slippage bound)
    /// @param deadline         Swap deadline
    /// @return ethOut          Native ETH received
    function _swapToNative(address tokenIn, uint256 amountIn, uint256 amountOutMinETH, uint256 deadline)
        internal
        returns (uint256 ethOut)
    {
        if (amountOutMinETH == 0) revert Errors.InvalidAmount();
        // If caller passed 0, use the contract's default window; else enforce it's in the future
        if (deadline == 0) {
            deadline = block.timestamp + defaultSwapDeadlineSec;
        } else if (deadline < block.timestamp) {
            revert Errors.SlippageExceededOrExpired();
        }
        if (address(uniV3Router) == address(0) || address(uniV3Factory) == address(0)) revert Errors.InvalidInput();

        if (tokenIn == weth) {
            // Fast-path: pull WETH from user and unwrap to native
            IERC20(weth).safeTransferFrom(_msgSender(), address(this), amountIn);

            uint256 balanceBeforeUnwrap = address(this).balance;
            IWETH(weth).withdraw(amountIn);
            ethOut = address(this).balance - balanceBeforeUnwrap;

            // Slippage bound still applies for a consistent interface (caller can set to amountIn)
            if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
            return ethOut;
        }
        (IUniswapV3Pool pool, uint24 fee) = _findV3PoolWithNative(tokenIn);

        // Reject fee-on-transfer tokens: if the gateway receives fewer tokens than amountIn,
        // the subsequent allowance/swap will operate on a mismatched amount and the router pull
        // will fail.
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) - balBefore != amountIn) revert Errors.InvalidAmount();
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV3Router), amountIn);

        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: weth,
            fee: fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinETH,
            sqrtPriceLimitX96: 0
        });

        uint256 wethOut = uniV3Router.exactInputSingle(params);

        IERC20(tokenIn).forceApprove(address(uniV3Router), 0);

        uint256 balanceBeforeSwapUnwrap = address(this).balance;
        IWETH(weth).withdraw(wethOut);
        ethOut = address(this).balance - balanceBeforeSwapUnwrap;

        // Defensive: enforce the bound again after unwrap
        if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
    }

    /// @dev                    Find the best-fee direct v3 pool between tokenIn and WETH.
    ///                         Scans v3FeeOrder and returns the first existing pool.
    /// @param tokenIn          ERC-20 to find a pool for
    /// @return pool            The Uniswap V3 pool contract
    /// @return fee             The fee tier of the pool
    function _findV3PoolWithNative(address tokenIn) internal view returns (IUniswapV3Pool pool, uint24 fee) {
        if (tokenIn == address(0) || weth == address(0)) revert Errors.ZeroAddress();

        // Try fee tiers in the configured order
        for (uint256 i = 0; i < v3FeeOrder.length; i++) {
            uint24 tier = v3FeeOrder[i];
            address p = IUniswapV3Factory(uniV3Factory).getPool(tokenIn, weth, tier);
            if (p != address(0)) {
                return (IUniswapV3Pool(p), tier);
            }
        }
        revert Errors.InvalidInput();
    }

    // ==============================
    //  UG_6: VALIDATION & ROUTING
    // ==============================

    /// @dev                    Infers the TX_TYPE from the request's four decision variables:
    ///                         hasPayload, hasFunds, fundsIsNative, hasNativeValue.
    /// @param req              UniversalTxRequest struct
    /// @param nativeValue      Effective native value (msg.value or swapped amount)
    /// @return inferred        The inferred TX_TYPE for routing
    function _fetchTxType(UniversalTxRequest memory req, uint256 nativeValue) private pure returns (TX_TYPE inferred) {
        bool hasPayload = req.payload.length > 0;
        bool hasFunds = req.amount > 0;
        bool fundsIsNative = (req.token == address(0));
        bool hasNativeValue = nativeValue > 0;

        // For TX_TYPE.GAS:
        //  - pure gas top-up (no payload, no funds, nativeValue > 0)
        if (!hasPayload && !hasFunds && hasNativeValue) {
            return TX_TYPE.GAS;
        }
        // For TX_TYPE.GAS_AND_PAYLOAD:
        //  - payload present
        //  - no funds
        //  - nativeValue MAY be 0 (payload-only) or > 0 (payload + gas)
        if (hasPayload && !hasFunds) {
            return TX_TYPE.GAS_AND_PAYLOAD;
        }

        // For TX_TYPE.FUNDS: Case 1: Native Funds
        if (!hasPayload && hasFunds) {
            // Case 1.1: Native Funds Only.
            // FUNDS (native) — must come with native value
            if (fundsIsNative && hasNativeValue) {
                return TX_TYPE.FUNDS;
            }
            // Case 1.2: ERC-20 Funds Only.
            // FUNDS (ERC-20) — native value may be 0 (no fee) or equal to inboundFee
            // The exact native amount is validated post-fee-extraction in _sendTxWithFunds
            if (!fundsIsNative) {
                return TX_TYPE.FUNDS;
            }
            revert Errors.InvalidInput();
        }

        // For TX_TYPE.FUNDS_AND_PAYLOAD: Case 2: (Native/ERC20 Funds) + Payload
        if (hasPayload && hasFunds) {
            // Case 2.1: No batching (ERC-20 funds, user already has UEA gas)
            // Native value may be 0 (no fee) or equal to inboundFee; resolved post-fee in _sendTxWithFunds
            if (!fundsIsNative) {
                return TX_TYPE.FUNDS_AND_PAYLOAD;
            }
            // Case 2.2: Batching: native funds + native gas (later we enforce nativeValue >= amount)
            if (fundsIsNative && hasNativeValue) {
                return TX_TYPE.FUNDS_AND_PAYLOAD;
            }
            revert Errors.InvalidInput();
        }

        revert Errors.InvalidInput();
    }

    /// @dev                    Extract the protocol fee from the native value and forward it to TSS.
    ///                         Called before routing so downstream functions see the post-fee value.
    /// @param nativeValue      Raw native value received with the transaction
    /// @return adjustedNative  nativeValue minus the collected fee
    /// @return feeCollected    Amount forwarded to TSS as the protocol fee
    function _collectInboundFee(uint256 nativeValue) private returns (uint256 adjustedNative, uint256 feeCollected) {
        uint256 fee = inboundFee;
        if (fee == 0) return (nativeValue, 0);

        // Every tx must supply at least inboundFee in native
        if (nativeValue < fee) revert Errors.InsufficientProtocolFee();

        // Forward fee to TSS
        (bool ok,) = payable(tssAddress).call{ value: fee }("");
        if (!ok) revert Errors.DepositFailed();

        return (nativeValue - fee, fee);
    }

    /// @dev                    Internal router that dispatches to the appropriate handler based on TX_TYPE.
    ///                         TX_TYPE inference is performed AFTER fee deduction so that the inferred
    ///                         type matches the effective native value used by downstream handlers.
    /// @param req              UniversalTxRequest struct
    /// @param caller           Caller address
    /// @param nativeValue      Native value (msg.value or swap output)
    /// @param fromCEA          True if called via sendUniversalTxFromCEA
    function _routeUniversalTx(UniversalTxRequest memory req, address caller, uint256 nativeValue, bool fromCEA)
        internal
    {
        // Sanity Check : revertRecipient is not address(0)
        if (req.revertRecipient == address(0)) {
            revert Errors.InvalidRecipient();
        }

        // Skip protocol fee for CEA path — fees already paid on Push Chain
        if (!fromCEA) {
            uint256 feeCollected;
            (nativeValue, feeCollected) = _collectInboundFee(nativeValue);
            totalProtocolFeesCollected += feeCollected;
        }

        TX_TYPE txType = _fetchTxType(req, nativeValue);

        // PC20 early exit: if token is a PC20 wrapper, route to burn path
        if (_isPC20Wrapper(req.token)) {
            _routePC20Tx(req, caller, nativeValue, fromCEA);
            return;
        }

        // Prefix payload with PRC_20_SELECTOR so Push Chain can distinguish
        // PRC20 transactions from PC20 transactions (PC20 path returns above).
        req.payload = abi.encodePacked(PRC_20_SELECTOR, req.payload);

        // Route 1: GAS or GAS_AND_PAYLOAD → Instant route
        if (txType == TX_TYPE.GAS || txType == TX_TYPE.GAS_AND_PAYLOAD) {
            // address(0) recipient: Push Chain attributes funds to the sender's UEA
            address gasRecipient = fromCEA ? req.recipient : address(0);
            _sendTxWithGas(
                txType, caller, gasRecipient, nativeValue, req.payload, req.revertRecipient, req.signatureData, fromCEA
            );
        }
        // Route 2: FUNDS or FUNDS_AND_PAYLOAD → Standard route
        else if (txType == TX_TYPE.FUNDS || txType == TX_TYPE.FUNDS_AND_PAYLOAD) {
            _sendTxWithFunds(req, nativeValue, txType, fromCEA);
        }
        // Route 3: Invalid.
        // Defensive: unreachable under the current _fetchTxType logic (which either returns one of
        // GAS / GAS_AND_PAYLOAD / FUNDS / FUNDS_AND_PAYLOAD, or reverts). Kept as an invariant guard
        // against future TX_TYPE enum additions or _fetchTxType refactors that could silently drop
        // a case.
        else {
            revert Errors.InvalidTxType();
        }
    }

    // ==============================
    //      RECEIVE / FALLBACK
    // ==============================

    /// @dev Reject plain ETH; only accept ETH via explicit deposit functions or WETH unwrapping.
    receive() external payable {
        // Allow WETH unwrapping; block unexpected sends.
        if (msg.sender != weth) revert Errors.DepositFailed();
    }
}
