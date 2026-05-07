// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  IPC20
 * @notice Minimum interface for Push-Chain-originated tokens eligible for cross-chain export.
 * @dev    Any ERC-20 on Push Chain that implements pc20Metadata() can be exported via UGPC.exportPC20().
 */
interface IPC20 is IERC20 {
    /// @notice Returns metadata required for cross-chain export.
    /// @return name          Token name forwarded to destination wrapper
    /// @return symbol        Token symbol forwarded to destination wrapper
    /// @return decimals      Decimal precision preserved on destination
    /// @return originAddress address(this) — canonical source binding
    function pc20Metadata()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals,
            address originAddress
        );
}
