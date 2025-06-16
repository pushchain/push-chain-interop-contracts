// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UniversalGateway.sol";
import "forge-std/console2.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AggregatorV3Interface} from "../src/interfaces/IAMMInterface.sol";

contract UniversalGatewayTest is Test {
    UniversalGateway locker;
    address user = makeAddr("user");
    address admin = makeAddr("admin");
    address recipient = makeAddr("recipient");
    bytes32 transactionHash = keccak256("transactionHash");

    // address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // address constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // address constant ETHUSDFEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    //TESTNET SEPOLIA ADDRESS

    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address constant ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant ETHUSDFEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant USDTUSDFEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    function setUp() public {
        // vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        address deployedAddress = Upgrades.deployUUPSProxy(
            "UniversalGateway.sol",
            abi.encodeCall(
                UniversalGateway.initialize,
                (admin, WETH, USDT, ROUTER, ETHUSDFEED, USDTUSDFEED)
            )
        );
        locker = UniversalGateway(deployedAddress);
        vm.deal(user, 100 ether);
    }

    function test_OraclePrice() public {
        (uint256 price, uint8 decimals) = locker.getEthUsdPrice();
        assertGt(price, 0, "Incorrect Price");
        console.log(price);
        assertEq(decimals, 8);
    }

    function test_AddFunds_ConvertsETHtoUSDT() public {
        vm.startPrank(user);
        uint256 initialUSDTBalance = IERC20(USDT).balanceOf(address(locker));

        // Get ETH/USD price
        (uint256 ethPrice, uint8 ethDecimals) = locker.getEthUsdPrice();

        // Get USDT/USD price
        (, int256 usdtPrice, , , ) = AggregatorV3Interface(USDTUSDFEED)
            .latestRoundData();
        uint8 usdtDecimals = AggregatorV3Interface(USDTUSDFEED).decimals();

        // Calculate expected USDT amount (with slippage)
        uint256 expectedEthInUsd = (ethPrice * 1 ether) / 1e18; // This gives us USD amount in 8 decimals
        uint256 minOut = (expectedEthInUsd * 995) / 1000; // 0.5% slippage
        uint256 expectedUsdt = minOut / 1e2; // Convert to USDT decimals

        // Calculate final USD amount using USDT price
        uint256 expectedUsdAmount = (uint256(usdtPrice) * expectedUsdt) /
            10 ** usdtDecimals;

        UniversalGateway.AmountInUSD memory expectedPrice = UniversalGateway.AmountInUSD({
            amountInUSD: expectedUsdAmount,
            decimals: usdtDecimals
        });

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit FundsAdded(user, transactionHash, expectedPrice);

        locker.addFunds{value: 1 ether}(transactionHash);

        uint256 finalUSDTBalance = IERC20(USDT).balanceOf(address(locker));
        assertGt(finalUSDTBalance, initialUSDTBalance, "USDT not received");

        vm.stopPrank();
    }

    function test_RecoverToken_ByAdmin() public {
        // Send some ETH and convert to USDT
        vm.startPrank(user);
        locker.addFunds{value: 1 ether}(transactionHash);
        vm.stopPrank();

        uint256 lockerUSDTBalance = IERC20(USDT).balanceOf(address(locker));
        assertGt(lockerUSDTBalance, 0);

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(recipient, lockerUSDTBalance);
        locker.recoverToken(recipient, lockerUSDTBalance);
        vm.stopPrank();

        assertEq(IERC20(USDT).balanceOf(recipient), lockerUSDTBalance);
    }

    function test_RecoverToken_NotAdminShouldRevert() public {
        vm.expectRevert();
        vm.prank(user);
        locker.recoverToken(recipient, 1e6); // Try to recover 1 USDT
    }

    function test_Upgradeability() public {
        //@dev: This is a workaround for the upgradeability test. In a real scenario, the admin can upgrade.
        vm.prank(admin);
        locker.grantRole(0x00, address(this));

        Upgrades.upgradeProxy(address(locker), "UniversalGatewayV2.sol", "");

        // Just assert that it's still functional after upgrade
        vm.prank(user);
        locker.addFunds{value: 0.5 ether}(transactionHash);
    }

    event FundsAdded(
        address indexed user,
        bytes32 indexed transactionHash,
        UniversalGateway.AmountInUSD indexed AmountInUSD
    );
    event TokenRecovered(address indexed admin, uint256 amount);
}