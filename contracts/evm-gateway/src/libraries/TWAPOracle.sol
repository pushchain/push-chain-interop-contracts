// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {Errors} from "./Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TWAPOracle
 * @notice Library for fetching ETH/USD prices using Uniswap V3 TWAP oracles
 * @dev Extracts price fetching logic from UniversalGatewayV1 into a reusable library
 */
library TWAPOracle {
    /// @dev Configuration for a Uniswap V3 pool used for price oracle
    struct PoolConfig {
        IUniswapV3Pool pool;
        address stableToken;
        uint8 stableTokenDecimals;
        bool enabled;
    }

    /// @notice ETH/USD (scaled to 1e18) using Uniswap V3 TWAP from the configured WETH/USDC pool.
    /// @dev Assumes USDC ≈ $1; scales 6 decimals -> 1e18. Enforces observation cardinality.
    function getEthUsdPrice1e18(
        PoolConfig memory cfg,
        address weth,
        uint32 twapWindowSec,
        uint16 minObsCardinality
    ) internal view returns (uint256 ethUsd1e18) {
        if (!cfg.enabled) revert Errors.NoValidTWAP();

        IUniswapV3Pool pool = cfg.pool;

        // slot0: (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, feeProtocol, unlocked)
        (, /*tick*/ , , uint16 obsCard, uint16 obsCardNext, , ) = pool.slot0();

        // Require sufficient observation history for TWAP (either current or next target)
        if (minObsCardinality != 0 && obsCardNext < minObsCardinality && obsCard < minObsCardinality) {
            revert Errors.LowCardinality();
        }

        // TWAP tick over window
        (int24 meanTick, ) = OracleLibrary.consult(address(pool), twapWindowSec);

        // Quote 1 ETH (1e18 wei) -> USDC at meanTick, regardless of token ordering in the pool
        address t0 = pool.token0();
        address t1 = pool.token1();

        uint256 usdcOut;
        if (t0 == weth) {
            // WETH (t0) -> USDC (t1)
            usdcOut = OracleLibrary.getQuoteAtTick(meanTick, 1e18, t0, t1);
            if (t1 != cfg.stableToken) revert Errors.InvalidPoolConfig();
        } else if (t1 == weth) {
            // WETH (t1) -> USDC (t0)
            usdcOut = OracleLibrary.getQuoteAtTick(meanTick, 1e18, t1, t0);
            if (t0 != cfg.stableToken) revert Errors.InvalidPoolConfig();
        } else {
            revert Errors.InvalidPoolConfig();
        }

        // Scale USDC (6 decimals) -> 1e18 USD
        if (cfg.stableTokenDecimals < 18) {
            ethUsd1e18 = usdcOut * (10 ** (18 - cfg.stableTokenDecimals)); // typically *1e12
        } else if (cfg.stableTokenDecimals > 18) {
            ethUsd1e18 = usdcOut / (10 ** (cfg.stableTokenDecimals - 18));
        } else {
            ethUsd1e18 = usdcOut;
        }

        if (ethUsd1e18 == 0) revert Errors.NoValidTWAP();
    }

    /// @notice Convert an ETH amount (wei) into USD (1e18) using the same TWAP.
    function quoteEthAmountInUsd1e18(
        PoolConfig memory cfg,
        address weth,
        uint256 amountWei,
        uint32 twapWindowSec,
        uint16 minObsCardinality
    ) internal view returns (uint256 usd1e18) {
        uint256 px = getEthUsdPrice1e18(cfg, weth, twapWindowSec, minObsCardinality);
        // Use OpenZeppelin's Math.mulDiv to avoid precision loss / overflow
        usd1e18 = Math.mulDiv(amountWei, px, 1e18);
    }

    /// @notice Returns (pool, fee) for the first existing token/native v3 pool following feeOrder.
    /// @dev Reverts if none exists. Special case: if token == native, returns (address(0), 0) for unwrap.
    /// @param factory Uniswap V3 factory contract
    /// @param token Token address to find pool for
    /// @param native Native token address (e.g., WETH)
    /// @param feeOrder Array of fee tiers to try in order
    /// @return pool The found Uniswap V3 pool (or address(0) for native token)
    /// @return fee The fee tier of the found pool (or 0 for native token)
    function _findPoolWithNative(
        IUniswapV3Factory factory,
        address token,
        address native,
        uint24[3] memory feeOrder
    ) internal view returns (IUniswapV3Pool pool, uint24 fee) {
        if (address(factory) == address(0)) revert Errors.NotSwapAllowed();
        if (token == address(0) || native == address(0)) revert Errors.ZeroAddress();
        if (token == native) {
            // Special case: "pool" not needed for swap; we can just unwrap instead.
            return (IUniswapV3Pool(address(0)), 0);
        }

        unchecked {
            for (uint256 i = 0; i < 3; i++) {
                uint24 f = feeOrder[i];
                address p = factory.getPool(token, native, f);
                if (p != address(0)) {
                    return (IUniswapV3Pool(p), f);
                }
            }
        }
        revert Errors.PairNotFound(); // "no token/native v3 pool"
    }

    /// @notice Estimate native token out for `amountIn` of a given token using v3 TWAP.
    /// @dev Enforces observation cardinality and returns the estimated native token out in wei.
    /// @param pool Uniswap V3 pool for the token/native pair
    /// @param token Token address to estimate output for
    /// @param native Native token address (e.g., WETH)
    /// @param amountIn Amount of input token
    /// @param twapWindowSec TWAP window in seconds
    /// @param minObsCardinality Minimum observation cardinality required
    /// @return nativeOutEstWei Estimated native token output in wei
    function _estimateNativeOutForToken(
        IUniswapV3Pool pool,
        address token,
        address native,
        uint256 amountIn,
        uint32 twapWindowSec,
        uint16 minObsCardinality
    ) internal view returns (uint256 nativeOutEstWei) {
        // Native token fast-path: no pool needed; "estimate" = amountIn (in native units) after unwrap.
        if (token == native) return amountIn;
        if (address(pool) == address(0)) revert Errors.InvalidPoolConfig();
        
        // Require adequate observation history
        (, , , uint16 obsCard, uint16 obsCardNext, , ) = pool.slot0();
        if (minObsCardinality != 0 && obsCard < minObsCardinality && obsCardNext < minObsCardinality) {
            revert Errors.LowCardinality();
        }

        // TWAP tick over your window
        (int24 meanTick, ) = OracleLibrary.consult(address(pool), twapWindowSec);

        // getQuoteAtTick expects baseAmount as uint128
        if (amountIn > type(uint128).max) revert Errors.InvalidAmount();
        nativeOutEstWei = OracleLibrary.getQuoteAtTick(
            meanTick,
            uint128(amountIn),
            token,
            native
        );
    }
}
