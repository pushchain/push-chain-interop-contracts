// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ISwapRouter, IWETH, AggregatorV3Interface} from "./interfaces/IAMMInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract UniversalGateway is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    struct AmountInUSD {
        uint256 amountInUSD;
        uint8 decimals;
    }

    event FundsAdded(
        address indexed user,
        bytes32 indexed transactionHash,
        AmountInUSD AmountInUSD
    );
    event TokenRecovered(address indexed admin, uint256 indexed amount);

    address public WETH;
    address public USDT;
    address public UNISWAP_ROUTER;
    AggregatorV3Interface public ethUsdPriceFeed;
    AggregatorV3Interface public usdtUsdPriceFeed;

    uint24 constant POOL_FEE = 500; // 0.05%

    function initialize(
        address _admin,
        address _weth,
        address _usdt,
        address _router,
        address _priceFeed,
        address _usdtPriceFeed
    ) external initializer {
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        WETH = _weth;
        USDT = _usdt;
        UNISWAP_ROUTER = _router;
        ethUsdPriceFeed = AggregatorV3Interface(_priceFeed);
        usdtUsdPriceFeed = AggregatorV3Interface(_usdtPriceFeed);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function addFunds(bytes32 _transactionHash) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");

        // Wrap ETH to WETH
        IWETH(WETH).deposit{value: msg.value}();
        uint256 WethBalance = IERC20(WETH).balanceOf(address(this));
        IWETH(WETH).approve(UNISWAP_ROUTER, WethBalance);

        // Get current ETH/USD price from Chainlink
        (uint256 price, uint8 decimals) = getEthUsdPrice();

        // Calculate minimum output with 0.5% slippage
        uint256 ethInUsd = (price * WethBalance) / 1e18;
        uint256 minOut = (ethInUsd * 995) / 1000;
        minOut = minOut / 1e2; // Convert from 8 decimals to 6 decimals (USDT)

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDT,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp, //not for sepolia
                amountIn: WethBalance,
                amountOutMinimum: minOut, // Adjust to USDT decimals (6) && not for sepolia
                sqrtPriceLimitX96: 0
            });

        uint256 usdtReceived = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(
            params
        );

        // Get USDT/USD price and calculate final USD amount
        (, int256 usdtPrice, , , ) = usdtUsdPriceFeed.latestRoundData();
        uint8 usdDecimals = usdtUsdPriceFeed.decimals();
        uint256 usdAmount = (uint256(usdtPrice) * usdtReceived) /
            10 ** 6;

        AmountInUSD memory usdAmountStruct = AmountInUSD({
            amountInUSD: usdAmount,
            decimals: usdDecimals
        });

        emit FundsAdded(msg.sender, _transactionHash, usdAmountStruct);
    }

    function recoverToken(
        address _recipient,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(USDT).safeTransfer(_recipient, amount);

        emit TokenRecovered(_recipient, amount);
    }

    function getEthUsdPrice() public view returns (uint256, uint8) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        uint8 decimals = ethUsdPriceFeed.decimals();

        require(price > 0, "Invalid price");
        return (uint256(price), decimals); // 8 decimals
    }
}