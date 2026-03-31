// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  VaultPCConfig
/// @notice Per-chain deployment parameters for VaultPC.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract VaultPCConfig {
    struct Config {
        address deployer;
        address vaultPCProxy; // Set for upgrades, address(0) for fresh deploys
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 42101) return _pushChainTestnet();

        revert("VaultPCConfig: unsupported chain");
    }

    // =====================================================================
    //  Push Chain Testnet (Chain ID: 42101)
    // =====================================================================

    function _pushChainTestnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            vaultPCProxy: address(0) // TODO: Set for upgrades
        });
    }
}
