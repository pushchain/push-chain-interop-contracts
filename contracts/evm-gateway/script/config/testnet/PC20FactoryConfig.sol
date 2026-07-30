// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  PC20FactoryConfig
/// @notice Per-chain deployment parameters for PC20Factory.

abstract contract PC20FactoryConfig {
    struct Config {
        address deployer;
        address pauser;
        address vault;
        address gateway;
    }

    function getPC20Config() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 97) return _bscTestnet();
        if (id == 84532) return _baseSepolia();
        if (id == 421614) return _arbitrumSepolia();
        if (id == 11155111) return _ethSepolia();

        revert("PC20FactoryConfig: unsupported chain");
    }

    function _bscTestnet() private pure returns (Config memory) {
        return Config({
            deployer: 0x6dD2cA20ec82E819541EB43e1925DbE46a441970,
            pauser: 0x6dD2cA20ec82E819541EB43e1925DbE46a441970,
            vault: 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881,
            gateway: 0x44aFFC61983F4348DdddB886349eb992C061EaC0
        });
    }

    function _baseSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0x52DEA34AfAaD33Bb16675ED527b1ed80E83ffb09,
            pauser: 0x52DEA34AfAaD33Bb16675ED527b1ed80E83ffb09,
            vault: 0xb4Ba4D5542D1dD48BD3589543660B265B41f16CB,
            gateway: 0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16
        });
    }

    function _arbitrumSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xD854DDe7C58eC1B405E6577F48a7cC5b5E6EF317,
            pauser: 0xD854DDe7C58eC1B405E6577F48a7cC5b5E6EF317,
            vault: 0x233B1B1B378eb0Aa723097634025A47C4b73A8F7,
            gateway: 0x2cd870e0166Ba458dEC615168Fd659AacD795f34
        });
    }

    function _ethSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6,
            pauser: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6,
            vault: 0xD019Eb12D0d6eF8D299661f22B4B7d262eD4b965,
            gateway: 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A
        });
    }
}
