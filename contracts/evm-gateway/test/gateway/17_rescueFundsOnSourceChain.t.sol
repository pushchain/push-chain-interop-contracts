// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { TX_TYPE } from "../../src/libraries/Types.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";

contract RescueFundsOnSourceChainTest is Test {
    // Actors
    address public admin;
    address public pauser;
    address public user1;
    address public attacker;
    address public uem;
    address public vaultPC;

    // Contracts
    UniversalGatewayPC public gateway;
    TransparentUpgradeableProxy public gatewayProxy;
    ProxyAdmin public proxyAdmin;

    // Mocks
    MockUniversalCoreReal public universalCore;
    MockPRC20 public prc20Token;
    MockPRC20 public gasToken;

    // Constants
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    uint256 public constant RESCUE_GAS_LIMIT = 200_000;
    string public constant SOURCE_CHAIN_NAMESPACE = "1";
    string public constant SOURCE_TOKEN_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    bytes32 public constant UNIVERSAL_TX_ID = bytes32(uint256(99));

    function setUp() public {
        admin = address(0x1);
        pauser = address(0x2);
        user1 = address(0x3);
        attacker = address(0x5);
        uem = address(0x6);
        vaultPC = address(0x7);

        vm.label(admin, "admin");
        vm.label(pauser, "pauser");
        vm.label(user1, "user1");
        vm.label(attacker, "attacker");
        vm.label(uem, "uem");
        vm.label(vaultPC, "vaultPC");

        vm.deal(admin, 100 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(attacker, 1000 ether);

        // Deploy mocks
        universalCore = new MockUniversalCoreReal(uem);

        gasToken = new MockPRC20(
            "Push Chain Native", "PC", 18, SOURCE_CHAIN_NAMESPACE, MockPRC20.TokenType.PC, address(universalCore), ""
        );

        prc20Token = new MockPRC20(
            "USDC on Push Chain",
            "USDC",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        vm.prank(uem);
        universalCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(gasToken));

        // Deploy gateway
        UniversalGatewayPC implementation = new UniversalGatewayPC();
        proxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector, admin, pauser, address(universalCore), vaultPC
        );

        gatewayProxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
        gateway = UniversalGatewayPC(address(gatewayProxy));

        // Set rescue gas limit on UniversalCore
        vm.prank(uem);
        universalCore.setRescueFundsGasLimitByChain(SOURCE_CHAIN_NAMESPACE, RESCUE_GAS_LIMIT);
    }

    // ============================================================
    //                      HAPPY PATH
    // ============================================================

    function testRescueSuccess() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 pcToSend = expectedGasFee + 0.5 ether;

        vm.prank(user1);
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueEventParams() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 pcToSend = expectedGasFee + 0.5 ether;

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.RescueFundsOnSourceChain(
            UNIVERSAL_TX_ID,
            address(prc20Token),
            SOURCE_CHAIN_NAMESPACE,
            user1,
            TX_TYPE.RESCUE_FUNDS,
            expectedGasFee,
            DEFAULT_GAS_PRICE,
            RESCUE_GAS_LIMIT
        );
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueNoProtocolFee() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 pcToSend = expectedGasFee + 0.5 ether;

        uint256 vaultPCBefore = vaultPC.balance;

        vm.prank(user1);
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));

        assertEq(vaultPC.balance, vaultPCBefore);
    }

    function testRescueNoPRC20Burn() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 pcToSend = expectedGasFee + 0.5 ether;

        prc20Token.mint(user1, 1000e6);
        uint256 prc20Before = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));

        assertEq(prc20Token.balanceOf(user1), prc20Before);
    }

    function testRescueRefundExcessPC() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 excess = 0.5 ether;
        uint256 pcToSend = expectedGasFee + excess;

        uint256 userBefore = user1.balance;

        vm.prank(user1);
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));

        assertEq(user1.balance, userBefore - expectedGasFee);
    }

    // ============================================================
    //                      REVERT CASES
    // ============================================================

    function testRescueRevertZeroPRC20() public {
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.rescueFundsOnSourceChain{ value: 1 ether }(UNIVERSAL_TX_ID, address(0));
    }

    function testRescueRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(user1);
        vm.expectRevert();
        gateway.rescueFundsOnSourceChain{ value: 1 ether }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueRevertZeroValue() public {
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.rescueFundsOnSourceChain{ value: 0 }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueRevertZeroGasPrice() public {
        // Deploy a separate core with gas token and rescue limit but no gas price
        MockUniversalCoreReal badCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        badCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(gasToken));
        vm.prank(uem);
        badCore.setRescueFundsGasLimitByChain(SOURCE_CHAIN_NAMESPACE, RESCUE_GAS_LIMIT);
        // gasPrice not set → defaults to 0, getRescueFundsGasLimit reverts

        UniversalGatewayPC impl2 = new UniversalGatewayPC();
        ProxyAdmin pa2 = new ProxyAdmin(admin);
        bytes memory initData =
            abi.encodeWithSelector(UniversalGatewayPC.initialize.selector, admin, pauser, address(badCore), vaultPC);
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(address(impl2), address(pa2), initData);
        UniversalGatewayPC gw2 = UniversalGatewayPC(address(proxy2));

        vm.prank(user1);
        vm.expectRevert();
        gw2.rescueFundsOnSourceChain{ value: 1 ether }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueRevertZeroGasToken() public {
        // Deploy core with gas price and rescue limit but no gas token
        MockUniversalCoreReal badCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        badCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        badCore.setRescueFundsGasLimitByChain(SOURCE_CHAIN_NAMESPACE, RESCUE_GAS_LIMIT);
        // gasToken not set → defaults to address(0), getRescueFundsGasLimit reverts

        UniversalGatewayPC impl2 = new UniversalGatewayPC();
        ProxyAdmin pa2 = new ProxyAdmin(admin);
        bytes memory initData =
            abi.encodeWithSelector(UniversalGatewayPC.initialize.selector, admin, pauser, address(badCore), vaultPC);
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(address(impl2), address(pa2), initData);
        UniversalGatewayPC gw2 = UniversalGatewayPC(address(proxy2));

        vm.prank(user1);
        vm.expectRevert();
        gw2.rescueFundsOnSourceChain{ value: 1 ether }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    function testRescueRevertZeroGasLimit() public {
        // Deploy a core without setting rescueFundsGasLimitByChainNamespace
        MockUniversalCoreReal badCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        badCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        badCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(gasToken));
        // rescueFundsGasLimit not set → defaults to 0, getRescueFundsGasLimit reverts

        UniversalGatewayPC impl2 = new UniversalGatewayPC();
        ProxyAdmin pa2 = new ProxyAdmin(admin);
        bytes memory initData =
            abi.encodeWithSelector(UniversalGatewayPC.initialize.selector, admin, pauser, address(badCore), vaultPC);
        TransparentUpgradeableProxy proxy2 = new TransparentUpgradeableProxy(address(impl2), address(pa2), initData);
        UniversalGatewayPC gw2 = UniversalGatewayPC(address(proxy2));

        vm.prank(user1);
        vm.expectRevert();
        gw2.rescueFundsOnSourceChain{ value: 1 ether }(UNIVERSAL_TX_ID, address(prc20Token));
    }

    // ============================================================
    //                   TX_TYPE + ADMIN
    // ============================================================

    function testRescueTxTypeIsRescue() public {
        uint256 expectedGasFee = DEFAULT_GAS_PRICE * RESCUE_GAS_LIMIT;
        uint256 pcToSend = expectedGasFee + 0.5 ether;

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.RescueFundsOnSourceChain(
            UNIVERSAL_TX_ID,
            address(prc20Token),
            SOURCE_CHAIN_NAMESPACE,
            user1,
            TX_TYPE.RESCUE_FUNDS,
            expectedGasFee,
            DEFAULT_GAS_PRICE,
            RESCUE_GAS_LIMIT
        );
        gateway.rescueFundsOnSourceChain{ value: pcToSend }(UNIVERSAL_TX_ID, address(prc20Token));

        // TX_TYPE.RESCUE_FUNDS == 4
        assertEq(uint8(TX_TYPE.RESCUE_FUNDS), 4);
    }
}
