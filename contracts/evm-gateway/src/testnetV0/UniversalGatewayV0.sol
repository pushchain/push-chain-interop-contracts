// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGatewayV0
 * @notice Universal Gateway for EVM chains [TESTNETs Only]
 *         - Acts as a gateway for all supported external chains to bridge funds and payloads to Push Chain.
 *         - Users of external chains can deposit funds and payloads to Push Chain using the gateway.
 *
 * @dev    - Transaction Types: 4 main types of transactions supported by gateway:
 *         -    1. GAS_TX: Allows users to fund their UEAs ( on Push Chain ) with gas deposits from source chains.
 *         -    2. GAS_AND_PAYLOAD_TX: Allows users to fund their UEAs with gas deposits from source chains and execute payloads through their UEAs on Push Chain.
 *         -    3. FUNDS_TX: Allows users to move large ticket-size funds from to any recipient address on Push Chain.
 *         -    4. FUNDS_AND_PAYLOAD_TX: Allows users to move large ticket-size funds from to any recipient address on Push Chain and execute payloads through their UEAs on Push Chain.
 *         - Note: Check the ./libraries/Types.sol file for more details on transaction types.
 *
 * @dev    - TSS-controlled functionalities:
 *         -    1. Token Support List: allowlist for ERC20 used as gas inputs on gas tx path.
 *         - Note: Fund management and access control is managed by TSS_ROLE.
 *
 * @dev    - Rate-Limit Checks:
 *         -    Universal Gateway includes rate-limit checks for both Fee Abstraction & Universal Transaction Routes.
 *         -    For Fee Abstraction Route ( Low Block Confirmation Requirement ):
 *               - Includes _checkUSDCaps: USD cap checks for the deposit amount. Must be within MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
 *               - Includes _checkBlockUSDCap: Block-based USD cap checks. Must be within BLOCK_USD_CAP.
 *         -    For Universal Transaction Route ( Standard Block Confirmation Requirement ):
 *               - Includes _consumeRateLimit: Consume the per-token epoch rate limit.
 *                     - Every supported token has a per-token epoch limit threshold.
 *                     - New Epoch resets the usage limit threshold of a given token.
 *               - Includes _checkUSDCaps and _checkBlockUSDCap for _sendTxWithGas function called internally.
 *         - Note: Check the ./interfaces/IUniversalGateway.sol file for more details on rate-limit checks.
 *
 * @dev    - Chainlink Oracle is used for ETH/USD price feed.
 */

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Errors } from "../libraries/Errors.sol";
import { IUniversalGatewayV0 } from "./interfaces/IUniversalGatewayV0.sol";

import { RevertInstructions, TX_TYPE, EpochUsage } from "../libraries/Types.sol";
import { UniversalTxRequest, UniversalTokenTxRequest } from "../libraries/TypesUG.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { ISwapRouterSepolia } from "./interfaces/ISwapRouterSepolia.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { ICEAFactory } from "../interfaces/ICEAFactory.sol";

