// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { ISwapRouterSepolia } from "../../src/interfaces/ISwapRouterSepolia.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";

/**
 * @title MockUniswapV3Factory
 * @notice Simple mock for Uniswap V3 Factory for testing
 */
contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;
    address public factoryOwner;

    constructor() {
        factoryOwner = msg.sender;
    }

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        require(msg.sender == factoryOwner, "MockFactory: not owner");
        pools[token0][token1][fee] = pool;
        pools[token1][token0][fee] = pool; // Symmetric
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view override returns (address pool) {
        return pools[tokenA][tokenB][fee];
    }

    function owner() external view override returns (address) {
        return factoryOwner;
    }

    function feeAmountTickSpacing(uint24) external pure override returns (int24) {
        return 60;
    }

    function createPool(address, address, uint24) external pure override returns (address) {
        revert("MockFactory: createPool not implemented");
    }

    function setOwner(address) external pure override {
        revert("MockFactory: setOwner not implemented");
    }

    function enableFeeAmount(uint24, int24) external pure override {
        revert("MockFactory: enableFeeAmount not implemented");
    }
}

/**
 * @title MockUniswapV3Router
 * @notice Simple mock for Uniswap V3 Router for testing
 * @dev Simulates swaps by transferring tokens and returning WETH
 */
contract MockUniswapV3Router is ISwapRouterSepolia {
    address public weth;
    mapping(address => uint256) public swapRates; // token -> ETH rate (1e18 = 1:1)

    constructor(address _weth) {
        weth = _weth;
    }

    /// @notice Set swap rate for a token (amountOut = amountIn * rate / 1e18)
    function setSwapRate(address token, uint256 rate) external {
        swapRates[token] = rate;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        require(params.tokenOut == weth, "MockRouter: tokenOut must be WETH");

        // Calculate amount out based on swap rate (default 1:1 if not set)
        uint256 rate = swapRates[params.tokenIn];
        if (rate == 0) {
            rate = 1e18; // Default 1:1
        }
        amountOut = (params.amountIn * rate) / 1e18;

        // Transfer tokens from gateway to this router
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Mint WETH to gateway (simulating swap output)
        // If router doesn't have enough WETH, mint it by depositing ETH
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));
        if (wethBalance < amountOut) {
            uint256 ethNeeded = amountOut - wethBalance;
            // Mint WETH by depositing ETH (router should have ETH from setUp)
            IWETH(weth).deposit{ value: ethNeeded }();
        }

        // Transfer WETH to gateway
        IERC20(weth).transfer(msg.sender, amountOut);

        return amountOut;
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("MockRouter: exactInput not implemented");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) {
        revert("MockRouter: exactOutputSingle not implemented");
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("MockRouter: exactOutput not implemented");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {
        // Mock router doesn't need to implement callback logic
        revert("MockRouter: callback not used");
    }
}
