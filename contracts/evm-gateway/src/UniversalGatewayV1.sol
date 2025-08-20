// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGatewayV1 (Transparent Upgradeable)
 * @notice Push Chain Universal Gateway for EVM chains.
 *         - Transparent upgradeable (use OZ TransparentUpgradeableProxy + ProxyAdmin).
 *         - Pausable, role-based access control.
 *         - Handles two deposit types:
 *             (1) depositForUniversalTx  (gas funding deposit; supports native and ERC20->WETH swap to native)
 *             (2) depositForAssetBridge  (lock ERC20 or native on gateway for mint on Push Chain)
 *         - TSS-controlled withdraw (native or ERC20).
 *         - Token whitelisting for bridges; separate allowlist for ERC20 used as gas inputs on universal tx path.
 *         - USD cap checks for universal tx deposits via pluggable rate provider.
 *
 */

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable}         from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors}                     from "./libraries/Errors.sol";
import {IUniswapV2Factory, ISwapRouter} from "./interfaces/IAMMInterface.sol";
import {IUniversalGateway}          from "./interfaces/IUniversalGateway.sol";
import {RevertSettings, UniversalPayload} from "./libraries/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";


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
    uint256 public MIN_CAP_UNIVERSAL_TX_USD; // inclusive lower bound
    uint256 public MAX_CAP_UNIVERSAL_TX_USD; // inclusive upper bound

    /// @notice Token whitelist for BRIDGING (assets locked in this contract)
    mapping(address => bool) public isSupportedToken;

    /// @notice Uniswap V2 factory & router (chain-specific)
    IUniswapV2Factory public uniV2Factory;
    ISwapRouter  public uniV2Router;
    address           public WETH; // cached from router

    /// @notice Chainlink price feed for USD valuation checks
    AggregatorV3Interface public ethUsdFeed;          // Chainlink ETH/USD proxy
    uint256 public maxPriceAge;
    // note: sequencerUptimeFeed will be added for gateways for L2s

    // storage gap for upgradeability
    uint256[43] private __gap;

    /**
     * @param admin            DEFAULT_ADMIN_ROLE holder
     * @param pauser           PAUSER_ROLE
     * @param tss              initial TSS address
     * @param minCapUsd        min USD cap (1e18 decimals)
     * @param maxCapUsd        max USD cap (1e18 decimals)
     * @param rateProv         external rate provider (required for USD checks)
     * @param factory          UniswapV2 factory (optional if ERC20-for-gas disabled)
     * @param router           UniswapV2 router  (optional if ERC20-for-gas disabled)
     */
    function initialize(
        address admin,
        address pauser,
        address tss,
        uint256 minCapUsd,
        uint256 maxCapUsd,
        address rateProv,
        address factory,
        address router
    ) external initializer {
        if (admin == address(0) || pauser == address(0) || tss == address(0)) revert Errors.ZeroAddress();

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

        if (factory != address(0) && router != address(0)) {
            uniV2Factory = IUniswapV2Factory(factory);
            uniV2Router  = ISwapRouter(router);
            WETH         = ISwapRouter(router).WETH();
        }

        ethUsdFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        emit TSSAddressUpdated(address(0), tss);
        emit CapsUpdated(minCapUsd, maxCapUsd);
        if (factory != address(0) && router != address(0)) {
            emit RoutersUpdated(factory, router);
        }
    }

    modifier onlyTSS() {
        if (!hasRole(TSS_ROLE, _msgSender())) revert Errors.WithdrawFailed();
        _;
    }

    // =========================
    //           ADMIN ACTIONS
    // =========================
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
        emit PausedBy(_msgSender());
    }

    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
        emit UnpausedBy(_msgSender());
    }

    function setTSSAddress(address newTSS) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newTSS == address(0)) revert Errors.ZeroAddress();
        address old = tssAddress;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTSS);

        tssAddress = newTSS;
        emit TSSAddressUpdated(old, newTSS);
    }

    function setCapsUSD(uint256 minCapUsd, uint256 maxCapUsd) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused { //@audit-info - NEEDS RECHECK
        // optional: require(minCapUsd <= maxCapUsd)
        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;
        emit CapsUpdated(minCapUsd, maxCapUsd);
    }

    function setPriceGuards(uint256 _maxPriceAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxPriceAge = _maxPriceAge;      // e.g., 120
    }

    function setEthUsdFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feed == address(0)) revert Errors.ZeroAddress();
        ethUsdFeed = AggregatorV3Interface(feed);
    }

    function setRouters(address factory, address router) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (factory == address(0) || router == address(0)) revert Errors.ZeroAddress();
        uniV2Factory = IUniswapV2Factory(factory);
        uniV2Router  = ISwapRouter(router);
        WETH         = ISwapRouter(router).WETH();
        emit RoutersUpdated(factory, router);
    }

    function modifySupportForToken(address[] calldata tokens, bool[] calldata isSupported) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (tokens.length != isSupported.length) revert Errors.InvalidInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            isSupportedToken[tokens[i]] = isSupported[i];
            emit TokenSupportModified(tokens[i], isSupported[i]);
        }
    }

    // =========================
    //           DEPOSITS
    // =========================

    /**
     * @notice Deposit for Universal Transaction (gas funding deposit).
     *         - If token == address(0): accept native and forward to TSS.
     *         - If token != 0: swap ERC20->ETH via UniswapV2 then forward ETH to TSS.
     *         - Enforces USD caps against the *input* token and amount.
     *
     * @param tokenIn     address(0) for native; ERC20 otherwise
     * @param amountIn    msg.value (for native) or ERC20 amount
     * @param payload     universal payload
     * @param _data       optional bytes - can be empty
     * @param revertCFG   revert instructions (fund recipient + message)
     * @param amountOutMinETH min ETH expected when swapping ERC20->ETH (ignored for native)
     * @param deadline    swap deadline (ignored for native)
     */
    function depositForUniversalTx( //@audit-info - double check event emission + ORACLE SET UP + GAS LIMIT
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        bytes   calldata _data,
        RevertSettings calldata revertCFG,
        uint256 amountOutMinETH,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        if (revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();

        uint256 ethForwarded;
        if (tokenIn == address(0)) {
            // native path
            if (msg.value != amountIn || amountIn == 0) revert Errors.InvalidAmount();
            _checkUSDCaps(amountIn);
            ethForwarded = _handleNativeDeposit(amountIn);
        } else {
            // ToDo: add USD cap check for ERC20 Token
            if (msg.value != 0 || amountIn == 0) revert Errors.InvalidAmount();
            ethForwarded = _handleERC20ForGasDeposit(tokenIn, amountIn, amountOutMinETH, deadline);
        }

        emit DepositForUniversalTx({ // audit-info - double check event emission
            sender:        _msgSender(),
            payloadHash:   keccak256(abi.encode(payload)),
            nativeTokenDeposited: amountIn,
            _data:          _data,
            revertCFG:     revertCFG
        });
    }

    /**
     * @notice Deposit for Asset Bridging (lock on gateway).
     *         - If token == address(0): accept native and hold in contract.
     *         - If token != 0: require token is isSupported, transferFrom to this contract.
     * @param recipient   bridged asset recipient on Push
     * @param token       address(0) for native; ERC20 otherwise
     * @param amount      amount to lock
     * @param _data       optional bytes - can be empty
     * @param revertCFG   revert config (fundRecipient + message)
     */
    function depositForAssetBridge(
        address recipient,
        address token,
        uint256 amount,
        bytes   calldata _data,
        RevertSettings calldata revertCFG
    ) external payable nonReentrant whenNotPaused {
        if (recipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0) revert Errors.InvalidAmount();
        if (revertCFG.fundRecipient == address(0)) revert Errors.InvalidRecipient();

        if (token == address(0)) {
            // native: amount must match value; funds are held in this contract for TVL
        if (msg.value != amount) revert Errors.InvalidAmount();
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            _handleTokenDeposit(token, amount);
        }

        emit DepositForBridge({ //@audit-info - double check event emission
            sender:        _msgSender(),
            recipient:      recipient,
            amount:         amount,
            tokenAddress:   token,
            data:           _data,
            revertCFG:      revertCFG
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
    function withdraw(
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
    function revertWithdraw(
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

    function _checkUSDCaps(uint256 amount) internal view { //@audit-info - NEEDS RECHECK
        uint256 usdValue = Math.mulDiv(amount, _ethUsdPrice1e18(), 1e18);
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
    function _handleTokenDeposit(address token, uint256 amount) internal {
        if (!isSupportedToken[token]) revert Errors.NotSupported();
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
    }

    /// @dev For universal tx gas: swap ERC20 -> ETH using Uniswap V2 and forward ETH to TSS.
    ///      Reverts if no pair or if swap fails or deadline/slippage violation.
    function _handleERC20ForGasDeposit(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 ethForwarded) {
        if (address(uniV2Factory) == address(0) || address(uniV2Router) == address(0) || WETH == address(0)) {
            revert Errors.NotSwapAllowed();
        }

        // Pair must exist
        address pair = IUniswapV2Factory(uniV2Factory).getPair(tokenIn, WETH);
        if (pair == address(0)) revert Errors.PairNotFound();

        // Pull tokens then approve router
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV2Router), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = WETH;

        // Perform swap
        uint256 balanceBefore = address(this).balance;
        // Prefer standard variant; fee-on-transfer variant is also present in some deployments;
        // choose one; here we use the standard that returns amounts.
        uint256[] memory amounts = ISwapRouter(uniV2Router).swapExactTokensForETH(
            amountIn,
            amountOutMin,
            path,
            address(this),
            deadline
        );
        // Clear approval (defense-in-depth)
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV2Router), 0);

        if (amounts.length < 2) revert Errors.SlippageExceededOrExpired();
        uint256 ethGained = address(this).balance - balanceBefore;
        if (ethGained < amountOutMin) revert Errors.SlippageExceededOrExpired();

        // Forward ETH to TSS
        (bool ok, ) = payable(tssAddress).call{value: ethGained}("");
        if (!ok) revert Errors.DepositFailed();

        return ethGained;
    }

    /// @dev Native withdraw by TSS
    function _handleNativeWithdraw(address recipient, uint256 amount) internal {
        (bool ok, ) = payable(recipient).call{value: amount}("");
        if (!ok) revert Errors.WithdrawFailed();
    }

    /// @dev ERC20 withdraw by TSS (token must be isSupported for bridging)
    function _handleTokenWithdraw(address token, address recipient, uint256 amount) internal {
        if (!isSupportedToken[token]) revert Errors.NotSupported();
        IERC20(token).safeTransfer(recipient, amount);
    }


    /// @notice Returns ETH/USD scaled to 1e18, with staleness & (optionally) sequencer checks only for L2s.
    /// @dev Reverts on invalid, stale, or unsafe conditions.
    function _ethUsdPrice1e18() internal view returns (uint256 px1e18) {

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            ethUsdFeed.latestRoundData();

        if (answer <= 0) revert Errors.InvalidAmount();
        if (answeredInRound < roundId) revert Errors.StalePrice();
        if (block.timestamp - updatedAt > maxPriceAge) revert Errors.StalePrice();
        
        uint8 dec = ethUsdFeed.decimals();                 // typically 8
        uint256 denom = 10 ** uint256(dec);                // scale divisor for feed decimals
        // Scale price to 1e18 with full-precision math
        return Math.mulDiv(uint256(answer), 1e18, denom);  // 1 ETH = ethUsdPrice1e18 USD
        
    }

    // =========================
    //         RECEIVE/FALLBACK
    // =========================

    /// @dev Reject plain ETH; we only accept ETH via explicit deposit functions.
    receive() external payable {
        revert Errors.DepositFailed();
    }

    fallback() external payable {
        revert Errors.DepositFailed();
    }
}
