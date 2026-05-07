// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  UniversalGatewayPC
 * @notice Outbound gateway on Push Chain for bridging funds and payloads to external EVM chains.
 *
 * @dev    Deployed on Push Chain only. Routes three outbound TX_TYPEs: FUNDS, FUNDS_AND_PAYLOAD,
 *         and GAS_AND_PAYLOAD. PRC20 tokens are burned at request time; gas fees paid in native PC
 *         are swapped via UniversalCore — the gas-cost portion is burned (freeing backing tokens
 *         for TSS relayers). The protocol fee is collected as native PC and sent directly to VaultPC.
 */

import { Errors } from "./libraries/Errors.sol";
import { IPRC20 } from "./interfaces/IPRC20.sol";
import { IPC20 } from "./interfaces/IPC20.sol";
import { IVaultPC } from "./interfaces/IVaultPC.sol";
import { IVaultPC20 } from "./interfaces/IVaultPC20.sol";
import { IUniversalCore } from "./interfaces/IUniversalCore.sol";
import { IUniversalGatewayPC } from "./interfaces/IUniversalGatewayPC.sol";
import { TX_TYPE } from "./libraries/Types.sol";
import { UniversalOutboundTxRequest, PC20ExportRequest } from "./libraries/TypesUGPC.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract UniversalGatewayPC is
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IUniversalGatewayPC
{
    using SafeERC20 for IERC20;

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice MUTABLE — admin-updatable via updateUniversalCore.
    address public universalCore;
    /// @notice MUTABLE — admin-updatable via updateVaultPC.
    IVaultPC public vaultPC;
    uint256 public nonce;
    /// @notice MUTABLE — admin-updatable via updateVaultPC20.
    IVaultPC20 public vaultPC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    // ==============================
    //    UGPC_1: ADMIN ACTIONS
    // ==============================

    /// @param admin            Address of the admin.
    /// @param pauser           Address of the pauser.
    /// @param _universalCore   Address of the UniversalCore.
    /// @param _vaultPC         Address of the VaultPC.
    function initialize(address admin, address pauser, address _universalCore, address _vaultPC) external initializer {
        if (admin == address(0) || pauser == address(0) || _universalCore == address(0) || _vaultPC == address(0)) {
            revert Errors.ZeroAddress();
        }

        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControlDefaultAdminRules_init(1 days, admin);

        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        universalCore = _universalCore;
        vaultPC = IVaultPC(_vaultPC);
    }

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(OPERATOR_ROLE) whenPaused {
        _unpause();
    }

    /// @notice                Sets the VaultPC address.
    /// @param _vaultPC        Address of the new VaultPC.
    function updateVaultPC(address _vaultPC) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (_vaultPC == address(0)) revert Errors.ZeroAddress();
        address oldVaultPC = address(vaultPC);
        vaultPC = IVaultPC(_vaultPC);
        emit VaultPCUpdated(oldVaultPC, _vaultPC);
    }

    /// @notice                Sets the UniversalCore address.
    /// @dev                   Allows admin to re-point the UniversalCore dependency without
    ///                        requiring a proxy upgrade. Mirrors setVaultPC.
    /// @param _universalCore  Address of the new UniversalCore.
    function updateUniversalCore(address _universalCore) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (_universalCore == address(0)) revert Errors.ZeroAddress();
        address oldUniversalCore = universalCore;
        universalCore = _universalCore;
        emit UniversalCoreUpdated(oldUniversalCore, _universalCore);
    }

    /// @inheritdoc IUniversalGatewayPC
    function updateVaultPC20(address _vaultPC20) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (_vaultPC20 == address(0)) revert Errors.ZeroAddress();
        address oldVaultPC20 = address(vaultPC20);
        vaultPC20 = IVaultPC20(_vaultPC20);
        emit VaultPC20Updated(oldVaultPC20, _vaultPC20);
    }

    // ==============================
    //    UGPC_2: OUTBOUND TX
    // ==============================

    /// @inheritdoc IUniversalGatewayPC
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _validateParams(req.token, req.revertRecipient);

        TX_TYPE txType = _fetchTxType(req);

        (
            address gasToken,
            uint256 gasFee,
            uint256 gasLimitUsed,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace
        ) = _fetchOutboundTxGasAndFees(req.token, req.gasLimit);

        if (req.gasPrice > 0) {
            if (req.gasPrice < gasPrice) revert Errors.GasPriceBelowBase();
            gasPrice = req.gasPrice;
            gasFee = gasPrice * gasLimitUsed;
        }

        if (req.amount > 0) {
            _burnPRC20(msg.sender, req.token, req.amount);
        }

        if (msg.value < protocolFee) revert Errors.InvalidInput();
        if (protocolFee > 0) {
            (bool ok,) = address(vaultPC).call{ value: protocolFee }("");
            if (!ok) revert Errors.InvalidInput();
        }
        uint256 pcForSwap = msg.value - protocolFee;
        if (req.maxPCForGas != 0) {
            if (req.maxPCForGas > pcForSwap) revert Errors.InvalidAmount();
            uint256 excess = pcForSwap - req.maxPCForGas;
            pcForSwap = req.maxPCForGas;
            if (excess > 0) {
                (bool refundOk,) = msg.sender.call{ value: excess }("");
                if (!refundOk) revert Errors.WithdrawFailed();
            }
        }
        _swapAndCollectFees(gasToken, pcForSwap, gasFee);

        uint256 currentNonce = nonce;
        nonce = currentNonce + 1;

        bytes32 subTxId = keccak256(
            abi.encode(
                msg.sender, req.recipient, req.token, req.amount, keccak256(req.payload), chainNamespace, currentNonce
            )
        );

        emit UniversalTxOutbound(
            subTxId,
            msg.sender,
            chainNamespace,
            req.token,
            req.recipient,
            req.amount,
            gasToken,
            gasFee,
            gasLimitUsed,
            req.payload,
            protocolFee,
            req.revertRecipient,
            txType,
            gasPrice
        );
    }

    /// @inheritdoc IUniversalGatewayPC
    function rescueFundsOnSourceChain(
        bytes32 universalTxId,
        address prc20
    ) external payable whenNotPaused nonReentrant {
        if (prc20 == address(0)) revert Errors.ZeroAddress();

        (
            address gasToken,
            uint256 gasFee,
            uint256 rescueGasLimit,
            uint256 gasPrice,
            string memory chainNamespace
        ) = IUniversalCore(universalCore).getRescueFundsGasLimit(prc20);

        _swapAndCollectFees(gasToken, msg.value, gasFee);

        emit RescueFundsOnSourceChain(
            universalTxId,
            prc20,
            chainNamespace,
            msg.sender,
            TX_TYPE.RESCUE_FUNDS,
            gasFee,
            gasPrice,
            rescueGasLimit
        );
    }

    // ==============================
    //    UGPC_4: PC20 EXPORT
    // ==============================

    /// @inheritdoc IUniversalGatewayPC
    function exportPC20(PC20ExportRequest calldata req)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        // 1. VALIDATION
        if (req.token == address(0)) revert Errors.ZeroAddress();
        if (req.amount == 0) revert Errors.ZeroAmount();
        if (req.revertRecipient == address(0)) revert Errors.InvalidRecipient();
        if (req.recipient.length == 0) revert Errors.InvalidRecipient();
        if (bytes(req.destChainNamespace).length == 0) revert Errors.InvalidData();
        IPC20(req.token).pc20Metadata();

        // 2. FEE QUOTE
        (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            uint256 gasLimitUsed
        ) = _fetchPC20ExportGasAndFees(req.destChainNamespace, req.gasLimit, req.token);

        // 3. LOCK PC20 IN VAULTPC20
        IERC20(req.token).safeTransferFrom(msg.sender, address(vaultPC20), req.amount);
        vaultPC20.recordLock(req.token, req.amount);

        // 4. PROTOCOL FEE COLLECTION
        if (msg.value < protocolFee) revert Errors.InvalidInput();
        if (protocolFee > 0) {
            (bool ok,) = address(vaultPC).call{value: protocolFee}("");
            if (!ok) revert Errors.InvalidInput();
        }
        uint256 pcForSwap = msg.value - protocolFee;

        // 5. GAS SWAP CAP (maxPCForGas)
        if (req.maxPCForGas != 0) {
            if (req.maxPCForGas > pcForSwap) revert Errors.InvalidAmount();
            uint256 excess = pcForSwap - req.maxPCForGas;
            pcForSwap = req.maxPCForGas;
            if (excess > 0) {
                (bool refundOk,) = msg.sender.call{value: excess}("");
                if (!refundOk) revert Errors.WithdrawFailed();
            }
        }

        // 6. GAS SWAP AND BURN
        _swapAndCollectFees(gasToken, pcForSwap, gasFee);

        // 7. NONCE AND SUBTXID
        uint256 currentNonce = nonce;
        nonce = currentNonce + 1;

        bytes32 subTxId = keccak256(
            abi.encode(
                msg.sender,
                req.recipient,
                req.token,
                req.amount,
                keccak256(req.payload),
                req.destChainNamespace,
                currentNonce
            )
        );

        // 8. EVENT EMISSION
        emit PC20ExportInitiated(
            subTxId,
            msg.sender,
            req.destChainNamespace,
            req.token,
            req.recipient,
            req.amount,
            gasToken,
            gasFee,
            gasLimitUsed,
            req.payload,
            protocolFee,
            req.revertRecipient,
            gasPrice
        );
    }

    // ==============================
    //   UGPC_3: INTERNAL HELPERS
    // ==============================

    /// @dev                    Infers TX_TYPE from the outbound request.
    ///                         - amount > 0, no payload  → FUNDS
    ///                         - amount > 0, payload     → FUNDS_AND_PAYLOAD
    ///                         - amount = 0, payload     → GAS_AND_PAYLOAD
    ///                         - amount = 0, no payload  → reverts (empty tx)
    /// @param req              The outbound transaction request.
    /// @return inferred        The inferred TX_TYPE.
    function _fetchTxType(UniversalOutboundTxRequest calldata req) private pure returns (TX_TYPE inferred) {
        bool hasPayload = req.payload.length > 0;
        bool hasFunds = req.amount > 0;

        if (!hasPayload && hasFunds) return TX_TYPE.FUNDS;
        if (hasPayload && hasFunds) return TX_TYPE.FUNDS_AND_PAYLOAD;
        if (hasPayload && !hasFunds) return TX_TYPE.GAS_AND_PAYLOAD;

        revert Errors.InvalidInput();
    }

    /// @dev                    Validates token and revertRecipient are non-zero.
    /// @param token            Token address to validate.
    /// @param revertRecipient  Address to receive funds in case of revert.
    function _validateParams(address token, address revertRecipient) internal pure {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (revertRecipient == address(0)) {
            revert Errors.InvalidRecipient();
        }
    }

    /// @dev                    Fetch gas fee quote and chain metadata from UniversalCore.
    ///                         If gasLimit = 0, UniversalCore resolves it to the per-chain
    ///                         baseGasLimitByChainNamespace and returns it as gasLimitUsed.
    /// @param token            PRC20 token address (used to resolve chain).
    /// @param gasLimit         Caller-requested gas limit (0 = default).
    /// @return gasToken        Gas token PRC20 address for the target chain.
    /// @return gasFee          Gas cost in gas token units (excludes protocol fee).
    /// @return gasLimitUsed    Gas limit actually used for the quote.
    /// @return protocolFee     Protocol fee in native PC (from UniversalCore.protocolFeeByToken mapping).
    /// @return gasPrice        Gas price on the external chain (wei per gas unit).
    /// @return chainNamespace  Chain namespace string for the target chain.
    function _fetchOutboundTxGasAndFees(address token, uint256 gasLimit)
        internal
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 gasLimitUsed,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace
        )
    {
        (gasToken, gasFee, protocolFee, gasPrice, chainNamespace, gasLimitUsed) =
            IUniversalCore(universalCore).getOutboundTxGasAndFees(token, gasLimit);

        if (gasToken == address(0) || gasFee + protocolFee == 0) {
            revert Errors.InvalidData();
        }
    }

    /// @dev                    Swap native PC → gas token PRC20 via UniversalCore.
    ///                         Burns gasFee. Refunds unused PC to caller.
    /// @param gasToken         Gas token PRC20 address (e.g., pETH).
    /// @param pcAmount         Native PC amount (msg.value minus protocolFee) to swap.
    /// @param gasFee           Gas cost portion to burn (in gas token units).
    function _swapAndCollectFees(address gasToken, uint256 pcAmount, uint256 gasFee) internal {
        if (pcAmount == 0) revert Errors.ZeroAmount();

        IUniversalCore(universalCore).swapAndBurnGas{ value: pcAmount }(gasToken, 0, gasFee, 0, msg.sender);
    }

    /// @dev                    Fetch gas fee quote for a PC20 export from UniversalCore.
    /// @param destChainNamespace Destination chain (CAIP-2)
    /// @param gasLimit          Caller-requested gas limit (0 = default)
    /// @param pc20Token         PC20 token address (for protocol fee lookup)
    function _fetchPC20ExportGasAndFees(
        string calldata destChainNamespace,
        uint256 gasLimit,
        address pc20Token
    )
        internal
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            uint256 gasLimitUsed
        )
    {
        (gasToken, gasFee, protocolFee, gasPrice,, gasLimitUsed,) =
            IUniversalCore(universalCore).getPC20ExportGasAndFees(destChainNamespace, gasLimit, pc20Token);

        if (gasToken == address(0) || gasFee + protocolFee == 0) {
            revert Errors.InvalidData();
        }
    }

    /// @dev                    Pulls PRC20 from `from` into this contract, then burns them.
    /// @param from             Address to pull tokens from.
    /// @param token            PRC20 token address.
    /// @param amount           Amount to burn.
    function _burnPRC20(address from, address token, uint256 amount) internal {
        bool transferred = IPRC20(token).transferFrom(from, address(this), amount);
        if (!transferred) revert Errors.TokenTransferFailed(token, amount);
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);
    }
}
