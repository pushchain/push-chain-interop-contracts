// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertSettings, UniversalPayload, TX_TYPE } from "../libraries/Types.sol";

interface IUniversalGateway {
    // =========================
    //           EVENTS
    // =========================

    /// @dev Universal tx deposit (gas funding). Revert settings flattened for indexers.
    event TxWithGas(
        address indexed sender, bytes payload, uint256 nativeTokenDeposited, RevertSettings revertCFG, TX_TYPE txType
    );
    /// @dev Asset bridge deposit (lock on gateway). Revert settings flattened for indexers.
    event TxWithFunds( // address(0) for moving funds + payload for execution.
        address indexed sender,
        address indexed recipient,
        address bridgeToken,
        uint256 bridgeAmount,
        bytes payload,
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

    /// @notice Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain.
    /// @dev    Supports 2 TX types:
    ///          a. GAS.
    ///          b. GAS_AND_PAYLOAD.
    ///         Note: Any TX initiated via fee abstraction route requires lower block confirmations for execution on Push Chain.
    ///         Hence, the deposit amount is subject to USD cap checks that is strictly enforced with MIN_CAP_UNIVERSAL_TX_USD and MAX_CAP_UNIVERSAL_TX_USD.
    ///         Gas for this transaction must be paid in the NATIVE token of the source chain.
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
    function sendTxWithGas(UniversalPayload calldata payload, RevertSettings calldata revertCFG) external payable;

    /// @notice Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain with any supported Token.
    /// @dev    Allows users to use any token to fund or execute a payload on Push Chain.
    ///         The deposited token is swapped to native ETH using Uniswap v3.
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
    ) external;

    /// @notice Allows initiating a TX for movement of high value funds from source chain to Push Chain.
    /// @dev    Doesn't support arbitrary execution payload via UEAs. Only allows movement of funds.
    ///         The tokens moved must be supported by the gateway.
    ///         Supports only Universal TX type with high value funds, i.e., high block confirmations are required.
    ///         Supports the TX type - FUNDS.
    /// @param recipient Recipient address
    /// @param bridgeToken Token address to bridge
    /// @param bridgeAmount Amount of token to bridge
    /// @param revertCFG Revert settings
    function sendFunds(address recipient, address bridgeToken, uint256 bridgeAmount, RevertSettings calldata revertCFG)
        external
        payable;

    /// @notice Allows initiating a TX for movement of funds and payload from source chain to Push Chain.
    /// @dev    Supports arbitrary execution payload via UEAs.
    ///         The tokens moved must be supported by the gateway.
    ///         Supports the TX type - FUNDS_AND_PAYLOAD.
    ///         Gas for this transaction must be paid in the NATIVE token of the source chain.
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
    ) external payable;

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
    /// @param amountOutMinETH Minimum ETH expected (slippage protection)
    /// @param deadline Swap deadline
    /// @param payload Universal payload to execute on Push Chain
    /// @param revertCFG Revert settings
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertSettings calldata revertCFG
    ) external;

    /// @notice Withdraw functions (TSS-only)

    /// @notice TSS-only withdraw (unlock) to an external recipient on Push Chain.
    /// @param recipient   destination address
    /// @param token       address(0) for native; ERC20 otherwise
    /// @param amount      amount to withdraw
    function withdrawFunds(address recipient, address token, uint256 amount) external;

    /// @notice Refund (revert) path controlled by TSS (e.g., failed universal/bridge).
    ///         Sends funds to revertCFG.fundRecipient using same rules as withdraw.
    /// @param token       address(0) for native; ERC20 otherwise
    /// @param amount      amount to refund
    /// @param revertCFG   (fundRecipient, revertMsg)
    function revertWithdrawFunds(address token, uint256 amount, RevertSettings calldata revertCFG) external;
}
