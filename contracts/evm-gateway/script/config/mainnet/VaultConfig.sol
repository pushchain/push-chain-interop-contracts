// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  VaultConfig (Mainnet)
/// @notice Per-chain deployment parameters for Vault on mainnet chains.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract VaultConfig {
    struct Config {
        // --- Core addresses ---
        address deployer;
        address gateway; // Can be address(0) initially, set via setGateway()
        address ceaFactory; // Must be deployed first
        address vaultProxy; // address(0) for fresh deploys, set for upgrades
        // --- Role addresses (must NOT default to deployer on mainnet) ---
        address tssAddress;
        address admin; // multisig
        address pauser;
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 1) return _ethereumMainnet();
        if (id == 42161) return _arbitrumOne();
        if (id == 56) return _bscMainnet();
        if (id == 8453) return _baseMainnet();

        revert("VaultConfig: unsupported mainnet chain");
    }

    // =====================================================================
    //  Ethereum Mainnet (Chain ID: 1)
    // =====================================================================

    function _ethereumMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            gateway: address(0), // TODO: Set after Gateway deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            vaultProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0) // TODO: Set before deployment
        });
    }

    // =====================================================================
    //  Arbitrum One (Chain ID: 42161)
    // =====================================================================

    function _arbitrumOne() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            gateway: address(0), // TODO: Set after Gateway deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            vaultProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0) // TODO: Set before deployment
        });
    }

    // =====================================================================
    //  BSC Mainnet (Chain ID: 56)
    // =====================================================================

    function _bscMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            gateway: address(0), // TODO: Set after Gateway deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            vaultProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0) // TODO: Set before deployment
        });
    }

    // =====================================================================
    //  Base Mainnet (Chain ID: 8453)
    // =====================================================================

    function _baseMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            gateway: address(0), // TODO: Set after Gateway deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            vaultProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0) // TODO: Set before deployment
        });
    }
}
