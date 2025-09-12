// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGateway
 * @notice Universal Gateway for EVM chains.
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
 *         -    1. TSS-controlled withdraw (native or ERC20).
 *         -    2. Token Support List: allowlist for ERC20 used as gas inputs on gas tx path.
 *         - Note: Fund management and access control is managed by TSS_ROLE.
 * 
 * @dev    - USD Cap Checks:
 *         -    TX Types like GAS_TX and GAS_AND_PAYLOAD_TX have require lower block confirmation for execution. 
 *         -    Therefore, these transactions have a USD cap checks for gas tx deposits via oracle. 
 *         - Note: Chainlink Oracle is used for ETH/USD price feed.
 */

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable}         from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors}                     from "./libraries/Errors.sol";
import {IUniversalGateway}          from "./interfaces/IUniversalGateway.sol";

import {RevertSettings, UniversalPayload, TX_TYPE} from "./libraries/Types.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ISwapRouter as ISwapRouterV3} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract UniversalGatewayV0 is
    Initializable,
    ContextUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IUniversalGateway
{
    using SafeERC20 for IERC20;
    // =========================
    //           ROLES
    // =========================
    bytes32 public constant TSS_ROLE    = keccak256("TSS_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================
    //            STATE
    // =========================

    /// @notice The current TSS address (receives native from universal-tx deposits)
    address public tssAddress;

    /// @notice USD caps for universal tx deposits (1e18 = $1)
    uint256 public MIN_CAP_UNIVERSAL_TX_USD; // inclusive lower bound = 1USD = 1e18
    uint256 public MAX_CAP_UNIVERSAL_TX_USD; // inclusive upper bound = 10USD = 10e18

    /// @notice Token whitelist for BRIDGING (assets locked in this contract)
    mapping(address => bool) public isSupportedToken;

    /// @notice Uniswap V3 factory & router (chain-specific)
    IUniswapV3Factory public uniV3Factory;
    ISwapRouterV3     public uniV3Router;
    address           public WETH;
    uint24[3] public v3FeeOrder = [uint24(500), uint24(3000), uint24(10000)]; 

    /// @notice Chainlink ETH/USD oracle config
    AggregatorV3Interface public ethUsdFeed;          
    uint8  public chainlinkEthUsdDecimals;            
    uint256 public chainlinkStalePeriod;              

    /// @notice (Optional) Chainlink L2 Sequencer uptime feed & grace period for rollups
    AggregatorV3Interface public l2SequencerFeed;        // if set, enforce sequencer up + grace
    uint256 public l2SequencerGracePeriodSec;            // e.g., 300 seconds


    /// @notice Default additional time window used when callers pass deadline = 0 (Uniswap v3 swaps)
    uint256 public defaultSwapDeadlineSec; 

    /// @notice USDT token address for the old addFunds function
    address public USDT;
    /// @notice Pool fee for WETH/USDT swap (typically 3000 for 0.3%)
    uint24 public POOL_FEE = 3000;
    /// @notice USDT/USD price feed for calculating final USD amount
    AggregatorV3Interface public usdtUsdPriceFeed;

    uint256[40] private __gap;

    /**
     * @notice Initialize the UniversalGateway contract
     * @param admin            DEFAULT_ADMIN_ROLE holder
     * @param pauser           PAUSER_ROLE
     * @param tss              initial TSS address
     * @param minCapUsd        min USD cap (1e18 decimals)
     * @param maxCapUsd        max USD cap (1e18 decimals)
     * @param factory          UniswapV2 factory 
     * @param router           UniswapV2 router
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
        if (admin == address(0) || 
            pauser == address(0) || 
            tss == address(0) ||
            _wethAddress == address(0)) revert Errors.ZeroAddress();

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,          pauser);
        _grantRole(TSS_ROLE,             tss);

        tssAddress = tss;
        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;
        
        WETH = _wethAddress;
        if (factory != address(0) && router != address(0)) {
            uniV3Factory = IUniswapV3Factory(factory);
            uniV3Router  = ISwapRouterV3(router);

        }
        // Default swap deadline window (industry common ~10 minutes)
        defaultSwapDeadlineSec = 10 minutes;

        // Set a sane default for Chainlink staleness (can be tuned by admin)
        chainlinkStalePeriod = 1 hours;
        usdtUsdPriceFeed = AggregatorV3Interface(_usdtUsdPriceFeed);
        ethUsdFeed = AggregatorV3Interface(_ethUsdPriceFeed);

        emit ChainlinkStalePeriodUpdated(chainlinkStalePeriod);
    }

    /// Todo: TSS Implementation could be changed based on ESDCA vs BLS sign schemes.
    modifier onlyTSS() {
        if (!hasRole(TSS_ROLE, _msgSender())) revert Errors.WithdrawFailed();
        _;
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // =========================
    //           ADMIN ACTIONS
    // =========================
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }
     
    /// @notice Allows the admin to set the TSS address
    /// @param newTSS The new TSS address
    /// Todo: TSS Implementation could be changed based on ESDCA vs BLS sign schemes.
    function setTSSAddress(address newTSS) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newTSS == address(0)) revert Errors.ZeroAddress();
        address old = tssAddress;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTSS);

        tssAddress = newTSS;
        emit TSSAddressUpdated(old, newTSS);
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

    /// @notice Set the default swap deadline window (used when a caller passes deadline = 0)
    /// @param deadlineSec Number of seconds to add to block.timestamp when defaulting the deadline
    function setDefaultSwapDeadline(uint256 deadlineSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (deadlineSec == 0) revert Errors.InvalidAmount();
        defaultSwapDeadlineSec = deadlineSec;
        emit DefaultSwapDeadlineUpdated(deadlineSec);
    }

    /// @notice Allows the admin to set the Uniswap V3 factory and router
    /// @param factory The new Uniswap V3 factory address
    /// @param router The new Uniswap V3 router address
    function setRouters(address factory, address router) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (factory == address(0) || router == address(0)) revert Errors.ZeroAddress();
        uniV3Factory = IUniswapV3Factory(factory);
        uniV3Router  = ISwapRouterV3(router);
    }

    /// @notice Allows the admin to add support for a given token or remove support for a given token
    /// @dev    Adding support for given token, indicates the wrapped version of the token is live on Push Chain.
    /// @param tokens The tokens to modify the support for
    /// @param isSupported The new support status
    function modifySupportForToken(address[] calldata tokens, bool[] calldata isSupported) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (tokens.length != isSupported.length) revert Errors.InvalidInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            isSupportedToken[tokens[i]] = isSupported[i];
            emit TokenSupportModified(tokens[i], isSupported[i]);
        }
    }

    /// @notice Allows the admin to set the fee order for the Uniswap V3 router
    /// @param a The new fee order
    /// @param b The new fee order
    /// @param c The new fee order
    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused
    {
        uint24[3] memory old = v3FeeOrder;
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
        emit ChainlinkEthUsdFeedUpdated(feed, dec);
    }

    /// @notice Configure the maximum allowed data staleness for Chainlink reads
    /// @param stalePeriodSec If > 0, latestRoundData().updatedAt must be within this many seconds
    function setChainlinkStalePeriod(uint256 stalePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        chainlinkStalePeriod = stalePeriodSec;
        emit ChainlinkStalePeriodUpdated(stalePeriodSec);
    }

    /// @notice Set (or clear) the Chainlink L2 sequencer uptime feed for rollups
    /// @dev    Set to address(0) on L1s / chains without a sequencer feed.
    function setL2SequencerFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerFeed = AggregatorV3Interface(feed);
        emit L2SequencerFeedUpdated(feed);
    }

    /// @notice Configure the grace window after sequencer comes back up
    /// @param gracePeriodSec If > 0, require `block.timestamp - sequencer.updatedAt > gracePeriodSec`
    function setL2SequencerGracePeriod(uint256 gracePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerGracePeriodSec = gracePeriodSec;
        emit L2SequencerGracePeriodUpdated(gracePeriodSec);
    }

    // =========================
    //           DEPOSITS - Fee Abstraction Route
    // =========================
    
    struct AmountInUSD {
        uint256 amountInUSD;
        uint8 decimals;
    }

    event FundsAdded(
        address indexed user,
        bytes32 indexed transactionHash,
        AmountInUSD AmountInUSD
    );

    /// @notice OLD Implementation of sendTxWithGas with ETH as gas input
    /// Note:   TO BE REMOVED BEFORE MAINNET - Only for public testnet release
    function addFunds(bytes32 _transactionHash) external payable nonReentrant {
        if (msg.value == 0) revert Errors.InvalidAmount();

        // Wrap ETH to WETH
        IWETH(WETH).deposit{value: msg.value}();
        uint256 WethBalance = IERC20(WETH).balanceOf(address(this));
        IERC20(WETH).approve(address(uniV3Router), WethBalance);

        // Get current ETH/USD price from Chainlink
        (uint256 price, uint8 decimals) = getEthUsdPrice();

        // Calculate minimum output with 0.5% slippage
        uint256 ethInUsd = (price * WethBalance) / 1e18;
        uint256 minOut = (ethInUsd * 995) / 1000;
        minOut = minOut / 1e2; // Convert from 8 decimals to 6 decimals (USDT)

        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDT,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp, //not for sepolia
                amountIn: WethBalance,
                amountOutMinimum: minOut, // Adjust to USDT decimals (6) && not for sepolia
                sqrtPriceLimitX96: 0
            });

        uint256 usdtReceived = uniV3Router.exactInputSingle(params);

        // Get USDT/USD price and calculate final USD amount
        (, int256 usdtPrice, , , ) = usdtUsdPriceFeed.latestRoundData();
        uint8 usdDecimals = usdtUsdPriceFeed.decimals();
        uint256 usdAmount = (uint256(usdtPrice) * usdtReceived) /
            10 ** 6;

        AmountInUSD memory usdAmountStruct = AmountInUSD({
            amountInUSD: usdAmount,
            decimals: usdDecimals
        });

        emit FundsAdded(msg.sender, _transactionHash, usdAmountStruct);
    }


    /// @notice Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain.
    /// @dev    Supports 2 TX types:
    ///          a. GAS.
    ///          b. GAS_AND_PAYLOAD.
    ///         Note: Any TX initiated via fee abstraction route requires lower block confirmations for execution on Push Chain.abi
    ///         Hence, the deposit amount is subject to USD cap checks that is strictly enforced with MIN_CAP_UNIVERSAL_TX_USD and MAX_CAP_UNIVERSAL_TX_USD.
    ///         Gas for this transaction must be paid in the NATIVE token of the soruce chain.
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
     function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable nonReentrant whenNotPaused {


        _checkUSDCaps(msg.value);
        _handleNativeDeposit(msg.value);
        _sendTxWithGas(_msgSender(), abi.encode(payload), msg.value, revertCFG, TX_TYPE.GAS_AND_PAYLOAD);  
    }

  
    /// @notice Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain with any supported Token.
    /// @dev    Allows users to use any token to fund or execute a payload on Push Chain.
    ///         The deopited token is swapped to native ETH using Uniswap v3.
    ///         Supports 2 TX types:
    ///          a. GAS.
    ///          b. GAS_AND_PAYLOAD.
    ///         Note: Any TX initiated via fee abstraction route requires lower block confirmations for execution on Push Chain.
    ///         Hence, the deposit amount is subject to USD cap checks that is strictly enforced with MIN_CAP_UNIVERSAL_TX_USD and MAX_CAP_UNIVERSAL_TX_USD.
    ///         Gas for this transaction can be paid in any token with a valid pool with the native token on AMM. 
    /// @param tokenIn Token address to swap from
    /// @param amountIn Amount of token to swap
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
    /// @param amountOutMinETH Minimum ETH expected (slippage protection)
    /// @param deadline Swap deadline

    function sendTxWithGas(
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG,
        uint256 amountOutMinETH,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (tokenIn == address(0)) revert Errors.InvalidInput();
        if (amountIn == 0) revert Errors.InvalidAmount();
        if (amountOutMinETH == 0) revert Errors.InvalidAmount();
        // Allow deadline == 0 (use contract default); otherwise ensure it's in the future
        if (deadline != 0 && deadline < block.timestamp) revert Errors.SlippageExceededOrExpired();

        // Swap token to native ETH
        uint256 ethOut = swapToNative(tokenIn, amountIn, amountOutMinETH, deadline);

        // Forward ETH to TSS and emit deposit event
        _handleNativeDeposit(ethOut);
        _sendTxWithGas(
            _msgSender(),
            abi.encode(payload),
            ethOut,
            revertCFG,
            TX_TYPE.GAS_AND_PAYLOAD
        );
    }

    /// @dev    Internal helper function to deposit for Instant TX.
    ///         Emits the core TxWithGas event - important for Instant TX Route.
    /// @param _caller Sender address
    /// @param _payload Payload
    /// @param _nativeTokenAmount Amount of native token deposited
    /// @param _revertCFG Revert settings
    /// @param _txType Transaction type
    function _sendTxWithGas(
        address _caller, 
        bytes memory _payload, 
        uint256 _nativeTokenAmount, 
        RevertSettings calldata _revertCFG,
        TX_TYPE _txType
    ) internal {
        if (_revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();

        emit TxWithGas({
            sender: _caller,
            payload: _payload,
            nativeTokenDeposited: _nativeTokenAmount,
            revertCFG: _revertCFG,
            txType: _txType
        });
    }
   
    // =========================
    //           DEPOSITS - Universal TX Route
    // =========================

    /// @notice Allows initiating a TX for movement of high value funds from source chain to Push Chain.
    /// @dev    Doesn't support arbitrary execution payload via UEAs. Only allows movement of funds.
    ///         The tokens moved must be supported by the gateway. 
    ///         Supports only Universal TX type with high value funds, i.e., high block confirmations are required.
    ///         Supports the TX type - FUNDS.
    /// @param recipient Recipient address
    /// @param bridgeToken Token address to bridge
    /// @param bridgeAmount Amount of token to bridge
    /// @param revertCFG Revert settings
    function sendFunds(
        address recipient,
        address bridgeToken,
        uint256 bridgeAmount,
        RevertSettings calldata revertCFG
    ) external payable nonReentrant whenNotPaused {
        if (recipient == address(0)) revert Errors.InvalidRecipient();

        if (bridgeToken == address(0)) {
            // native: amount must match value; funds are held in this contract for TVL
            if (msg.value != bridgeAmount) revert Errors.InvalidAmount();
            _handleNativeDeposit(bridgeAmount);
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            _handleTokenDeposit(bridgeToken, bridgeAmount);
        }

        _sendTxWithFunds(
            _msgSender(),
            recipient,
            bridgeToken,
            bridgeAmount,
            bytes(""), // Empty payload for funds-only bridge
            revertCFG,
            TX_TYPE.FUNDS
        );
    }

    /// @notice Allows initiating a TX for movement of funds and payload from source chain to Push Chain.
    /// @dev    Supports arbitrary execution payload via UEAs.
    ///         The tokens moved must be supported by the gateway. 
    ///         Supports the TX type - FUNDS_AND_PAYLOAD.
    ///         Gas for this transaction must be paid in the NATIVE token of the soruce chain.
    ///         Note: Recipient for such TXs are always the user's UEA on Push Chain. Hence, no recipient address is needed.
    /// @param bridgeToken Token address to bridge
    /// @param bridgeAmount Amount of token to bridge
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable nonReentrant whenNotPaused {
        if (bridgeAmount == 0) revert Errors.InvalidAmount();
        uint256 gasAmount = msg.value;
        if (gasAmount == 0) revert Errors.InvalidAmount();

        // Check and initiate Instant TX 
        _checkUSDCaps(gasAmount);
        _handleNativeDeposit(gasAmount);
        _sendTxWithGas(
            _msgSender(),
            bytes(""),
            gasAmount,
            revertCFG,
            TX_TYPE.GAS
        );

        // Check and initiate Universal TX 
        _handleTokenDeposit(bridgeToken, bridgeAmount);
        _sendTxWithFunds(
            _msgSender(),
            address(0),
            bridgeToken,
            bridgeAmount,
            abi.encode(payload),
            revertCFG,
            TX_TYPE.FUNDS_AND_PAYLOAD
        );
    }


    /// @notice Allows initiating a TX for movement of funds and payload from source chain to Push Chain.   
    ///        Similar to sendTxWithFunds(), but with a token as gas input.
    /// @dev    The gas token is swapped to native ETH using Uniswap v3.
    ///         The tokens moved must be supported by the gateway. 
    ///         Supports the TX type - FUNDS_AND_PAYLOAD.
    ///         Gas for this transaction can be paid in any token with a valid pool with the native token on AMM. 
    ///         Imposes a strict check for USD cap for the deposit amount. High Value movement of funds is not allowed through this route.
    /// @dev    The route emits two different events:
    ///          a. TxWithGas - for gas funding - no payload is moved. 
    ///                                   allows user to fund their UEA, which will be used for execution of payload.
    ///          b. TxWithFunds - for funds and payload movement from source chain to Push Chain.
    ///                                   
    ///         Note: Recipient for such TXs are always the user's UEA. Hence, no recipient address is needed.                     
    /// @param bridgeToken Token address to bridge
    /// @param bridgeAmount Amount of token to bridge
    /// @param gasToken Token address to swap from
    /// @param gasAmount Amount of token to swap
    /// @param payload Universal payload to e
    
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external nonReentrant whenNotPaused {
        if (bridgeAmount == 0) revert Errors.InvalidAmount();
        if (gasToken == address(0)) revert Errors.InvalidInput();
        if (gasAmount == 0) revert Errors.InvalidAmount();

        // Swap gasToken to native ETH
        uint256 nativeGasAmount = swapToNative(gasToken, gasAmount, amountOutMinETH, deadline);

        _checkUSDCaps(nativeGasAmount);
        _handleNativeDeposit(nativeGasAmount);

        _sendTxWithGas(
            _msgSender(),
            bytes(""),
            nativeGasAmount,
            revertCFG,
            TX_TYPE.GAS
        );

        _handleTokenDeposit(bridgeToken, bridgeAmount);
        _sendTxWithFunds(
            _msgSender(),
            address(0),
            bridgeToken,
            bridgeAmount,
            abi.encode(payload),
            revertCFG,
            TX_TYPE.FUNDS_AND_PAYLOAD
        );

    }

    /// @notice Internal helper function to deposit for Universal TX.   
    /// @dev    Emits the core TxWithFunds event - important for Universal TX Route.
    /// @param _caller Sender address
    /// @param _recipient Recipient address
    /// @param _bridgeToken Token address to bridge
    /// @param _bridgeAmount Amount of token to bridge
    /// @param _payload Payload
    /// @param _revertCFG Revert settings
    /// @param _txType Transaction type
    function _sendTxWithFunds(
        address _caller,
        address _recipient,
        address _bridgeToken,
        uint256 _bridgeAmount,
        bytes memory _payload,
        RevertSettings calldata _revertCFG,
        TX_TYPE _txType
    ) internal {
        if (_revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        /// for recipient == address(0), the funds are being moved to UEA of the msg.sender on Push Chain.
        if (_recipient == address(0)){
            if (
                _txType != TX_TYPE.FUNDS_AND_PAYLOAD &&
                _txType != TX_TYPE.GAS_AND_PAYLOAD
            ) {
                revert Errors.InvalidTxType();
            }
        }

        emit TxWithFunds({
            sender: _caller,
            recipient: _recipient,
            bridgeAmount: _bridgeAmount,
            bridgeToken: _bridgeToken,
            payload: _payload,
            revertCFG: _revertCFG,
            txType: _txType
        });
    }

    // =========================
    //          WITHDRAW
    // =========================

    /**
     * @notice TSS-only withdraw (unlock) to an external recipient on Push Chain.
     * @param recipient   destination address
     * @param token       address(0) for native; ERC20 otherwise
     * @param amount      amount to withdraw
     */
    function withdrawFunds(
        address recipient,
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyTSS {
        if (recipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0) revert Errors.InvalidAmount();

        if (token == address(0)) {
            _handleNativeWithdraw(recipient, amount);
        } else {
            _handleTokenWithdraw(token, recipient, amount);
        }

        emit WithdrawFunds(recipient, amount, token);
    }

    /**
     * @notice Refund (revert) path controlled by TSS (e.g., failed universal/bridge).
     *         Sends funds to revertCFG.fundRecipient using same rules as withdraw.
     * @param token       address(0) for native; ERC20 otherwise
     * @param amount      amount to refund
     * @param revertCFG   (fundRecipient, revertMsg)
     */
    function revertWithdrawFunds(
        address token,
        uint256 amount,
        RevertSettings calldata revertCFG
    ) external nonReentrant whenNotPaused onlyTSS {
        if (revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0) revert Errors.InvalidAmount();

        if (token == address(0)) {
            _handleNativeWithdraw(revertCFG.fundRecipient, amount);
        } else {
            _handleTokenWithdraw(token, revertCFG.fundRecipient, amount);
        }

        emit WithdrawFunds(revertCFG.fundRecipient, amount, token);
    }

    // =========================
    //      PUBLIC HELPERS
    // =========================

    /// @notice Computes the minimum and maximum deposit amounts in native ETH (wei) implied by the USD caps.
    /// @dev    Uses the current ETH/USD price from {getEthUsdPrice}.
    /// @return minValue Minimum native amount (in wei) allowed by MIN_CAP_UNIVERSAL_TX_USD
    /// @return maxValue Maximum native amount (in wei) allowed by MAX_CAP_UNIVERSAL_TX_USD
    function getMinMaxValueForNative() public view returns (uint256 minValue, uint256 maxValue) {
        (uint256 ethUsdPrice, ) = getEthUsdPrice(); // ETH price in USD (1e18 scaled)
        
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
            (
                ,            // roundId (unused)
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

        (
            uint80 roundId,
            int256 priceInUSD,
            ,
            uint256 updatedAt,  
            uint80 answeredInRound
        ) = ethUsdFeed.latestRoundData();

        // Basic oracle safety checks
        if (priceInUSD <= 0) revert Errors.InvalidData();
        if (answeredInRound < roundId) revert Errors.InvalidData();
        if (chainlinkStalePeriod != 0 && block.timestamp - updatedAt > chainlinkStalePeriod) {
            revert Errors.InvalidData();
        }

        uint8 dec = chainlinkEthUsdDecimals;
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
        (uint256 px1e18, ) = getEthUsdPrice(); // will validate freshness and positivity
        // USD(1e18) = (amountWei * px1e18) / 1e18
        // Note: amountWei is 1e18-based (wei), price is scaled to 1e18 above.
        usd1e18 = (amountWei * px1e18) / 1e18;
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

    /// @dev Forward native ETH to TSS; returns amount forwarded (= msg.value or computed after swap).
    function _handleNativeDeposit(uint256 amount) internal returns (uint256) {
        (bool ok, ) = payable(tssAddress).call{value: amount}("");
        if (!ok) revert Errors.DepositFailed();
        return amount;
    }

    /// @dev Lock ERC20 in this contract for bridging (must be isSupported).
    ///      Tokens are stored in gateway contract.
    /// @param token Token address to deposit
    /// @param amount Amount of token to deposit
    function _handleTokenDeposit(address token, uint256 amount) internal {
        if (!isSupportedToken[token]) revert Errors.NotSupported();
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
    }

    /// @dev Native withdraw by TSS
    function _handleNativeWithdraw(address recipient, uint256 amount) internal {
        (bool ok, ) = payable(recipient).call{value: amount}("");
        if (!ok) revert Errors.WithdrawFailed();
    }

    /// @dev ERC20 withdraw by TSS (token must be isSupported for bridging)
    ///      Tokens are moved out of gateway contract.
    /// @param token Token address to withdraw
    /// @param recipient Recipient address
    /// @param amount Amount of token to withdraw
    function _handleTokenWithdraw(address token, address recipient, uint256 amount) internal {
        // Note: Removing isSupportedToken[token] for now to avoid a rare case scenario
        //       If a token was supported before and user bridged > but was removed from support list later, funds get stuck.
        // if (!isSupportedToken[token]) revert Errors.NotSupported();
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();
        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @dev Swap any ERC20 to the chain's native token via a direct Uniswap v3 pool to WETH.
    ///      - If tokenIn == WETH: unwrap to native and return.
    ///      - Else: require a direct tokenIn/WETH v3 pool, swap via exactInputSingle, unwrap, return ETH out.
    ///      - No price/cap logic here; slippage and deadline are enforced; caps are enforced elsewhere.
    ///      - If `deadline == 0`, it is replaced with `block.timestamp + defaultSwapDeadlineSec`.
    /// @param tokenIn           ERC-20 being paid as "gas token"
    /// @param amountIn          amount of tokenIn to pull and swap
    /// @param amountOutMinETH   min acceptable native (ETH) out (slippage bound)
    /// @param deadline          swap deadline
    /// @return ethOut           native ETH received
    function swapToNative(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMinETH,
        uint256 deadline
    ) internal returns (uint256 ethOut) {
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
        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinETH, // min WETH out, equals min ETH out after unwrap
            sqrtPriceLimitX96: 0
        });

        uint256 wethOut = uniV3Router.exactInputSingle(params);

        // Approval hygiene
        IERC20(tokenIn).approve(address(uniV3Router), 0);

        // Unwrap WETH -> native and compute exact ETH out
        uint256 balBefore = address(this).balance;
        IWETH(WETH).withdraw(wethOut);
        ethOut = address(this).balance - balBefore;

        // Defensive: enforce the bound again after unwrap
        if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();

        _checkUSDCaps(ethOut);
    }

    // Helper: find the best-fee direct v3 pool between tokenIn and WETH.
    // Scans v3FeeOrder (e.g., [500, 3000, 10000]) and returns the first existing pool.
    function _findV3PoolWithNative(
        address tokenIn
    ) internal view returns (IUniswapV3Pool pool, uint24 fee) {
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


    // =========================
    //         RECEIVE/FALLBACK
    // =========================

    /// @dev Reject plain ETH; we only accept ETH via explicit deposit functions or WETH unwrapping.
   receive() external payable {
    // Allow WETH unwrapping; block unexpected sends.
    if (msg.sender != WETH) revert Errors.DepositFailed();
}
}
