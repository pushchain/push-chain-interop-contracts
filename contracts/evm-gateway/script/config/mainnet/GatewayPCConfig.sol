// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  GatewayPCConfig (Mainnet)
/// @notice Per-chain deployment parameters for UniversalGatewayPC on Push Chain mainnet.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract GatewayPCConfig {
    struct Config {
        address deployer;
        address universalCore;
        address vaultPC; // Must be deployed first
        address gatewayPCProxy; // Set for upgrades, address(0) for fresh deploys
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        // TODO: Replace 0 with Push Chain mainnet chain ID
        if (id == 0) return _pushChainMainnet();

        revert("GatewayPCConfig: unsupported mainnet chain");
    }

    // =====================================================================
    //  Push Chain Mainnet (Chain ID: TODO)
    // =====================================================================

    function _pushChainMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            universalCore: address(0), // TODO: Set before deployment
            vaultPC: address(0), // TODO: Set after VaultPC deployment
            gatewayPCProxy: address(0) // TODO: Set for upgrades
        });
    }
}
