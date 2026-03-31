// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  GatewayConfig
/// @notice Per-chain deployment parameters for UniversalGateway.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract GatewayConfig {
    struct Config {
        address deployer;
        address vault;
        address uniswapV3Factory;
        address uniswapV3Router;
        address weth;
        address ethUsdFeed;
        address gatewayProxy; // Set for upgrades, address(0) for fresh deploys
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 11155111) return _ethSepolia();
        if (id == 421614) return _arbitrumSepolia();
        if (id == 97) return _bscTestnet();
        if (id == 84532) return _baseSepolia();

        revert("GatewayConfig: unsupported chain");
    }

    // =====================================================================
    //  Ethereum Sepolia (Chain ID: 11155111)
    // =====================================================================

    function _ethSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6,
            vault: 0xD019Eb12D0d6eF8D299661f22B4B7d262eD4b965,
            uniswapV3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
            uniswapV3Router: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E,
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            ethUsdFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            gatewayProxy: 0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A
        });
    }

    // =====================================================================
    //  Arbitrum Sepolia (Chain ID: 421614)
    // =====================================================================

    function _arbitrumSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0xD854DDe7C58eC1B405E6577F48a7cC5b5E6EF317,
            vault: 0x233B1B1B378eb0Aa723097634025A47C4b73A8F7,
            uniswapV3Factory: 0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e,
            uniswapV3Router: 0x101F443B4d1b059569D643917553c771E1b9663E,
            weth: 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73,
            ethUsdFeed: 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165,
            gatewayProxy: 0x2cd870e0166Ba458dEC615168Fd659AacD795f34
        });
    }

    // =====================================================================
    //  BSC Testnet (Chain ID: 97)
    // =====================================================================

    function _bscTestnet() private pure returns (Config memory) {
        return Config({
            deployer: 0x6dD2cA20ec82E819541EB43e1925DbE46a441970,
            vault: 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881,
            uniswapV3Factory: 0x0bEC2a9E08658eAA15935C25cfF953caB2934C85,
            uniswapV3Router: 0x2908Fa14Ef79A774c2bF0ab895948B0e768e4CB0,
            weth: 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,
            ethUsdFeed: 0x143db3CEEfbdfe5631aDD3E50f7614B6ba708BA7,
            gatewayProxy: 0x44aFFC61983F4348DdddB886349eb992C061EaC0
        });
    }

    // =====================================================================
    //  Base Sepolia (Chain ID: 84532)
    // =====================================================================

    function _baseSepolia() private pure returns (Config memory) {
        return Config({
            deployer: 0x52DEA34AfAaD33Bb16675ED527b1ed80E83ffb09,
            vault: 0xb4Ba4D5542D1dD48BD3589543660B265B41f16CB,
            uniswapV3Factory: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
            uniswapV3Router: 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4,
            weth: 0x4200000000000000000000000000000000000006,
            ethUsdFeed: 0xE7fab834B68dA8016239845D08F0B8a82fa446f0,
            gatewayProxy: 0xFD4fef1F43aFEc8b5bcdEEc47f35a1431479aC16
        });
    }
}