contract UniversalGatewayV0 is
    Initializable,
    ContextUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IUniversalGatewayV0
{
    using SafeERC20 for IERC20;

    // =========================
    //           ROLES
    // =========================
    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // =========================
    //            STATE
    // =========================

    /// @notice The current TSS address (receives native from universal-tx deposits)
    address public TSS_ADDRESS;

    /// @notice USD caps for universal tx deposits (1e18 = $1)
    uint256 public MIN_CAP_UNIVERSAL_TX_USD; // inclusive lower bound = 1USD = 1e18
    uint256 public MAX_CAP_UNIVERSAL_TX_USD; // inclusive upper bound = 10USD = 10e18

    /// @notice Token whitelist for BRIDGING (assets locked in this contract)
    mapping(address => bool) public _isSupportedToken; // Deprecated - Use tokenToLimitThreshold instead

    /// @notice Uniswap V3 factory & router (chain-specific)
    IUniswapV3Factory public uniV3Factory;
    ISwapRouterSepolia public uniV3Router;
    address public WETH;
    uint24[3] public v3FeeOrder;

    /// @notice Chainlink ETH/USD oracle config
    AggregatorV3Interface public ethUsdFeed;
    uint8 public chainlinkEthUsdDecimals;
    uint256 public chainlinkStalePeriod;

    /// @notice (Optional) Chainlink L2 Sequencer uptime feed & grace period for rollups
    AggregatorV3Interface public l2SequencerFeed; // if set, enforce sequencer up + grace
    uint256 public l2SequencerGracePeriodSec; // e.g., 300 seconds

    /// @notice Default additional time window used when callers pass deadline = 0 (Uniswap v3 swaps)
    uint256 public defaultSwapDeadlineSec;

    /// @notice USDT token address (kept for storage layout compatibility)
    address public USDT;
    /// @notice Pool fee for WETH/USDT swap (kept for storage layout compatibility)
    uint24 public POOL_FEE;
    /// @notice USDT/USD price feed (kept for storage layout compatibility)
    AggregatorV3Interface public usdtUsdPriceFeed;

    /// @notice Per-block cap for total USD value spend on GAS routes (1e18 = $1). 0 disables.
    uint256 public BLOCK_USD_CAP;
    /// @dev Two-scalar accounting for block-based USD cap checks
    uint256 private _lastBlockNumber;
    uint256 private _consumedUSDinBlock;
    uint256 public epochDurationSec; // Epoch duration in seconds.
    mapping(address => uint256) public tokenToLimitThreshold; // Per-token epoch limit thresholds.
    mapping(address => EpochUsage) private _usage; // Current-epoch usage per token (address(0) represents native).

    /// @notice Map to track if a payload has been executed
    mapping(bytes32 => bool) public isExecuted;

    // Storage gap: reduced from 40 to 38 to accommodate VAULT and CEA_FACTORY below.
    uint256[38] private __gap;

    // New state appended after gap (upgrade-safe)
    /// @notice The Vault contract address on this chain
    address public VAULT;
    /// @notice CEAFactory address for CEA identity validation
    address public CEA_FACTORY;

    /// @notice Flat protocol fee in native token (wei). 0 = disabled.
    uint256 public INBOUND_FEE;

    /// @notice Running total of protocol fees collected (native, in wei).
    uint256 public totalProtocolFeesCollected;

    // =====================================================
    //                    INITIALIZER
    // =====================================================
    /**
     * @notice Initialize the UniversalGateway contract
     * @param admin            DEFAULT_ADMIN_ROLE holder
     * @param pauser           PAUSER_ROLE
     * @param tss              initial TSS address
     * @param minCapUsd        min USD cap (1e18 decimals)
     * @param maxCapUsd        max USD cap (1e18 decimals)
     * @param factory          UniswapV3 factory
     * @param router           UniswapV3 router
     * @param _wethAddress     WETH address
     * @param _usdtAddress     USDT address
     * @param _usdtUsdPriceFeed USDT/USD price feed
     * @param _ethUsdPriceFeed ETH/USD price feed
     */
    function initialize(
        address admin,
        address pauser,
        address tss,
        uint256 minCapUsd,
        uint256 maxCapUsd,
        address factory,
        address router,
        address _wethAddress,
        address _usdtAddress,
        address _usdtUsdPriceFeed,
        address _ethUsdPriceFeed
    ) external initializer {
        if (admin == address(0) || pauser == address(0) || tss == address(0) || _wethAddress == address(0)) revert Errors.ZeroAddress();

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(TSS_ROLE, tss);

        TSS_ADDRESS = tss;
        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;

        WETH = _wethAddress;
        v3FeeOrder = [uint24(500), uint24(3000), uint24(10000)];
        POOL_FEE = 3000;
        if (factory != address(0) && router != address(0)) {
            uniV3Factory = IUniswapV3Factory(factory);
            uniV3Router = ISwapRouterSepolia(router);
        }
        // Default swap deadline window (industry common ~10 minutes)
        defaultSwapDeadlineSec = 10 minutes;

        // Set a sane default for Chainlink staleness (can be tuned by admin)
        chainlinkStalePeriod = 1 hours;
        usdtUsdPriceFeed = AggregatorV3Interface(_usdtUsdPriceFeed);
        ethUsdFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        USDT = _usdtAddress;
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    // =========================
    //    UG_1: ADMIN ACTIONS
    // =========================
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Allows the admin to set the TSS address
    /// @param newTSS The new TSS address
    function setTSS(address newTSS) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTSS == address(0)) revert Errors.ZeroAddress();
        address old = TSS_ADDRESS;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTSS);

        TSS_ADDRESS = newTSS;
    }

    /// @notice Allows the admin to set the Vault address and grant VAULT_ROLE
    /// @param newVault The new Vault address
    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newVault == address(0)) revert Errors.ZeroAddress();
        address old = VAULT;
        VAULT = newVault;
        _grantRole(VAULT_ROLE, newVault);
        if (old != address(0)) _revokeRole(VAULT_ROLE, old);
        emit VaultUpdated(old, newVault);
    }

    /// @notice Allows the admin to set the CEAFactory address
    /// @param newFactory The new CEAFactory address
    function setCEAFactory(address newFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFactory == address(0)) revert Errors.ZeroAddress();
        CEA_FACTORY = newFactory;
    }

    /// @notice         Set the flat protocol fee (in wei). Set to 0 to disable.
    /// @param fee      New protocol fee in wei
    function setInboundFee(uint256 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        INBOUND_FEE = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @notice Allows the admin to set the USD cap ranges
    /// @param minCapUsd The minimum USD cap
    /// @param maxCapUsd The maximum USD cap
    function setCapsUSD(uint256 minCapUsd, uint256 maxCapUsd) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (minCapUsd > maxCapUsd) revert Errors.InvalidCapRange();

        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;
        emit CapsUpdated(minCapUsd, maxCapUsd);
    }

    /// @notice             Set the per-block USD cap for GAS routes (1e18 = $1). Set to 0 to disable.
    function setBlockUsdCap(uint256 cap1e18) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        BLOCK_USD_CAP = cap1e18;
    }

    /// @notice Set the default swap deadline window (used when a caller passes deadline = 0)
    /// @param deadlineSec Number of seconds to add to block.timestamp when defaulting the deadline
    function setDefaultSwapDeadline(uint256 deadlineSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (deadlineSec == 0) revert Errors.InvalidAmount();
        defaultSwapDeadlineSec = deadlineSec;
    }

    /// @notice Allows the admin to set the Uniswap V3 factory and router
    /// @param factory The new Uniswap V3 factory address
    /// @param router The new Uniswap V3 router address
    function setRouters(address factory, address router) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (factory == address(0) || router == address(0)) revert Errors.ZeroAddress();
        uniV3Factory = IUniswapV3Factory(factory);
        uniV3Router = ISwapRouterSepolia(router);
    }

    /// @notice             Set limit thresholds for a batch of tokens (0 disables support for that token)
    /// @param tokens       tokens to set limit thresholds for
    /// @param thresholds   limit thresholds for the tokens
    function setTokenLimitThresholds(address[] calldata tokens, uint256[] calldata thresholds)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (tokens.length != thresholds.length) revert Errors.InvalidInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenToLimitThreshold[tokens[i]] = thresholds[i];
            emit TokenLimitThresholdUpdated(tokens[i], thresholds[i]);
        }
    }

    /// @notice               Update the epoch duration (hard reset schedule)
    /// @param newDurationSec new epoch duration
    function updateEpochDuration(uint256 newDurationSec) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = epochDurationSec;
        epochDurationSec = newDurationSec;
        emit EpochDurationUpdated(old, newDurationSec);
    }

    /// @notice Allows the admin to set the fee order for the Uniswap V3 router
    /// @param a The new fee order
    /// @param b The new fee order
    /// @param c The new fee order
    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        v3FeeOrder = [a, b, c];
    }

    /// @notice Set the Chainlink ETH/USD feed (and cache its decimals)
    function setEthUsdFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (feed == address(0)) revert Errors.ZeroAddress();
        AggregatorV3Interface f = AggregatorV3Interface(feed);
        // Will revert if not a contract or not a valid aggregator when decimals() is called by non-aggregator contracts.
        uint8 dec = f.decimals();
        ethUsdFeed = f;
        chainlinkEthUsdDecimals = dec;
    }

    /// @notice Configure the maximum allowed data staleness for Chainlink reads
    /// @param stalePeriodSec If > 0, latestRoundData().updatedAt must be within this many seconds
    function setChainlinkStalePeriod(uint256 stalePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        chainlinkStalePeriod = stalePeriodSec;
    }

    /// @notice Set (or clear) the Chainlink L2 sequencer uptime feed for rollups
    /// @dev    Set to address(0) on L1s / chains without a sequencer feed.
    function setL2SequencerFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerFeed = AggregatorV3Interface(feed);
    }

    /// @notice Configure the grace window after sequencer comes back up
    /// @param gracePeriodSec If > 0, require `block.timestamp - sequencer.updatedAt > gracePeriodSec`
    function setL2SequencerGracePeriod(uint256 gracePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerGracePeriodSec = gracePeriodSec;
    }

    // =========================
    //  UG_2: UNIVERSAL TRANSACTION
    // =========================

    //
    function sendUniversalTx(UniversalTxRequest calldata req) external payable nonReentrant whenNotPaused {
        if (_isCallerCEA()) revert Errors.InvalidInput();
        uint256 nativeValue = msg.value;
        TX_TYPE txType = _fetchTxType(req, nativeValue);
        _routeUniversalTx(req, _msgSender(), nativeValue, txType, false);
    }

    function sendUniversalTx(UniversalTokenTxRequest calldata reqToken) external payable nonReentrant whenNotPaused {
        if (_isCallerCEA()) revert Errors.InvalidInput();
        if (reqToken.gasToken == address(0)) revert Errors.InvalidInput();
        if (reqToken.gasAmount == 0) revert Errors.InvalidAmount();
        if (reqToken.amountOutMinETH == 0) revert Errors.InvalidAmount();
        if (reqToken.deadline != 0 && reqToken.deadline < block.timestamp) revert Errors.SlippageExceededOrExpired();

        // Swap token to native
        uint256 nativeValue =
            swapToNative(reqToken.gasToken, reqToken.gasAmount, reqToken.amountOutMinETH, reqToken.deadline);

        // Build UniversalTxRequest from token request
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: reqToken.recipient,
            token: reqToken.token,
            amount: reqToken.amount,
            payload: reqToken.payload,
            revertRecipient: reqToken.revertRecipient,
            signatureData: reqToken.signatureData
        });

        TX_TYPE txType = _fetchTxType(req, nativeValue);
        _routeUniversalTx(req, _msgSender(), nativeValue, txType, false);
    }

    /// @notice                Initiate a Universal Transaction from a CEA (Chain Execution Account).
    /// @dev                   Validates CEA identity via CEAFactory, resolves the mapped UEA, and routes
    ///                        directly to _routeUniversalTx with fromCEA=true.
    ///                        req.recipient MUST equal the CEA's mapped UEA (anti-spoof).
    /// @param req             UniversalTxRequest struct
    function sendUniversalTxFromCEA(UniversalTxRequest calldata req) external payable nonReentrant whenNotPaused {
        if (CEA_FACTORY == address(0)) revert Errors.InvalidInput();
        if (!_isCallerCEA()) revert Errors.InvalidInput();

        address mappedUEA = ICEAFactory(CEA_FACTORY).getPushAccountForCEA(_msgSender());
        if (mappedUEA == address(0)) revert Errors.InvalidInput();

        if (req.recipient != mappedUEA) revert Errors.InvalidRecipient();

        uint256 nativeValue = msg.value;
        TX_TYPE txType = _fetchTxType(req, nativeValue);
        _routeUniversalTx(req, _msgSender(), nativeValue, txType, true);
    }

    // =========================
    //  UG_2.1: UNIVERSAL TRANSACTION Internal Helpers
    // =========================

    /// @notice                     Internal helper function to deposit for Instant TX.
    /// @dev                        Handles rate-limit checks for Fee Abstraction Tx Route
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
            // performs rate-limit checks and handle deposit
            //_checkUSDCaps(_gasAmount);
            //_checkBlockUSDCap(_gasAmount);
            _handleDeposits(address(0), _gasAmount);
        }

        _emitUniversalTx( // recipient as address(0) -> UEA.
            _caller,
            _recipient,
            address(0),
            _gasAmount,
            _payload,
            _revertRecipient,
            _txType,
            _signatureData,
            _fromCEA
        );
    }

    /// @notice                     Internal helper function to deposit for TX_TYPE.FUNDS or TX_TYPE.FUNDS_AND_PAYLOAD
    /// @dev                        Handles rate-limit checks for Universal Tx Route ( Higher Block Confirmations )
    /// @dev                        Recipient address(0) indicates the funds are attributed to the caller's UEA on Push Chain.
    /// @param _req                 UniversalTxRequest struct
    /// @param nativeValue          Native value ( msg.value )
    /// @param txType               TX_TYPE.FUNDS or TX_TYPE.FUNDS_AND_PAYLOAD
    function _sendTxWithFunds(UniversalTxRequest memory _req, uint256 nativeValue, TX_TYPE txType, bool fromCEA)
        private
    {
        // Case 1: For TX_TYPE = FUNDS

        if (txType == TX_TYPE.FUNDS) {
            address tokenForFunds;
            // Case 1.1: Token to bridge is Native Token -> address(0)
            // req.amount = desired bridge amount (fee is additive: msg.value = req.amount + INBOUND_FEE).
            // nativeValue is post-fee (= msg.value - INBOUND_FEE = req.amount).
            if (_req.token == address(0)) {
                if (_req.amount != nativeValue) revert Errors.InvalidAmount();
                tokenForFunds = address(0);
            }
            // Case 1.2: Token to bridge is ERC20 Token -> _req.token
            // Post-fee nativeValue is routed as a gas top-up (e.g. from swapToNative or batched native).
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

            //_consumeRateLimit(tokenForFunds, _req.amount);
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
            else if (_req.token != address(0)) {
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

            //_consumeRateLimit(tokenForFundsAndPayload, _req.amount);
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

    /// @notice                    Internal helper function to emit the UniversalTx event
    /// @param sender              Sender address
    /// @param recipient           Recipient address
    /// @param token               Token address
    /// @param amount              Amount
    /// @param payload             Payload
    /// @param revertRecipient     Revert recipient address
    /// @param txType              TX_TYPE
    /// @param signatureData       Signature data
    /// @param fromCEA             True if the tx originated from a CEA
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

    // =========================
    //  UG_3: REVERT HANDLING PATHS
    // =========================

    /// @inheritdoc IUniversalGatewayV0
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

    /// @inheritdoc IUniversalGatewayV0
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

    function _validateRevertParams(bytes32 subTxId, uint256 amount, address token, address revertRecipient) private {
        if (isExecuted[subTxId]) revert Errors.PayloadExecuted();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0 || (token == address(0) && msg.value != amount)) revert Errors.InvalidAmount();

        isExecuted[subTxId] = true;
    }

    // =========================
    //  UG_4: PUBLIC HELPERS
    // =========================

    /// @notice             Checks if a token is supported by the gateway.
    /// @param token        Token address to check
    /// @return             True if the token is supported, false otherwise
    //
    function isSupportedToken(address token) public view returns (bool) {
        return tokenToLimitThreshold[token] != 0;
    }

    /// @notice Computes the minimum and maximum deposit amounts in native ETH (wei) implied by the USD caps.
    /// @dev    Uses the current ETH/USD price from {getEthUsdPrice}.
    /// @return minValue Minimum native amount (in wei) allowed by MIN_CAP_UNIVERSAL_TX_USD
    /// @return maxValue Maximum native amount (in wei) allowed by MAX_CAP_UNIVERSAL_TX_USD
    function getMinMaxValueForNative() public view returns (uint256 minValue, uint256 maxValue) {
        (uint256 ethUsdPrice,) = getEthUsdPrice(); // ETH price in USD (1e18 scaled)

        // Convert USD caps to ETH amounts
        // Formula: ETH_amount = (USD_cap * 1e18) / ETH_price_in_USD
        minValue = (MIN_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
        maxValue = (MAX_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
    }

    /// @notice Returns the ETH/USD price scaled to 1e18 (i.e., USD with 18 decimals).
    /// @dev Reads Chainlink AggregatorV3, applies safety checks,
    ///      then rescales from the feed's native decimals (typically 8) to 1e18.
    ///      - Output units:
    ///          • price1e18 = USD(1e18) per 1 ETH. Example: if ETH = $4,400, returns 4_400 * 1e18.
    ///      - Also returns the raw Chainlink feed decimals for observability.
    /// @return price1e18 ETH price in USD scaled to 1e18 (USD with 18 decimals)
    /// @return chainlinkDecimals The decimals of the underlying Chainlink feed (e.g., 8)
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

        // This can happen if the feed wasn't properly initialized or returns 0 decimals
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

    /// @notice Converts an ETH amount (in wei) to USD with 18 decimals via Chainlink price.
    /// @dev Uses getEthUsdPrice which returns USD(1e18) per ETH and computes:
    ///         usd1e18 = (amountWei * price1e18) / 1e18.
    /// @param amountWei Amount of ETH in wei to convert
    /// @return usd1e18 USD value scaled to 1e18
    function quoteEthAmountInUsd1e18(uint256 amountWei) public view returns (uint256 usd1e18) {
        if (amountWei == 0) return 0;
        (uint256 px1e18,) = getEthUsdPrice(); // will validate freshness and positivity
        // USD(1e18) = (amountWei * px1e18) / 1e18
        // Note: amountWei is 1e18-based (wei), price is scaled to 1e18 above.
        usd1e18 = (amountWei * px1e18) / 1e18;
    }

    /// @notice             Returns both the total token amount used and remaining in the current epoch.
    /// @param token        token address to query (use address(0) for native)
    /// @return used        amount already consumed in the current epoch (in token's natural units)
    /// @return remaining   amount still available to send in this epoch (0 if exceeded or unsupported)
    function currentTokenUsage(address token) external view returns (uint256 used, uint256 remaining) {
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

    // =========================
    //       INTERNAL HELPERS
    // =========================

    /// @dev Check if the amount is within the USD cap range
    ///      Cap Ranges are defined in the constructor or can be updated by the admin.
    /// @param amount Amount to check
    function _checkUSDCaps(uint256 amount) public view {
        uint256 usdValue = quoteEthAmountInUsd1e18(amount);
        if (usdValue < MIN_CAP_UNIVERSAL_TX_USD) revert Errors.InvalidAmount();
        if (usdValue > MAX_CAP_UNIVERSAL_TX_USD) revert Errors.InvalidAmount();
    }

    /// @dev                Handle deposits of native ETH or ERC20 tokens
    ///                     If token is address(0): Forward native ETH to TSS
    ///                     Otherwise: Transfer ERC20 to VAULT for custody
    /// @param token        token address (address(0) for native ETH)
    /// @param amount       amount to deposit
    function _handleDeposits(address token, uint256 amount) internal {
        if (token == address(0)) {
            // Handle native ETH deposit to TSS
            (bool ok,) = payable(TSS_ADDRESS).call{ value: amount }("");
            if (!ok) revert Errors.DepositFailed();
        } else {
            // Handle ERC20 token deposit to Vault
            if (tokenToLimitThreshold[token] == 0) revert Errors.NotSupported();
            IERC20(token).safeTransferFrom(_msgSender(), VAULT, amount);
        }
    }

    /// @dev                Enforce per-block USD budget for GAS routes using two-scalar accounting.
    ///                     - `BLOCK_USD_CAP` is denominated in USD(1e18). When 0, the feature is disabled.
    ///                     - Resets the window when a new block is observed.
    /// @param amountWei    native amount (in wei) to be accounted against the current block's USD budget
    function _checkBlockUSDCap(uint256 amountWei) private {
        uint256 cap = BLOCK_USD_CAP;
        if (cap == 0) return;

        if (block.number != _lastBlockNumber) {
            _lastBlockNumber = block.number;
            _consumedUSDinBlock = 0;
        }

        uint256 usd1e18 = quoteEthAmountInUsd1e18(amountWei);

        if (usd1e18 > cap) revert Errors.BlockCapLimitExceeded();

        unchecked {
            uint256 newUsed = _consumedUSDinBlock + usd1e18;
            if (newUsed > cap) revert Errors.BlockCapLimitExceeded();
            _consumedUSDinBlock = newUsed;
        }
    }

    /// @dev                Enforce and consume the per-token epoch rate limit.
    ///                     For a token, if threshold is 0, it is unsupported.
    ///                     epoch.used is reset to 0 when a new epoch starts (no rollover).
    /// @param token        token address to consume rate limit
    /// @param amount       amount of token to consume rate limit
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

    /// @dev Swap any ERC-20 to the chain's native token via a direct Uniswap v3 pool to WETH.
    ///      - If tokenIn == WETH: unwrap to native and return.
    ///      - Else: require a direct tokenIn/WETH v3 pool, swap via exactInputSingle, unwrap, return ETH out.
    ///      - No price/cap logic here; slippage and deadline are enforced; caps are enforced elsewhere.
    ///      - If `deadline == 0`, it is replaced with `block.timestamp + defaultSwapDeadlineSec`.
    /// @param tokenIn           ERC-20 being paid as "gas token"
    /// @param amountIn          amount of tokenIn to pull and swap
    /// @param amountOutMinETH   min acceptable native (ETH) out (slippage bound)
    /// @param deadline          swap deadline
    /// @return ethOut           native ETH received
    function swapToNative(address tokenIn, uint256 amountIn, uint256 amountOutMinETH, uint256 deadline)
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

        if (tokenIn == WETH) {
            // Fast-path: pull WETH from user and unwrap to native
            IERC20(WETH).safeTransferFrom(_msgSender(), address(this), amountIn);

            uint256 balBefore = address(this).balance;
            IWETH(WETH).withdraw(amountIn);
            ethOut = address(this).balance - balBefore;

            // Slippage bound still applies for a consistent interface (caller can set to amountIn)
            if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
            return ethOut;
        }

        // Find a direct tokenIn/WETH pool; revert if none
        (IUniswapV3Pool pool, uint24 fee) = _findV3PoolWithNative(tokenIn);
        // 'pool' is only used as existence proof; swap goes via router using 'fee'

        // Pull tokens and grant router allowance
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV3Router), amountIn);

        // Swap tokenIn -> WETH with exactInputSingle and slippage check
        ISwapRouterSepolia.ExactInputSingleParams memory params = ISwapRouterSepolia.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: fee,
            recipient: address(this),
            // deadline: deadline, NOT FOR SEPOLIA
            amountIn: amountIn,
            amountOutMinimum: amountOutMinETH, // min WETH out, equals min ETH out after unwrap
            sqrtPriceLimitX96: 0
        });

        uint256 wethOut = uniV3Router.exactInputSingle(params);

        // Approval hygiene
        IERC20(tokenIn).forceApprove(address(uniV3Router), 0);

        // Unwrap WETH -> native and compute exact ETH out
        uint256 _balBefore = address(this).balance;
        IWETH(WETH).withdraw(wethOut);
        ethOut = address(this).balance - _balBefore;

        // Defensive: enforce the bound again after unwrap
        if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();

        // _checkUSDCaps(ethOut); // TODO: DEPRECATED FOR TESTNET
    }

    // Helper: find the best-fee direct v3 pool between tokenIn and WETH.
    // Scans v3FeeOrder (e.g., [500, 3000, 10000]) and returns the first existing pool.
    function _findV3PoolWithNative(address tokenIn) internal view returns (IUniswapV3Pool pool, uint24 fee) {
        if (tokenIn == address(0) || WETH == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == WETH) {
            // Caller should handle the WETH fast-path; we return zeroed pool/fee here.
            return (IUniswapV3Pool(address(0)), 0);
        }

        // Try fee tiers in the configured order
        for (uint256 i = 0; i < v3FeeOrder.length; i++) {
            uint24 tier = v3FeeOrder[i];
            address p = IUniswapV3Factory(uniV3Factory).getPool(tokenIn, WETH, tier);
            if (p != address(0)) {
                return (IUniswapV3Pool(p), tier);
            }
        }

        // No direct pool found
        revert Errors.InvalidInput();
    }

    /// @dev Returns true if the caller is a CEA registered with CEA_FACTORY
    function _isCallerCEA() private view returns (bool) {
        if (CEA_FACTORY == address(0)) return false;
        return ICEAFactory(CEA_FACTORY).isCEA(msg.sender);
    }

    // =========================
    //  UG_6: VALIDATION & ROUTERS for sendUniversalTx()
    // =========================

    /**
     * @notice Infers the TX_TYPE for an incoming universal request by inspecting only
     *         the four decision variables we agreed on:
     *         - hasPayload     := (req.payload.length > 0)
     *         - hasFunds       := (req.amount > 0)
     *         - fundsIsNative  := (req.token == address(0))
     *         - hasNativeValue := (nativeValue > 0)  // nativeValue = msg.value (native-gas) OR swapped amount (token-gas)
     *
     * @param req          UniversalTxRequest (txType field is ignored here)
     * @param nativeValue  Effective native value attached to the call path (msg.value or swapped amount)
     * @return inferred    The inferred TX_TYPE for routing
     */
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
            // FUNDS (ERC-20) — native value may be 0 (no fee) or equal to INBOUND_FEE
            // The exact native amount is validated post-fee-extraction in _sendTxWithFunds
            if (!fundsIsNative) {
                return TX_TYPE.FUNDS;
            }
            revert Errors.InvalidInput();
        }

        // For TX_TYPE.FUNDS_AND_PAYLOAD: Case 2: (Native/ERC20 Funds) + Payload
        if (hasPayload && hasFunds) {
            // Case 2.1: No batching (ERC-20 funds, user already has UEA gas)
            // Native value may be 0 (no fee) or equal to INBOUND_FEE; resolved post-fee in _sendTxWithFunds
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
    ///                         Called before routing so all downstream functions see the post-fee native value.
    ///                         For ERC20 FUNDS/FUNDS_AND_PAYLOAD (no native bridging), nativeValue must equal
    ///                         INBOUND_FEE; after extraction it will be 0.
    /// @param nativeValue      Raw native value received with the transaction
    /// @return adjustedNative  nativeValue minus the collected fee
    /// @return feeCollected    Amount forwarded to TSS as the protocol fee
    function _collectInboundFee(uint256 nativeValue) private returns (uint256 adjustedNative, uint256 feeCollected) {
        uint256 fee = INBOUND_FEE;
        if (fee == 0) return (nativeValue, 0);

        // Every tx must supply at least INBOUND_FEE in native
        if (nativeValue < fee) revert Errors.InsufficientProtocolFee();

        // Forward fee to TSS
        (bool ok,) = payable(TSS_ADDRESS).call{ value: fee }("");
        if (!ok) revert Errors.DepositFailed();

        return (nativeValue - fee, fee);
    }

    /// @dev Internal router that dispatches to the appropriate handler based on TX_TYPE
    /// @param req The universal transaction request (memory for token-gas, can accept calldata too)
    /// @param caller The original caller (msg.sender from the public function)
    /// @param nativeValue The effective native value (msg.value for native-gas, swapped amount for token-gas)
    /// @param fromCEA True if the tx originated from a CEA via sendUniversalTxFromCEA
    function _routeUniversalTx(
        UniversalTxRequest memory req,
        address caller,
        uint256 nativeValue,
        TX_TYPE txType,
        bool fromCEA
    ) internal {
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
        // Route 3: Invalid
        else {
            revert Errors.InvalidTxType();
        }
    }

    // =========================
    //         RECEIVE/FALLBACK
    // =========================
    /// @dev Reject plain ETH; we only accept ETH via explicit deposit functions or WETH unwrapping.
    receive() external payable {
        // Allow WETH unwrapping; block unexpected sends.
        if (msg.sender != WETH) revert Errors.DepositFailed();
    }
}
