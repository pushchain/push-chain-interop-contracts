// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { UniversalPayload } from "../libraries/Types.sol";
import { IPRC20 } from "../Interfaces/IPRC20.sol";

// ============================================================
//  Local type re-declaration for UGPC outbound call.
//  Mirrors TypesUGPC.sol from push-chain-gateway-contracts.
// ============================================================

struct UniversalOutboundTxRequest {
    bytes recipient;
    address token;
    uint256 amount;
    uint256 gasLimit;
    bytes payload;
    address revertRecipient;
}

/// @dev Minimal interface for calling UGPC.sendUniversalTxOutbound().
interface IUniversalGatewayPC {
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable;
}

/**
 * @title   StakingExample
 * @notice  Demonstration contract showing how a custom Push Chain contract
 *          (non-UEA) can:
 *          1. Trigger outbound txs to external chains via UGPC.
 *          2. Receive inbound cross-chain calls from its CEA, delivered
 *             by the UNIVERSAL_EXECUTOR_MODULE.
 *
 * @dev     Upgradeable via transparent proxy (ERC1967). Deployed behind a
 *          TransparentUpgradeableProxy on Push Chain. A CEA is deployed on
 *          an external chain (e.g., BSC testnet) with `pushAccount` set to
 *          the proxy address.
 *
 *          -- Outbound flow --
 *          Owner calls `triggerOutbound()` on this contract. The contract
 *          calls `UGPC.sendUniversalTxOutbound(req)`, which burns PRC20
 *          tokens and emits an event. The TSS network picks up the event
 *          and deploys + executes the CEA on the external chain.
 *
 *          -- Inbound flow --
 *          The CEA on the external chain executes and sends a response
 *          back to Push Chain. The UNIVERSAL_EXECUTOR_MODULE delivers
 *          the payload by calling `executeUniversalTx()` on this contract.
 *          The contract decodes the UniversalPayload.data and acts on it.
 *
 *          -- Payload.data encoding --
 *          abi.encode(uint8 action, address user, bytes executionPayload)
 *
 *          Actions:
 *          - 0 = STAKE:   record a stake for `user`
 *          - 1 = UNSTAKE: reduce stake for `user`
 */
