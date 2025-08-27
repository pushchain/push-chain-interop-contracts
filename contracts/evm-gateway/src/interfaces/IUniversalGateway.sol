// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertSettings, UniversalPayload} from "../libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory, ISwapRouter} from "./IAMMInterface.sol";

interface IUniversalGateway {

    // =========================
    //           EVENTS
    // =========================

    /// @dev Universal tx deposit (gas funding). Revert settings flattened for indexers.
    event DepositForUniversalTx(
        address indexed sender,
        bytes32 payloadHash,
        uint256 nativeTokenDeposited,
        bytes   _data,
        RevertSettings revertCFG
    );

    /// @dev Asset bridge deposit (lock on gateway). Revert settings flattened for indexers.
    event DepositForBridge(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        address tokenAddress,           // address(0) if native
        bytes   data,
        RevertSettings revertCFG
    );

    event Withdraw(address indexed recipient, uint256 amount, address tokenAddress);
    event TSSAddressUpdated(address oldTSS, address newTSS);
    event TokenSupportModified(address tokenAddress, bool whitelistStatus);
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);
    event RoutersUpdated(address uniswapFactory, address uniswapRouter);
    event PausedBy(address account);
    event UnpausedBy(address account);

    // =========================
    //         FUNCTIONS
    // =========================

    /// @notice Main user-facing deposit functions
    function depositForUniversalTx(
        UniversalPayload calldata payload,
        bytes   calldata _data,
        RevertSettings calldata revertCFG
    ) external payable;

    function depositForAssetBridge(
        address recipient,
        address token,
        uint256 amount,
        bytes   calldata _data,
        RevertSettings calldata revertCFG
    ) external payable;

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
