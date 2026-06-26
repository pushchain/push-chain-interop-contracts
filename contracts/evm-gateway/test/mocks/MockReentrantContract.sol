// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { UniversalOutboundTxRequest } from "../../src/libraries/TypesUGPC.sol";

/**
 * @title MockReentrantContract
 * @notice Mock contract that attempts to reenter gateway contracts
 * @dev Used for testing reentrancy protection on UniversalGatewayPC and Vault
 */
contract MockReentrantContract {
    address public gateway;
    address public prc20Token;
    address public gasToken;

    // Vault-specific reentrancy state
    address public vault;
    address public vaultPC;
    address public token;
    bool public shouldReenter;
    uint256 public reenterType; // 0=withdraw, 1=withdrawAndCall, 2=revertWithdraw

    constructor(address _gateway, address _prc20Token, address _gasToken) {
        gateway = _gateway;
        prc20Token = _prc20Token;
        gasToken = _gasToken;
    }

    // ============================================================================
    // UniversalGatewayPC Reentrancy Functions
    // ============================================================================

    function attemptReentrancy(uint256 amount, uint256 gasLimit, address revertRecipient) external payable {
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: prc20Token,
            amount: amount,
            gasLimit: gasLimit,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: revertRecipient
        });
        IUniversalGatewayPC(gateway).sendUniversalTxOutbound{value: msg.value}(req);
    }

    function attemptReentrancyWithExecute(
        uint256 amount,
        bytes calldata payload,
        uint256 gasLimit,
        address revertRecipient
    ) external payable {
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: prc20Token,
            amount: amount,
            gasLimit: gasLimit,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: revertRecipient
        });
        IUniversalGatewayPC(gateway).sendUniversalTxOutbound{value: msg.value}(req);
    }

    receive() external payable {}

    // ============================================================================
    // Vault Reentrancy Functions
    // ============================================================================

    function setVault(address _vault) external {
        vault = _vault;
    }

    function setVaultPC(address _vaultPC) external {
        vaultPC = _vaultPC;
    }

    function enableVaultReentry(address _token, uint256 _type) external {
        token = _token;
        shouldReenter = true;
        reenterType = _type;
    }

    function pullTokens(address _token, address from, uint256 amount) external {
        IERC20(_token).transferFrom(from, address(this), amount);

        if (shouldReenter && vault != address(0)) {
            shouldReenter = false; // prevent infinite loop

            // Call vault based on reenter type
            if (reenterType == 0) {
                // Attempt to reenter withdraw
                (bool success,) =
                    vault.call(abi.encodeWithSignature("withdraw(address,address,uint256)", _token, address(this), 1));
                require(success, "Reentry failed");
            } else if (reenterType == 1) {
                // Attempt to reenter withdrawAndCall
                (bool success,) = vault.call(
                    abi.encodeWithSignature(
                        "withdrawAndCall(address,address,uint256,bytes)", _token, address(this), 1, ""
                    )
                );
                require(success, "Reentry failed");
            } else if (reenterType == 2) {
                // Attempt to reenter revertWithdraw
                (bool success,) = vault.call(
                    abi.encodeWithSignature("revertWithdraw(address,address,uint256)", _token, address(this), 1)
                );
                require(success, "Reentry failed");
            }
        }
    }

    // ============================================================================
    // VaultPC Reentrancy Functions
    // ============================================================================

    function attackVaultPCWithdraw(address _token, address to, uint256 amount) external {
        // First call to VaultPC withdraw - this should trigger transferFrom callback
        (bool success,) = vaultPC.call(abi.encodeWithSignature("withdraw(address,address,uint256)", _token, to, amount));
        require(!success, "Attack should have failed due to reentrancy guard");
    }

    // Callback from ERC20 transfer that attempts reentrancy
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        // Attempt to reenter withdraw during the transfer callback
        (bool success,) =
            vaultPC.call(abi.encodeWithSignature("withdraw(address,address,uint256)", msg.sender, address(this), 1));
        // The reentrancy should fail, so we just return true for the original transfer
        return true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
