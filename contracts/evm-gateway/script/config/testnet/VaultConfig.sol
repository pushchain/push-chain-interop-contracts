// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  VaultConfig
/// @notice Per-chain deployment parameters for Vault.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract VaultConfig {
    struct Config {
        address deployer;
        address gateway; // Can be address(0) initially, set via setGateway()
        address ceaFactory; // Must be deployed first
        address vaultProxy; // Set for upgrades, address(0) for fresh deploys
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 11155111) return _ethSepolia();
        if (id == 421614) return _arbitrumSepolia();
        if (id == 97) return _bscTestnet();
        if (id == 84532) return _baseSepolia();

        revert("VaultConfig: unsupported chain");
    }

    // =====================================================================
    //  Ethereum Sepolia (Chain ID: 11155111)
    // =====================================================================

    function _ethSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6,
            gateway: 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A,
            ceaFactory: 0x8ED594A83301FEc545fC6c19fc12cF7111777029,
            vaultProxy: 0xD019Eb12D0d6eF8D299661f22B4B7d262eD4b965
        });
    }

    // =====================================================================
    //  Arbitrum Sepolia (Chain ID: 421614)
    // =====================================================================

    function _arbitrumSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xD854DDe7C58eC1B405E6577F48a7cC5b5E6EF317,
            gateway: 0x2cd870e0166Ba458dEC615168Fd659AacD795f34,
            ceaFactory: 0x88DC189275078Cf509E4Cc773F089c8ad07b7EA2,
            vaultProxy: 0x233B1B1B378eb0Aa723097634025A47C4b73A8F7
        });
    }

    // =====================================================================
    //  BSC Testnet (Chain ID: 97)
    // =====================================================================

    function _bscTestnet() private pure returns (Config memory) {
        return Config({
            deployer: 0x6dD2cA20ec82E819541EB43e1925DbE46a441970,
            gateway: 0x44aFFC61983F4348DdddB886349eb992C061EaC0,
            ceaFactory: 0xe2182dae2dc11cBF6AA6c8B1a7f9c8315A6B0719,
            vaultProxy: 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881
        });
    }

    // =====================================================================
    //  Base Sepolia (Chain ID: 84532)
    // =====================================================================

    function _baseSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0x52DEA34AfAaD33Bb16675ED527b1ed80E83ffb09,
            gateway: 0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16,
            ceaFactory: 0x0A75ca7736b488Eb41675ADc3b3156BACF659F55,
            vaultProxy: 0xb4Ba4D5542D1dD48BD3589543660B265B41f16CB
        });
    }
}
