// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertSettings, UniversalPayload, TX_TYPE} from "../libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ISwapRouter as ISwapRouterV3} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IUniversalGateway {

    // =========================
    //           EVENTS
    // =========================

    /// @dev Universal tx deposit (gas funding). Revert settings flattened for indexers.
    event DepositForInstantTx(
        address indexed sender,
        bytes32 payloadHash,
        uint256 nativeTokenDeposited,
        RevertSettings revertCFG,
        TX_TYPE txType
    );

    /// @dev Asset bridge deposit (lock on gateway). Revert settings flattened for indexers.
    event DepositForUniversalTx(
        address indexed sender,
        address indexed recipient,      // address(0) for moving funds + payload for execution.
        address bridgeToken,
        uint256 bridgeAmount,
        uint256 gasAmount,
        bytes   data,
        RevertSettings revertCFG,
        TX_TYPE txType
    );

    event Withdraw(address indexed recipient, uint256 amount, address tokenAddress);
    event TSSAddressUpdated(address oldTSS, address newTSS);
    event TokenSupportModified(address tokenAddress, bool whitelistStatus);
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);
    event PoolStatusChanged(bool enabled);

    // =========================
    //         FUNCTIONS
    // =========================

    /// @notice Main user-facing deposit functions
    function depositForInstantTx(
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable;

    function depositForInstantTx_Token(
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG,
        uint256 amountOutMinETH,
        uint256 deadline
    ) external;

    function depositForUniversalTxFunds(
        address recipient,
        address token,
        uint256 amount,
        RevertSettings calldata revertCFG
    ) external payable;

    function depositForUniversalTxFundsAndPayload(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable;

    function depositForUniversalTxFundsAndPayload_Token(
        address token,
        uint256 amount,
        address gasToken,
        uint256 gasAmount,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external;

    /// @notice Withdraw functions (TSS-only)
    function withdraw(
        address recipient,
        address token,
        uint256 amount
    ) external;

    function revertWithdraw(
        address token,
        uint256 amount,
        RevertSettings calldata revertCfg
    ) external;
}
