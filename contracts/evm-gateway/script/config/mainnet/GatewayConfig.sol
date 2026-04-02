// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  GatewayConfig (Mainnet)
/// @notice Per-chain deployment parameters for UniversalGateway on mainnet chains.
/// @dev    To add a new chain:
///         1. Add a private function returning Config for that chain
///         2. Register it in the if/else ladder in getConfig()

abstract contract GatewayConfig {
    struct Config {
        // --- Core addresses ---
        address deployer;
        address vault;
        address uniswapV3Factory;
        address uniswapV3Router;
        address weth;
        address ethUsdFeed;
        address gatewayProxy; // address(0) for fresh deploys, set for upgrades
        // --- Role addresses (must NOT default to deployer on mainnet) ---
        address tssAddress;
        address admin; // multisig
        address pauser;
        // --- CEA ---
        address ceaFactory;
        // --- L2 sequencer (address(0) for L1 chains) ---
        address l2SequencerFeed;
        uint256 l2SequencerGracePeriodSec;
        // --- Oracle ---
        uint256 chainlinkStalePeriodSec;
        // --- Rate limits (18 decimals: 1e18 = $1 USD) ---
        uint256 minCapUsd;
        uint256 maxCapUsd;
    }

    /// @notice Resolves the config for the current chain.
    /// @dev    Reverts if block.chainid is not supported.
    function getConfig() internal view returns (Config memory) {
        uint256 id = block.chainid;

        if (id == 1) return _ethereumMainnet();
        if (id == 42161) return _arbitrumOne();
        if (id == 56) return _bscMainnet();
        if (id == 8453) return _baseMainnet();

        revert("GatewayConfig: unsupported mainnet chain");
    }

    // =====================================================================
    //  Ethereum Mainnet (Chain ID: 1)
    // =====================================================================

    function _ethereumMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            uniswapV3Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            ethUsdFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            gatewayProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0), // TODO: Set before deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            l2SequencerFeed: address(0), // L1 — no sequencer feed
            l2SequencerGracePeriodSec: 0,
            chainlinkStalePeriodSec: 3600, // 1 hour — ETH/USD heartbeat
            minCapUsd: 10e18, // TODO: Review — $10 minimum
            maxCapUsd: 10_000e18 // TODO: Review — $10,000 maximum
        });
    }

    // =====================================================================
    //  Arbitrum One (Chain ID: 42161)
    // =====================================================================

    function _arbitrumOne() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            uniswapV3Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564,
            weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            ethUsdFeed: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612,
            gatewayProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0), // TODO: Set before deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            l2SequencerFeed: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D,
            l2SequencerGracePeriodSec: 3600, // 1 hour grace after sequencer restart
            chainlinkStalePeriodSec: 3600,
            minCapUsd: 10e18, // TODO: Review
            maxCapUsd: 10_000e18 // TODO: Review
        });
    }

    // =====================================================================
    //  BSC Mainnet (Chain ID: 56)
    // =====================================================================

    function _bscMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865, // PancakeSwap V3
            uniswapV3Router: 0x1b81D678ffb9C0263b24A97847620C99d213eB14, // PancakeSwap V3
            weth: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // WBNB
            ethUsdFeed: 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e, // BNB/USD
            gatewayProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0), // TODO: Set before deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            l2SequencerFeed: address(0), // L1 — no sequencer feed
            l2SequencerGracePeriodSec: 0,
            chainlinkStalePeriodSec: 3600,
            minCapUsd: 10e18, // TODO: Review
            maxCapUsd: 10_000e18 // TODO: Review
        });
    }

    // =====================================================================
    //  Base Mainnet (Chain ID: 8453)
    // =====================================================================

    function _baseMainnet() private pure returns (Config memory) {
        return Config({
            deployer: address(0), // TODO: Set before deployment
            vault: address(0), // TODO: Set after Vault deployment
            uniswapV3Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD,
            uniswapV3Router: 0x2626664c2603336E57B271c5C0b26F421741e481,
            weth: 0x4200000000000000000000000000000000000006,
            ethUsdFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
            gatewayProxy: address(0),
            tssAddress: address(0), // TODO: Set before deployment
            admin: address(0), // TODO: Set to multisig before deployment
            pauser: address(0), // TODO: Set before deployment
            ceaFactory: address(0), // TODO: Set after CEAFactory deployment
            l2SequencerFeed: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
            l2SequencerGracePeriodSec: 3600,
            chainlinkStalePeriodSec: 3600,
            minCapUsd: 10e18, // TODO: Review
            maxCapUsd: 10_000e18 // TODO: Review
        });
    }
}
