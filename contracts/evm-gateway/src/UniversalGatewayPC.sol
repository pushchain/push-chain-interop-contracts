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
import { IVaultPC } from "./interfaces/IVaultPC.sol";
import { IUniversalCore } from "./interfaces/IUniversalCore.sol";
import { IUniversalGatewayPC } from "./interfaces/IUniversalGatewayPC.sol";
import { TX_TYPE } from "./libraries/Types.sol";
import { UniversalOutboundTxRequest } from "./libraries/TypesUGPC.sol";


import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract UniversalGatewayPC is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IUniversalGatewayPC
{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice MUTABLE — admin-updatable via setUniversalCore.
    address public UNIVERSAL_CORE;
    /// @notice MUTABLE — admin-updatable via setVaultPC.
    IVaultPC public VAULT_PC;
    uint256 public nonce;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    // ==============================
    //    UGPC_1: ADMIN ACTIONS
    // ==============================

    /// @param admin            Address of the admin.
    /// @param pauser           Address of the pauser.
    /// @param universalCore    Address of the UniversalCore.
    /// @param vaultPC          Address of the VaultPC.
    function initialize(address admin, address pauser, address universalCore, address vaultPC) external initializer {
        if (admin == address(0) || pauser == address(0) || universalCore == address(0) || vaultPC == address(0)) {
            revert Errors.ZeroAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        UNIVERSAL_CORE = universalCore;
        VAULT_PC = IVaultPC(vaultPC);
    }

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }

    /// @notice                Sets the VaultPC address.
    /// @param vaultPC         Address of the new VaultPC.
    function setVaultPC(address vaultPC) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (vaultPC == address(0)) revert Errors.ZeroAddress();
        address oldVaultPC = address(VAULT_PC);
        VAULT_PC = IVaultPC(vaultPC);
        emit VaultPCUpdated(oldVaultPC, vaultPC);
    }

    /// @notice                Sets the UniversalCore address.
    /// @dev                   Allows admin to re-point the UniversalCore dependency without
    ///                        requiring a proxy upgrade. Mirrors setVaultPC.
    /// @param universalCore   Address of the new UniversalCore.
    function setUniversalCore(address universalCore) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (universalCore == address(0)) revert Errors.ZeroAddress();
        address oldUniversalCore = UNIVERSAL_CORE;
        UNIVERSAL_CORE = universalCore;
        emit UniversalCoreUpdated(oldUniversalCore, universalCore);
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

        if (!IUniversalCore(UNIVERSAL_CORE).isSupportedToken(req.token)) revert Errors.NotSupported();

        TX_TYPE txType = _fetchTxType(req);

        (
            address gasToken,
            uint256 gasFee,
            uint256 gasLimitUsed,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace
        ) = _fetchOutboundTxGasAndFees(req.token, req.gasLimit);

        if (req.amount > 0) {
            _burnPRC20(msg.sender, req.token, req.amount);
        }

        if (msg.value < protocolFee) revert Errors.InvalidInput();
        if (protocolFee > 0) {
            (bool ok,) = address(VAULT_PC).call{ value: protocolFee }("");
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
        ) = IUniversalCore(UNIVERSAL_CORE).getRescueFundsGasLimit(prc20);

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
    ///                         If gasLimit = 0, uses BASE_GAS_LIMIT from UniversalCore.
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
        gasLimitUsed = gasLimit == 0 ? IUniversalCore(UNIVERSAL_CORE).BASE_GAS_LIMIT() : gasLimit;

        (gasToken, gasFee, protocolFee, gasPrice, chainNamespace) =
            IUniversalCore(UNIVERSAL_CORE).getOutboundTxGasAndFees(token, gasLimitUsed);

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

        IUniversalCore(UNIVERSAL_CORE).swapAndBurnGas{ value: pcAmount }(gasToken, 0, gasFee, 0, msg.sender);
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
