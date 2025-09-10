// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGatewayV1
 * @notice Universal Gateway for EVM chains.
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

import {RevertSettings, UniversalPayload, PoolCfg, TX_TYPE} from "./libraries/Types.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ISwapRouter as ISwapRouterV3} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract UniversalGatewayV1 is
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
    address           public WETH; // cached from router
    uint24[3] public v3FeeOrder = [uint24(500), uint24(3000), uint24(10000)]; 
    PoolCfg public poolUSDC; // DEPRECATED: used by TWAP; retained for storage layout

    /// @notice TWAP parameters
    uint32  public twapWindowSec;     // DEPRECATED: TWAP parameter (unused after Chainlink migration)
    uint16  public minObsCardinality; // DEPRECATED: TWAP parameter (unused after Chainlink migration)

    /// @notice Chainlink ETH/USD oracle config
    AggregatorV3Interface public ethUsdFeed;          // ETH/USD feed (decimals typically 8)
    uint8  public chainlinkEthUsdDecimals;            // Cached feed decimals
    uint256 public chainlinkStalePeriod;              // Max allowed staleness in seconds (0 = no check)

    /// @notice Emitted when Chainlink feed is updated
    event ChainlinkEthUsdFeedUpdated(address indexed feed, uint8 decimals);
    /// @notice Emitted when Chainlink staleness config is changed
    event ChainlinkStalePeriodUpdated(uint256 stalePeriodSec);


    // storage gap for upgradeability
    uint256[43] private __gap;

    /**
     * @notice Initialize the UniversalGatewayV1 contract
     * @param admin            DEFAULT_ADMIN_ROLE holder
     * @param pauser           PAUSER_ROLE
     * @param tss              initial TSS address
     * @param minCapUsd        min USD cap (1e18 decimals)
     * @param maxCapUsd        max USD cap (1e18 decimals)
     * @param factory          UniswapV2 factory (optional if ERC20-for-gas disabled)
     * @param router           UniswapV2 router  (optional if ERC20-for-gas disabled)
     */
    function initialize(
        address admin,
        address pauser,
        address tss,
        uint256 minCapUsd,
        uint256 maxCapUsd,
        address factory,
        address router,
        address _wethAddress
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

        emit TSSAddressUpdated(address(0), tss);
        emit CapsUpdated(minCapUsd, maxCapUsd);
        // sensible defaults; can be overridden with setters by admin
        twapWindowSec      = 1800; // 30m
        minObsCardinality  = 16;   // require some history for robust TWAP
    }

    /// Todo: TSS Implementation could be changed based on ESDCA vs BLS sign schemes.
    modifier onlyTSS() {
        if (!hasRole(TSS_ROLE, _msgSender())) revert Errors.WithdrawFailed();
        _;
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

    // =========================
    //           DEPOSITS - Fee Abstraction Route
    // =========================

    /// @notice Deposit for Instant Transaction (gas funding deposit or Low Value Fund & Payload Exec).
    /// @dev    Supports only Instant TX type, i.e., low block confirmations are required.
    ///         TX_TYPE supported for this route are:
    ///          a. GAS.
    ///          b. GAS_AND_PAYLOAD.
    ///         Imposes a strict check for USD cap for the deposit amount. High Value movement of funds is not allowed through this route.
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
     function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable nonReentrant whenNotPaused {
        // Note: Important check to ensure the USD cap is not exceeded.
        // Reason: The depositForInstantTx() function is designed for UX improvement and instant cross-chain calls. 
        // Therefore, the required block confirmations for this route is very minimal. This means moving large amounts of ETH via this route is not recommended.
        // Amount of ETH deposited must be less than or equal to the USD cap range allowed for this deposit route.
        // Trying to move out-of-range ETH will revert the whole trasnaction.

        _checkUSDCaps(msg.value);
        _handleNativeDeposit(msg.value);
        _sendTxWithGas(_msgSender(), keccak256(abi.encode(payload)), msg.value, revertCFG, TX_TYPE.GAS_AND_PAYLOAD);  
    }

    /// @notice Deposit for Instant Transaction with any supported Token.
    /// @dev    Allows users to use any token to fund or execute a payload on Push Chain.
    ///         The deopited token is swapped to native ETH using Uniswap v3.
    ///         TX_TYPE supported for this route are:
    ///          a. GAS.
    ///          b. GAS_AND_PAYLOAD.
    ///         Imposes a strict check for USD cap for the deposit amount. High Value movement of funds is not allowed through this route.
    /// @param tokenIn Token address to swap from
    /// @param amountIn Amount of token to swap
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
    /// @param amountOutMinETH Minimum ETH expected (slippage protection)
    /// @param deadline Swap deadline

    // ToDo: swapToNative function usage - hence commented out , to be implemented later.
    // function sendTxWithGas(
    //     address tokenIn,
    //     uint256 amountIn,
    //     UniversalPayload calldata payload,
    //     RevertSettings calldata revertCFG,
    //     uint256 amountOutMinETH,
    //     uint256 deadline
    // ) external nonReentrant whenNotPaused {
    //     if (tokenIn == address(0)) revert Errors.InvalidInput();
    //     if (amountIn == 0) revert Errors.InvalidAmount();
    //     if (amountOutMinETH == 0) revert Errors.InvalidAmount();
    //     if (deadline < block.timestamp) revert Errors.SlippageExceededOrExpired();

    //     // Swap token to native ETH
    //     uint256 ethOut = swapToNative(tokenIn, amountIn, amountOutMinETH, deadline); //@audit-info -> rename ethOut to nativeTokenAmount

    //     // Forward ETH to TSS and emit deposit event
    //     _handleNativeDeposit(ethOut);
    //     _sendTxWithGas(
    //         _msgSender(),
    //         keccak256(abi.encode(payload)),
    //         ethOut,
    //         revertCFG,
    //         TX_TYPE.GAS_AND_PAYLOAD
    //     );
    // }

    /// @dev    Internal helper function to deposit for Instant TX.
    ///         Emits the core DepositForInstantTx event - important for Instant TX Route.
    /// @param _caller Sender address
    /// @param _payloadHash Payload hash
    /// @param _nativeTokenAmount Amount of native token deposited
    /// @param _revertCFG Revert settings
    /// @param _txType Transaction type
    function _sendTxWithGas(
        address _caller, 
        bytes32 _payloadHash, 
        uint256 _nativeTokenAmount, 
        RevertSettings calldata _revertCFG,
        TX_TYPE _txType
    ) internal {
        if (_revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();

        emit DepositForInstantTx({
            sender: _caller,
            payloadHash: _payloadHash,
            nativeTokenDeposited: _nativeTokenAmount,
            revertCFG: _revertCFG,
            txType: _txType
        });
    }



    // =========================
    //           DEPOSITS - Universal TX Route
    // =========================

    /// @notice Allows deposit and movement of high value funds from source chain to Push Chain.
    /// @dev    Doesn't support arbitrary execution payload via UEAs. Only allows movement of funds.
    ///         The tokens moved must be supported by the gateway. 
    ///         Supports only Universal TX type with high value funds, i.e., high block confirmations are required.
    ///         TX_TYPE supported for this route are:
    ///          a. FUNDS.
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
            0,
            bytes32(0), // Empty payload hash for funds-only bridge
            revertCFG,
            TX_TYPE.FUNDS
        );
    }

    /// @notice Allows deposit and movement of funds and payload from source chain to Push Chain.
    /// @dev    Supports arbitrary execution payload via UEAs.
    ///         The tokens moved must be supported by the gateway. 
    ///         TX_TYPE supported for this route are:
    ///          a. FUNDS_AND_PAYLOAD.
    ///         Recipient for such TXs are always the user's UEA. Hence, no recipient address is needed.
    /// @dev    The route emits two different events:
    ///          a. DepositForInstantTx - for gas funding - no payload is moved. 
    ///                                   - allows user to fund their UEA, which will be used for execution of payload.
    ///          b. DepositForUniversalTx - for funds and payload movement from source chain to Push Chain.
    ///                                   
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
            hex"",
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
            gasAmount,
            keccak256(abi.encode(payload)),
            revertCFG,
            TX_TYPE.FUNDS_AND_PAYLOAD
        );
    }

    /// @notice Allows deposit and movement of funds and payload from source chain to Push Chain.
    ///        Similar to depositForUniversalTxFundsAndPayload(), but with a token as gas input.
    /// @dev    The gas token is swapped to native ETH using Uniswap v3.
    ///         The tokens moved must be supported by the gateway. 
    ///         TX_TYPE supported for this route are:
    ///          a. FUNDS_AND_PAYLOAD.
    ///         Imposes a strict check for USD cap for the deposit amount. High Value movement of funds is not allowed through this route.
    /// @dev    The route emits two different events:
    ///          a. DepositForInstantTx - for gas funding - no payload is moved. 
    ///                                   allows user to fund their UEA, which will be used for execution of payload.
    ///          b. DepositForUniversalTx - for funds and payload movement from source chain to Push Chain.
    ///                                   
    ///         Recipient for such TXs are always the user's UEA. Hence, no recipient address is needed.                     
    /// @param bridgeToken Token address to bridge
    /// @param bridgeAmount Amount of token to bridge
    /// @param gasToken Token address to swap from
    /// @param gasAmount Amount of token to swap
    /// @param payload Universal payload to e
    
    // ToDo: swapToNative function usage - hence commented out , to be implemented later.
    // function sendTxWithFunds(
    //     address bridgeToken,
    //     uint256 bridgeAmount,
    //     address gasToken,
    //     uint256 gasAmount,
    //     UniversalPayload calldata payload,
    //     RevertSettings calldata revertCFG
    // ) external nonReentrant whenNotPaused {
    //     if (bridgeAmount == 0) revert Errors.InvalidAmount();
    //     if (gasToken == address(0)) revert Errors.InvalidInput();
    //     if (gasAmount == 0) revert Errors.InvalidAmount();

    //     // Swap gasToken to native ETH
    //     uint256 nativeGasAmount = swapToNative(gasToken, gasAmount, 0, block.timestamp);

    //     _checkUSDCaps(nativeGasAmount);
    //     _handleNativeDeposit(nativeGasAmount);

    //     _sendTxWithGas(
    //         _msgSender(),
    //         hex"",
    //         nativeGasAmount,
    //         revertCFG,
    //         TX_TYPE.GAS
    //     );

    //     _handleTokenDeposit(bridgeToken, bridgeAmount);
    //     _depositForUniversalTx(
    //         _msgSender(),
    //         address(0),
    //         bridgeToken,
    //         bridgeAmount,
    //         nativeGasAmount,
    //         keccak256(abi.encode(payload)),
    //         revertCFG,
    //         TX_TYPE.FUNDS_AND_PAYLOAD
    //     );

    // }

    /// @notice Internal helper function to deposit for Universal TX.   
    /// @dev    Emits the core DepositForUniversalTx event - important for Universal TX Route.
    /// @param _caller Sender address
    /// @param _recipient Recipient address
    /// @param _bridgeToken Token address to bridge
    /// @param _bridgeAmount Amount of token to bridge
    /// @param _gasAmount Amount of gas to deposit
    /// @param _payloadHash Payload hash
    /// @param _revertCFG Revert settings
    /// @param _txType Transaction type
    function _sendTxWithFunds(
        address _caller,
        address _recipient,
        address _bridgeToken,
        uint256 _bridgeAmount,
        uint256 _gasAmount,
        bytes32 _payloadHash,
        RevertSettings calldata _revertCFG,
        TX_TYPE _txType
    ) internal {
        if (_revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        /// for recipient == address(0), the funds are being moved to UEA of the msg.sender.
        if (_recipient == address(0)){
            if (_gasAmount == 0) revert Errors.InvalidAmount();
            if (_payloadHash == bytes32(0)) revert Errors.InvalidData();
            if (
                _txType != TX_TYPE.FUNDS_AND_PAYLOAD &&
                _txType != TX_TYPE.GAS_AND_PAYLOAD
            ) {
                revert Errors.InvalidTxType();
            }
        }

        emit DepositForUniversalTx({
            sender: _caller,
            recipient: _recipient,
            bridgeAmount: _bridgeAmount,
            gasAmount: _gasAmount,
            bridgeToken: _bridgeToken,
            data: abi.encodePacked(_payloadHash),
            revertCFG: _revertCFG,
            txType: _txType
        });
    }

    // =========================
    //          WITHDRAW
    // =========================

    /**
     * @notice TSS-only withdraw (unlock) to an external recipient.
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

        emit Withdraw(recipient, amount, token);
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

        emit Withdraw(revertCFG.fundRecipient, amount, token);
    }

    // =========================
    //       INTERNAL HELPERS
    // =========================

    /// @dev Check if the amount is within the USD cap range
    ///      Cap Ranges are defined in the constructor or can be updated by the admin.
    /// @param amount Amount to check
    function _checkUSDCaps(uint256 amount) internal view { 
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

    /// @dev Internal helper function to swap any ERC20 token to native token of the source chain
    /// @param tokenIn Token address to swap from
    /// @param amountIn Amount of token to swap
    /// @param amountOutMinETH Minimum ETH expected (slippage protection)
    /// @param deadline Swap deadline
    /// @return ethOut Amount of ETH received after swap

    // Todo:  Implement this function later
    // function swapToNative(
    //     address tokenIn,
    //     uint256 amountIn,
    //     uint256 amountOutMinETH,
    //     uint256 deadline
    // ) internal returns (uint256 ethOut) {
    //     // 1) Find a viable X/WETH v3 pool (or WETH fast-path)
    //     (IUniswapV3Pool pool, uint24 fee) = TWAPOracle._findPoolWithNative(uniV3Factory, tokenIn, WETH, v3FeeOrder);

    //     // 2) Pre-swap USD cap (TWAP X->ETH, then ETH->USD)
    //     //    Also this assumes that the ETH/USD oracle is configured.
    //     uint256 estEthWei = TWAPOracle._estimateNativeOutForToken(pool, tokenIn, WETH, amountIn, twapWindowSec, minObsCardinality);
    //     _checkUSDCaps(estEthWei);

    //     // 3) Execute swap (or unwrap)
    //     if (tokenIn == WETH) {
    //         // Pull WETH then unwrap to ETH
    //         IERC20(WETH).safeTransferFrom(_msgSender(), address(this), amountIn);
    //         uint256 balBefore = address(this).balance;
    //         IWETH(WETH).withdraw(amountIn);
    //         ethOut = address(this).balance - balBefore;
    //         if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
    //     } else {
    //         // Pull Token X into this contract
    //         IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);
    //         IERC20(tokenIn).safeIncreaseAllowance(address(uniV3Router), amountIn);

    //         ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3.ExactInputSingleParams({
    //             tokenIn: tokenIn,
    //             tokenOut: WETH,
    //             fee: fee,
    //             recipient: address(this),
    //             deadline: deadline,
    //             amountIn: amountIn,
    //             amountOutMinimum: amountOutMinETH, // user-provided slippage bound in ETH
    //             sqrtPriceLimitX96: 0
    //         });

    //         uint256 wethOut = uniV3Router.exactInputSingle(params);

    //         IERC20(tokenIn).approve(address(uniV3Router), 0);
    //         uint256 balBefore = address(this).balance;
    //         IWETH(WETH).withdraw(wethOut);
    //         ethOut = address(this).balance - balBefore;

    //         // Invariant Check included: ethOut == wethOut, but keep the check anyway
    //         if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
    //     }

    //     _checkUSDCaps(ethOut);
    // }

    /// @notice ETH/USD price scaled to 1e18, sourced from Chainlink AggregatorV3.
    /// @dev Requires `ethUsdFeed` to be set. If `chainlinkStalePeriod` is non-zero, enforces freshness.
    function ethUsdPrice1e18() public view returns (uint256) {
        if (address(ethUsdFeed) == address(0)) revert Errors.InvalidInput(); // feed not set
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethUsdFeed.latestRoundData();

        // Basic oracle safety checks
        if (answer <= 0) revert Errors.InvalidData();
        if (answeredInRound < roundId) revert Errors.InvalidData();
        if (chainlinkStalePeriod != 0 && block.timestamp - updatedAt > chainlinkStalePeriod) {
            revert Errors.InvalidData();
        }

        uint8 dec = chainlinkEthUsdDecimals;
        // Scale answer (decimals = dec) to 1e18
        uint256 scale;
        unchecked {
            // dec is expected to be <= 18 for feeds; if >18, this will underflow so guard:
            if (dec > 18) revert Errors.InvalidData();
            scale = 10 ** uint256(18 - dec);
        }
        return uint256(answer) * scale;
    }

    /// @notice Convert an ETH amount (wei) into USD 1e18 using Chainlink ETH/USD price.
    function quoteEthAmountInUsd1e18(uint256 amountWei) public view returns (uint256 usd1e18) {
        if (amountWei == 0) return 0;
        uint256 px1e18 = ethUsdPrice1e18(); // will validate freshness and positivity
        // USD(1e18) = (amountWei * px1e18) / 1e18
        // Note: amountWei is 1e18-based (wei), price is scaled to 1e18 above.
        usd1e18 = (amountWei * px1e18) / 1e18;
    }

    /// @notice Get the minimum and maximum ETH amounts that can be deposited based on USD caps.
    /// @dev    Converts USD cap limits to ETH amounts using current Chainlink price.
    /// @return minValue Minimum ETH amount (in wei) that can be deposited
    /// @return maxValue Maximum ETH amount (in wei) that can be deposited
    function getMinMaxValueForNative() public view returns (uint256 minValue, uint256 maxValue) {
        uint256 ethUsdPrice = ethUsdPrice1e18(); // ETH price in USD (1e18 scaled)
        
        // Convert USD caps to ETH amounts
        // Formula: ETH_amount = (USD_cap * 1e18) / ETH_price_in_USD
        minValue = (MIN_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
        maxValue = (MAX_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
    }

    // =========================
    //         RECEIVE/FALLBACK
    // =========================

    /// @dev Reject plain ETH; we only accept ETH via explicit deposit functions. // ToDo: CHECK IF REVERT NEEDED in FALLBACKS
    receive() external payable {
        revert Errors.DepositFailed();
    }

    fallback() external payable {
        revert Errors.DepositFailed();
    }
}