contract StakingExample is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // =========================
    //    STATE
    // =========================

    /// @notice The privileged executor module — only address allowed to
    ///         deliver inbound cross-chain payloads.
    address public universalExecutorModule;

    /// @notice UGPC address on Push Chain for triggering outbound txs.
    address public ugpc;

    /// @notice Contract owner.
    address public owner;

    /// @notice Replay protection — tracks executed cross-chain tx IDs.
    mapping(bytes32 => bool) public executedTxIds;

    /// @notice Simple ledger: user => token => staked amount.
    mapping(address => mapping(address => uint256)) public stakedBalance;

    // =========================
    //    EVENTS
    // =========================

    /// @notice Emitted when an outbound tx is triggered from this contract.
    event OutboundTriggered(address indexed token, bytes recipient, uint256 amount, bytes payload);

    /// @notice Emitted when an inbound cross-chain payload is received.
    event InboundReceived(
        bytes32 indexed txId, string sourceChainNamespace, bytes ceaAddress, address prc20, uint256 amount
    );

    /// @notice Emitted when a cross-chain stake is recorded.
    event Staked(address indexed user, address indexed token, uint256 amount, bytes32 indexed txId);

    /// @notice Emitted when a user unstakes directly on Push Chain.
    event Unstaked(address indexed user, address indexed token, uint256 amount);

    // =========================
    //    ERRORS
    // =========================

    error NotOwner();
    error NotExecutorModule();
    error TxAlreadyExecuted();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error UnsupportedAction();
    error ExpiredDeadline();

    // =========================
    //    MODIFIERS
    // =========================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyUniversalExecutor() {
        if (msg.sender != universalExecutorModule) {
            revert NotExecutorModule();
        }
        _;
    }

    // =========================
    //    CONSTRUCTOR & INITIALIZER
    // =========================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for the upgradeable contract.
    /// @param _ugpc                     UniversalGatewayPC address on Push Chain.
    /// @param _universalExecutorModule  Universal Executor Module address.
    /// @param _owner                    Owner address for admin operations.
    function initialize(address _ugpc, address _universalExecutorModule, address _owner) external initializer {
        if (_ugpc == address(0) || _universalExecutorModule == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        __ReentrancyGuard_init();

        ugpc = _ugpc;
        universalExecutorModule = _universalExecutorModule;
        owner = _owner;
    }

    // =========================
    //    OUTBOUND: Push Chain → External Chain
    // =========================

    /// @notice Trigger an outbound tx from Push Chain to an external chain.
    /// @dev    The caller must have already transferred PRC20 tokens to this
    ///         contract (or this contract must hold sufficient PRC20 balance).
    ///         This contract approves UGPC to pull the tokens, then calls
    ///         `sendUniversalTxOutbound`.
    ///
    ///         `msg.value` must cover gas fees + protocol fee (paid in native PC).
    ///
    /// @param token            PRC20 token address on Push Chain.
    /// @param amount           Amount of PRC20 to burn/bridge.
    /// @param recipient        CEA or target address on the external chain (bytes-encoded).
    /// @param gasLimit         Gas limit for the external-chain execution (0 = default).
    /// @param payload          Calldata for the CEA to execute on the external chain.
    /// @param revertRecipient  Address to receive funds if the tx reverts on external chain.
    function triggerOutbound(
        address token,
        uint256 amount,
        bytes calldata recipient,
        uint256 gasLimit,
        bytes calldata payload,
        address revertRecipient
    ) external payable nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (revertRecipient == address(0)) revert ZeroAddress();

        if (amount > 0) {
            IPRC20(token).approve(ugpc, amount);
        }

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: recipient,
            token: token,
            amount: amount,
            gasLimit: gasLimit,
            payload: payload,
            revertRecipient: revertRecipient
        });

        IUniversalGatewayPC(ugpc).sendUniversalTxOutbound{ value: msg.value }(req);

        emit OutboundTriggered(token, recipient, amount, payload);
    }

    // =========================
    //    INBOUND: External Chain → Push Chain
    // =========================

    /// @notice Called by the UNIVERSAL_EXECUTOR_MODULE to deliver an inbound
    ///         cross-chain payload from a CEA on an external chain.
    /// @dev    Mirrors the UEA interface so the module can call the same
    ///         function name. The UniversalPayload.data field encodes:
    ///         abi.encode(uint8 action, address user, bytes executionPayload)
    ///
    ///         Security: only universalExecutorModule can call.
    ///         Replay protection: each txId can only be executed once.
    ///
    /// @param sourceChainNamespace  CAIP-2 chain ID (e.g., "eip155:97")
    /// @param ceaAddress            CEA address on the source chain (bytes-encoded)
    /// @param payload               UniversalPayload containing the action in .data
    /// @param amount                Amount of PRC20 tokens bridged with this inbound tx
    /// @param prc20                 PRC20 token address on Push Chain
    /// @param txId                  Unique cross-chain transaction identifier
    function executeUniversalTx(
        string calldata sourceChainNamespace,
        bytes calldata ceaAddress,
        bytes calldata payload,
        uint256 amount,
        address prc20,
        bytes32 txId
    ) external payable onlyUniversalExecutor nonReentrant {
        if (executedTxIds[txId]) revert TxAlreadyExecuted();
        executedTxIds[txId] = true;

        // if (payload.deadline > 0 && block.timestamp > payload.deadline) {
        //     revert ExpiredDeadline();
        // }

        _handleInboundPayload(payload, prc20, amount, txId);

        emit InboundReceived(txId, sourceChainNamespace, ceaAddress, prc20, amount);
    }

    // =========================
    //    DIRECT STAKING (Push Chain users)
    // =========================

    /// @notice Stake PRC20 tokens directly on Push Chain (no cross-chain).
    /// @param token  PRC20 token to stake.
    /// @param amount Amount to stake.
    function stake(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        stakedBalance[msg.sender][token] += amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, token, amount, bytes32(0));
    }

    /// @notice Unstake PRC20 tokens and withdraw them.
    /// @param token  PRC20 token to unstake.
    /// @param amount Amount to unstake.
    function unstake(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[msg.sender][token] < amount) {
            revert InsufficientStake();
        }

        stakedBalance[msg.sender][token] -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, token, amount);
    }

    // =========================
    //    ADMIN
    // =========================

    /// @notice Update the UGPC address.
    /// @param newUgpc New UGPC address.
    function setUgpc(address newUgpc) external {
        if (newUgpc == address(0)) revert ZeroAddress();
        ugpc = newUgpc;
    }

    /// @notice Update the Universal Executor Module address.
    /// @param newModule New module address.
    function setUniversalExecutorModule(address newModule) external {
        if (newModule == address(0)) revert ZeroAddress();
        universalExecutorModule = newModule;
    }

    /// @notice Transfer ownership to a new address.
    /// @param newOwner New owner address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // =========================
    //    VIEW
    // =========================

    /// @notice Returns the staked balance for a user and token.
    function getStake(address user, address token) external view returns (uint256) {
        return stakedBalance[user][token];
    }

    // =========================
    //    INTERNAL
    // =========================

    /// @dev Decodes UniversalPayload.data and dispatches to stake or unstake.
    ///      Expected format: abi.encode(uint8 action, address user, bytes executionPayload)
    ///      executionPayload is reserved for future use (e.g., forwarding a call
    ///      to another contract on Push Chain after staking).
    /// @param data    The .data field from UniversalPayload
    /// @param prc20   PRC20 token address bridged with this inbound tx
    /// @param amount  Amount of PRC20 tokens bridged
    /// @param txId    Cross-chain transaction identifier
    function _handleInboundPayload(bytes calldata data, address prc20, uint256 amount, bytes32 txId) internal {
        (uint8 action, address user,) = abi.decode(data, (uint8, address, bytes));

        if (user == address(0)) revert ZeroAddress();
        if (prc20 == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (action == 0) {
            stakedBalance[user][prc20] += amount;
            emit Staked(user, prc20, amount, txId);
        } else if (action == 1) {
            if (stakedBalance[user][prc20] < amount) {
                revert InsufficientStake();
            }
            stakedBalance[user][prc20] -= amount;
            emit Unstaked(user, prc20, amount);
        } else {
            revert UnsupportedAction();
        }
    }

    // =========================
    //    RECEIVE
    // =========================

    /// @notice Accept native PC (for gas refunds, cross-chain value transfers).
    receive() external payable { }
}
