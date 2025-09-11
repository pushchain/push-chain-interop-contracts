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
    event TxWithGas(
        address indexed sender,
        bytes payload,
        uint256 nativeTokenDeposited,
        RevertSettings revertCFG,
        TX_TYPE txType
    );

    /// @dev Asset bridge deposit (lock on gateway). Revert settings flattened for indexers.
    event TxWithFunds(
        address indexed sender,
        address indexed recipient,      // address(0) for moving funds + payload for execution.
        address bridgeToken,
        uint256 bridgeAmount,
        bytes   payload,
        RevertSettings revertCFG,
        TX_TYPE txType
    );

    event WithdrawFunds(address indexed recipient, uint256 amount, address tokenAddress);
    event TSSAddressUpdated(address oldTSS, address newTSS);
    event TokenSupportModified(address tokenAddress, bool whitelistStatus);
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);
    
    // Chainlink Oracle Events
    event ChainlinkEthUsdFeedUpdated(address indexed feed, uint8 decimals);
    event ChainlinkStalePeriodUpdated(uint256 stalePeriodSec);
    
    // L2 Sequencer Events
    event L2SequencerFeedUpdated(address indexed feed);
    event L2SequencerGracePeriodUpdated(uint256 gracePeriodSec);
    
    // Swap Configuration Events
    event DefaultSwapDeadlineUpdated(uint256 deadlineSec);

    // =========================
    //         FUNCTIONS
    // =========================

    /// @notice Main user-facing deposit functions
    function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable;

    // function sendTxWithGas(
    //     address tokenIn,
    //     uint256 amountIn,
    //     UniversalPayload calldata payload,
    //     RevertSettings calldata revertCFG,
    //     uint256 amountOutMinETH,
    //     uint256 deadline
    // ) external;

    function sendFunds(
        address recipient,
        address token,
        uint256 amount,
        RevertSettings calldata revertCFG
    ) external payable;

    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external payable;

    // function sendTxWithFunds(
    //     address token,
    //     uint256 amount,
    //     address gasToken,
    //     uint256 gasAmount,
    //     UniversalPayload calldata payload,
    //     RevertSettings calldata revertCFG
    // ) external;

    /// @notice Withdraw functions (TSS-only)
    function withdrawFunds(
        address recipient,
        address token,
        uint256 amount
    ) external;

    function revertWithdrawFunds(
        address token,
        uint256 amount,
        RevertSettings calldata revertCfg
    ) external;
}
