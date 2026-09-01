// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IVaultPC20 } from "../../src/interfaces/IVaultPC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockVaultPC20 is IVaultPC20 {
    mapping(address => uint256) public totalLocked;
    mapping(bytes32 => bool) public isExecuted;

    function recordLock(address token, uint256 amount) external {
        totalLocked[token] += amount;
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= totalLocked[token], "MockVaultPC20: balance < totalLocked");
        emit TokensLocked(token, amount, totalLocked[token]);
    }

    function unlock(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address recipient
    ) external {
        require(!isExecuted[subTxId], "MockVaultPC20: already executed");
        isExecuted[subTxId] = true;
        totalLocked[token] -= amount;
        IERC20(token).transfer(recipient, amount);
        emit TokensUnlocked(subTxId, token, amount, recipient);
    }

    function revertExport(
        bytes32 subTxId,
        address token,
        uint256 amount,
        address revertRecipient
    ) external {
        require(!isExecuted[subTxId], "MockVaultPC20: already executed");
        isExecuted[subTxId] = true;
        totalLocked[token] -= amount;
        IERC20(token).transfer(revertRecipient, amount);
        emit ExportReverted(subTxId, token, amount, revertRecipient);
    }

    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external {
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdrawal(token, to, amount);
    }
}
