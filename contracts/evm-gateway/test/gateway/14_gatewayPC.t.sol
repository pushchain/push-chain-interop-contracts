// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { TX_TYPE } from "../../src/libraries/Types.sol";
import { UniversalOutboundTxRequest } from "../../src/libraries/TypesUGPC.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";
import { MockReentrantContract } from "../mocks/MockReentrantContract.sol";

/**
 * @title   UniversalGatewayPCTest
 * @notice  Comprehensive test suite for UniversalGatewayPC contract
 * @dev     Tests initialization, admin functions, and user withdrawal flows
 */
contract UniversalGatewayPCTest is Test {
    // =========================
    //           ACTORS
    // =========================
    address public admin;
    address public pauser;
    address public user1;
    address public user2;
    address public attacker;
    address public uem;
    address public vaultPC;

    // =========================
    //        CONTRACTS
    // =========================
    UniversalGatewayPC public gateway;
    TransparentUpgradeableProxy public gatewayProxy;
    ProxyAdmin public proxyAdmin;

    // =========================
    //          MOCKS
    // =========================
    MockUniversalCoreReal public universalCore;
    MockPRC20 public prc20Token;
    MockPRC20 public gasToken;

    // =========================
    //      TEST CONSTANTS
    // =========================
    uint256 public constant LARGE_AMOUNT = 1000000 * 1e18;
    uint256 public constant DEFAULT_GAS_LIMIT = 500_000; // Matches UniversalCore.BASE_GAS_LIMIT
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0.01 ether;
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    uint256 public constant PC_FEE = 1 ether; // Standard native PC fee for tests
    string public constant SOURCE_CHAIN_NAMESPACE = "1"; // Ethereum mainnet
    string public constant SOURCE_TOKEN_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC

    // =========================
    //         SETUP
    // =========================
    function setUp() public {
        _createActors();
        _deployMocks();
        _deployGateway();
        _initializeGateway();
        _setupTokens();
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================
    function calculateExpectedGasFee(uint256 gasLimit) internal pure returns (uint256) {
        return DEFAULT_GAS_PRICE * gasLimit;
    }

    function calculateExpectedTotal(uint256 gasLimit) internal pure returns (uint256) {
        return DEFAULT_GAS_PRICE * gasLimit + DEFAULT_PROTOCOL_FEE;
    }

    function _createOutboundRequest(
        bytes memory recipient,
        address token,
        uint256 amount,
        uint256 gasLimit,
        bytes memory payload,
        address revertRecipient
    ) internal pure returns (UniversalOutboundTxRequest memory) {
        return UniversalOutboundTxRequest({
            recipient: recipient,
            token: token,
            amount: amount,
            gasLimit: gasLimit,
            payload: payload,
            revertRecipient: revertRecipient
        });
    }

    function _calculateExpectedsubTxId(
        address sender,
        bytes memory recipient,
        address token,
        uint256 amount,
        bytes memory payload,
        string memory chainId,
        uint256 expectedNonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, recipient, token, amount, keccak256(payload), chainId, expectedNonce));
    }

    function testInitializeSuccess() public {
        // Deploy new gateway for testing initialization
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector, admin, pauser, address(universalCore), vaultPC
        );

        TransparentUpgradeableProxy newProxy =
            new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Verify initialization
        assertEq(newGateway.UNIVERSAL_CORE(), address(universalCore));
        assertEq(address(newGateway.VAULT_PC()), vaultPC);
        assertTrue(newGateway.hasRole(newGateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(newGateway.hasRole(newGateway.PAUSER_ROLE(), pauser));
    }

    function testInitializeRevertZeroAdmin() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            address(0), // zero admin
            pauser,
            address(universalCore),
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroPauser() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            address(0), // zero pauser
            address(universalCore),
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroUniversalCore() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(0), // zero universal core
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroVaultPC() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore),
            address(0) // zero vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertDoubleInit() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector, admin, pauser, address(universalCore), vaultPC
        );

        TransparentUpgradeableProxy newProxy =
            new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Try to initialize again
        vm.expectRevert();
        newGateway.initialize(admin, pauser, address(universalCore), vaultPC);
    }

    // =========================
    //      ADMIN FUNCTION TESTS
    // =========================

    function testSetVaultPCSuccess() public {
        address newVaultPC = address(0x999);

        // Admin sets new VaultPC
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IUniversalGatewayPC.VaultPCUpdated(vaultPC, newVaultPC);
        gateway.setVaultPC(newVaultPC);

        // Verify state changes
        assertEq(address(gateway.VAULT_PC()), newVaultPC);
    }

    function testSetVaultPCRevertNonAdmin() public {
        address newVaultPC = address(0x999);

        vm.prank(attacker);
        vm.expectRevert();
        gateway.setVaultPC(newVaultPC);
    }

    function testSetVaultPCRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setVaultPC(address(0));
    }

    function testSetVaultPCRevertWhenPaused() public {
        // Pause the gateway first
        vm.prank(pauser);
        gateway.pause();

        address newVaultPC = address(0x999);

        // Attempt to set VaultPC while paused should revert
        vm.prank(admin);
        vm.expectRevert();
        gateway.setVaultPC(newVaultPC);
    }

    // ---- setUniversalCore (audit F-2026-15657) ----

    function testSetUniversalCoreSuccess() public {
        address oldUniversalCore = gateway.UNIVERSAL_CORE();
        address newUniversalCore = address(0x888);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IUniversalGatewayPC.UniversalCoreUpdated(oldUniversalCore, newUniversalCore);
        gateway.setUniversalCore(newUniversalCore);

        assertEq(gateway.UNIVERSAL_CORE(), newUniversalCore);
    }

    function testSetUniversalCoreRevertNonAdmin() public {
        address newUniversalCore = address(0x888);

        vm.prank(attacker);
        vm.expectRevert();
        gateway.setUniversalCore(newUniversalCore);
    }

    function testSetUniversalCoreRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setUniversalCore(address(0));
    }

    function testSetUniversalCoreRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        address newUniversalCore = address(0x888);

        vm.prank(admin);
        vm.expectRevert();
        gateway.setUniversalCore(newUniversalCore);
    }

    function testPauseSuccess() public {
        assertFalse(gateway.paused());

        vm.prank(pauser);
        gateway.pause();

        assertTrue(gateway.paused());
    }

    function testPauseRevertNonPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.pause();
    }

    function testPauseRevertAlreadyPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Try to pause again
        vm.prank(pauser);
        vm.expectRevert();
        gateway.pause();
    }

    function testUnpauseSuccess() public {
        // Pause the contract first
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        // Pauser unpauses the contract
        vm.prank(pauser);
        gateway.unpause();

        // Verify contract is unpaused
        assertFalse(gateway.paused());
    }

    function testUnpauseRevertNonPauser() public {
        // Pause the contract first
        vm.prank(pauser);
        gateway.pause();

        // Non-pauser tries to unpause
        vm.prank(attacker);
        vm.expectRevert();
        gateway.unpause();
    }

    function testUnpauseRevertNotPaused() public {
        // Contract is not paused initially
        assertFalse(gateway.paused());

        // Try to unpause
        vm.prank(pauser);
        vm.expectRevert();
        gateway.unpause();
    }

    function testAdminFunctionsWorkWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Verify that the contract is paused
        assertTrue(gateway.paused());

        // Unpause should still work
        vm.prank(pauser);
        gateway.unpause();

        assertFalse(gateway.paused());
    }

    // =========================
    //      WITHDRAW FUNCTION TESTS
    // =========================

    function testWithdrawSuccessWithCustomGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        address revertRecipient = user2;

        // Ensure user has enough balance
        uint256 userBalance = prc20Token.balanceOf(user1);
        if (userBalance < amount) {
            prc20Token.mint(user1, amount);
            vm.prank(user1);
            prc20Token.approve(address(gateway), amount);
        }

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances (exactOutputSingle mints exactly gasFee to vault)
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawEventEmission() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length >= 1, "At least one event should be emitted");
    }

    function testWithdrawEventEmissionWithTxType() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0);

        // Expect the UniversalTxOutbound event with TX_TYPE.FUNDS
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1, // sender
            SOURCE_CHAIN_NAMESPACE, // chainId
            address(prc20Token), // token
            bytes(""), // recipient
            amount, // amount
            address(gasToken), // gasToken
            expectedGasFee, // gasFee
            gasLimit, // gasLimit
            bytes(""), // payload (empty for withdraw)
            DEFAULT_PROTOCOL_FEE, // protocolFee
            revertRecipient, // revertRecipient
            TX_TYPE.FUNDS, // txType
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawSuccessWithDefaultGasLimit() public {
        uint256 amount = 1000 * 1e6; // 1000 USDC (6 decimals)
        uint256 gasLimit = 0; // Use default gas limit
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(0),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = address(0); // Zero recipient

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawRevertZeroPCAmount() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        // msg.value = 0 but protocolFee > 0 → reverts with InvalidInput (insufficient for protocol fee)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: 0}(req);
    }

    function testWithdrawRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    // =========================
    //   WITHDRAW AND EXECUTE FUNCTION TESTS
    // =========================

    function testWithdrawAndExecuteSuccessWithCustomGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances (exactOutputSingle mints exactly gasFee to vault)
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteEventEmission() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length >= 1, "At least one event should be emitted");
    }

    function testWithdrawAndExecuteEventEmissionWithTxType() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, payload, SOURCE_CHAIN_NAMESPACE, 0);

        // Expect the UniversalTxOutbound event with TX_TYPE.FUNDS_AND_PAYLOAD
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1, // sender
            SOURCE_CHAIN_NAMESPACE, // chainId
            address(prc20Token), // token
            bytes(""), // recipient
            amount, // amount
            address(gasToken), // gasToken
            expectedGasFee, // gasFee
            gasLimit, // gasLimit
            payload, // payload (non-empty for withdrawAndExecute)
            DEFAULT_PROTOCOL_FEE, // protocolFee
            revertRecipient, // revertRecipient
            TX_TYPE.FUNDS_AND_PAYLOAD, // txType
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawAndExecuteSuccessWithDefaultGasLimit() public {
        uint256 amount = 1000 * 1e6; // 1000 USDC (6 decimals)
        uint256 gasLimit = 0; // Use default gas limit
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteSuccessWithEmptyPayload() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = bytes(""); // Empty payload
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // empty payload - will be FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteSuccessWithComplexPayload() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;

        // Complex payload with multiple parameters
        bytes memory payload = abi.encodeWithSignature(
            "complexFunction(address,uint256,bytes32,string)",
            user2,
            1000,
            keccak256("test"),
            "complex string parameter"
        );

        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify token balances
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(0),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawAndExecuteRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload - will be GAS_AND_PAYLOAD type (amount = 0)
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    function testWithdrawAndExecuteRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = address(0); // Zero recipient

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawAndExecuteRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawAndExecuteRevertZeroPCAmount() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        // msg.value = 0 but protocolFee > 0 → reverts with InvalidInput (insufficient for protocol fee)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: 0}(req);
    }

    function testWithdrawAndExecuteRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testWithdrawAndExecuteDifferentPayloadSizes() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        uint256 initialBalance = prc20Token.balanceOf(user1);

        // Test with small payload
        bytes memory smallPayload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);

        UniversalOutboundTxRequest memory req1 = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            smallPayload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req1);

        // Reset balances for next test
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        // Test with large payload
        bytes memory largePayload = abi.encodeWithSignature(
            "largeFunction(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)",
            user2,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9
        );

        UniversalOutboundTxRequest memory req2 = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            largePayload, // non-empty payload for FUNDS_AND_PAYLOAD type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req2);

        // Both should succeed - verify final balance
        uint256 finalBalance = prc20Token.balanceOf(user1);
        assertEq(finalBalance, initialBalance - amount);
    }

    // =========================
    //      EDGE CASES & ADDITIONAL TESTS
    // =========================

    function testReentrancyProtection() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        // Create a contract that calls the gateway
        MockReentrantContract reentrantContract =
            new MockReentrantContract(address(gateway), address(prc20Token), address(gasToken));

        // Fund the contract with PRC20 and native PC
        prc20Token.mint(address(reentrantContract), amount);
        vm.deal(address(reentrantContract), PC_FEE);

        vm.prank(address(reentrantContract));
        prc20Token.approve(address(gateway), amount);

        // Call should succeed (reentrancy protection is for preventing recursive calls during execution)
        vm.prank(address(reentrantContract));
        reentrantContract.attemptReentrancy{value: PC_FEE}(amount, gasLimit, revertRecipient);

        // Verify the withdrawal succeeded
        assertEq(prc20Token.balanceOf(address(reentrantContract)), 0);
    }

    function testReentrancyProtectionWithExecute() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        // Create a contract that calls the gateway
        MockReentrantContract reentrantContract =
            new MockReentrantContract(address(gateway), address(prc20Token), address(gasToken));

        // Fund the contract with PRC20 and native PC
        prc20Token.mint(address(reentrantContract), amount);
        vm.deal(address(reentrantContract), PC_FEE);

        vm.prank(address(reentrantContract));
        prc20Token.approve(address(gateway), amount);

        // Call should succeed (reentrancy protection is for preventing recursive calls during execution)
        vm.prank(address(reentrantContract));
        reentrantContract.attemptReentrancyWithExecute{value: PC_FEE}(amount, payload, gasLimit, revertRecipient);

        // Verify the withdrawal succeeded
        assertEq(prc20Token.balanceOf(address(reentrantContract)), 0);
    }

    function testMaxGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify withdrawal succeeded
        assertEq(vaultPC.balance, initialGasTokenBalance + DEFAULT_PROTOCOL_FEE);
    }

    function testGasFeeCalculationAccuracy() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        // Test specific gas limits individually
        _testGasFeeForLimit(amount, revertRecipient, 50_000);
        _testGasFeeForLimit(amount, revertRecipient, 100_000);
        _testGasFeeForLimit(amount, revertRecipient, 200_000);
        _testGasFeeForLimit(amount, revertRecipient, 500_000);
    }

    function _testGasFeeForLimit(uint256 amount, address revertRecipient, uint256 gasLimit) internal {
        // exactOutputSingle mints exactly the quoted gasFee for the requested gasLimit
        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 balanceBefore = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        uint256 balanceAfter = vaultPC.balance;
        assertEq(balanceAfter - balanceBefore, DEFAULT_PROTOCOL_FEE);

        // Reset for next iteration
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);
    }

    function testSetVaultPCToZeroReverts() public {
        // Attempt to set VaultPC to zero should revert
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setVaultPC(address(0));
    }

    function testInvalidFeeQuoteZeroGasToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        // Create token with unconfigured chain ID (no gas token set for this chain)
        string memory unconfiguredChainId = "999"; // Chain ID not configured in universalCore
        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            unconfiguredChainId,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(invalidToken),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        // Withdrawal should fail with "MockUniversalCore: zero gas token" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas token");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function _createInvalidToken() internal returns (MockPRC20) {
        return new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );
    }

    function _createInvalidCoreWithZeroGasToken() internal returns (MockUniversalCoreReal) {
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        invalidCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(0)); // Zero gas token
        return invalidCore;
    }

    function testInvalidFeeQuoteZeroGasFee() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        // Create token with a chain ID that has gas token but no gas price configured
        string memory chainWithTokenNoPrice = "777";

        // Configure this chain in universalCore with gas token but NO gas price
        vm.prank(uem);
        universalCore.setGasTokenPRC20(chainWithTokenNoPrice, address(gasToken));
        // Intentionally NOT setting gas price for this chain

        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            chainWithTokenNoPrice,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(invalidToken),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        // Withdrawal should fail with "MockUniversalCore: zero gas price" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas price");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function _createInvalidCoreWithZeroGasPrice() internal returns (MockUniversalCoreReal) {
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, 0); // Zero gas price
        vm.prank(uem);
        invalidCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(gasToken));
        return invalidCore;
    }

    function testTokenBurnFailure() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        address revertRecipient = user2;

        // Create failing token
        MockPRC20 failingToken = _createFailingToken();

        // Setup token for user1
        failingToken.mint(user1, amount);
        vm.prank(user1);
        failingToken.approve(address(gateway), amount);

        // Mock the burn function to fail by setting balance to 0
        failingToken.setBalance(user1, 0);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(failingToken),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS type
            revertRecipient
        );

        // Withdrawal should fail with transfer failure
        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function _createFailingToken() internal returns (MockPRC20) {
        return new MockPRC20(
            "Failing Token",
            "FAIL",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );
    }

    // =========================
    //      INTERNAL FUNCTIONS
    // =========================

    function _createActors() internal {
        admin = address(0x1);
        pauser = address(0x2);
        user1 = address(0x3);
        user2 = address(0x4);
        attacker = address(0x5);
        uem = address(0x6);
        vaultPC = address(0x7);

        vm.label(admin, "admin");
        vm.label(pauser, "pauser");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(attacker, "attacker");
        vm.label(uem, "uem");
        vm.label(vaultPC, "vaultPC");

        vm.deal(admin, 100 ether);
        vm.deal(pauser, 100 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    function _deployMocks() internal {
        // Deploy UniversalCore mock
        universalCore = new MockUniversalCoreReal(uem);

        // Deploy gas token (PC native token)
        gasToken = new MockPRC20(
            "Push Chain Native",
            "PC",
            18,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.PC,
            address(universalCore),
            ""
        );

        // Deploy PRC20 token (wrapped USDC)
        prc20Token = new MockPRC20(
            "USDC on Push Chain",
            "USDC",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Configure UniversalCore with gas settings
        vm.prank(uem);
        universalCore.setGasPrice(SOURCE_CHAIN_NAMESPACE, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(SOURCE_CHAIN_NAMESPACE, address(gasToken));

        // Configure protocol fees on UniversalCore
        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(prc20Token), DEFAULT_PROTOCOL_FEE);
        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(gasToken), DEFAULT_PROTOCOL_FEE);

        vm.label(address(universalCore), "UniversalCore");
        vm.label(address(prc20Token), "PRC20Token");
        vm.label(address(gasToken), "GasToken");
    }

    function _deployGateway() internal {
        // Deploy implementation
        UniversalGatewayPC implementation = new UniversalGatewayPC();

        // Deploy proxy admin
        proxyAdmin = new ProxyAdmin(admin);

        // Deploy transparent upgradeable proxy
        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector, admin, pauser, address(universalCore), vaultPC
        );

        gatewayProxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        // Cast proxy to gateway interface
        gateway = UniversalGatewayPC(address(gatewayProxy));

        vm.label(address(gateway), "UniversalGatewayPC");
        vm.label(address(gatewayProxy), "GatewayProxy");
        vm.label(address(proxyAdmin), "ProxyAdmin");
    }

    function _initializeGateway() internal view {
        // Gateway is already initialized via proxy constructor
        // Verify initialization
        assertEq(gateway.UNIVERSAL_CORE(), address(universalCore));
        assertEq(address(gateway.VAULT_PC()), vaultPC);
        assertTrue(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gateway.hasRole(gateway.PAUSER_ROLE(), pauser));
    }

    function _setupTokens() internal {
        // Mint tokens to users
        prc20Token.mint(user1, LARGE_AMOUNT);
        prc20Token.mint(user2, LARGE_AMOUNT);

        // Approve gateway to spend PRC20 tokens (gas token approval no longer needed — fees paid in native PC)
        vm.prank(user1);
        prc20Token.approve(address(gateway), type(uint256).max);

        vm.prank(user2);
        prc20Token.approve(address(gateway), type(uint256).max);
    }

    // =========================
    //   TX_TYPE INFERENCE TESTS
    // =========================

    // Test Group A: Basic TX_TYPE Inference (3 tests)

    function testFetchTxType_FUNDS_NoPayloadWithAmount() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""), // empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0);

        // Expect the UniversalTxOutbound event with TX_TYPE.FUNDS
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1, // sender
            SOURCE_CHAIN_NAMESPACE, // chainId
            address(prc20Token), // token
            bytes(""), // recipient
            amount, // amount
            address(gasToken), // gasToken
            expectedGasFee, // gasFee
            DEFAULT_GAS_LIMIT, // gasLimit
            bytes(""), // payload (empty)
            DEFAULT_PROTOCOL_FEE, // protocolFee
            revertRecipient, // revertRecipient
            TX_TYPE.FUNDS, // txType
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testFetchTxType_FUNDS_AND_PAYLOAD_WithPayloadAndAmount() public {
        uint256 amount = 1000 * 1e6;
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // non-empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, payload, SOURCE_CHAIN_NAMESPACE, 0);

        // Expect the UniversalTxOutbound event with TX_TYPE.FUNDS_AND_PAYLOAD
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1, // sender
            SOURCE_CHAIN_NAMESPACE, // chainId
            address(prc20Token), // token
            bytes(""), // recipient
            amount, // amount
            address(gasToken), // gasToken
            expectedGasFee, // gasFee
            DEFAULT_GAS_LIMIT, // gasLimit
            payload, // payload (non-empty)
            DEFAULT_PROTOCOL_FEE, // protocolFee
            revertRecipient, // revertRecipient
            TX_TYPE.FUNDS_AND_PAYLOAD, // txType
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testFetchTxType_GAS_AND_PAYLOAD_PayloadOnlyNoAmount() public {
        uint256 amount = 0; // No amount
        bytes memory payload = abi.encodeWithSignature("someFunction()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // non-empty payload
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED for GAS_AND_PAYLOAD
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    // Test Group B: Edge Cases for _fetchTxType() (8 tests)

    function testFetchTxType_FUNDS_MinimalAmount() public {
        uint256 amount = 1; // Minimal non-zero amount
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""), // empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialBalance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify it succeeded with TX_TYPE.FUNDS
        assertEq(prc20Token.balanceOf(user1), initialBalance - amount);
    }

    function testFetchTxType_FUNDS_MaximalAmount() public {
        uint256 amount = LARGE_AMOUNT; // Large amount
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""), // empty payload
            revertRecipient
        );

        uint256 initialBalance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify it succeeded with TX_TYPE.FUNDS
        assertEq(prc20Token.balanceOf(user1), initialBalance - amount);
    }

    function testFetchTxType_GAS_AND_PAYLOAD_SingleBytePayload() public {
        uint256 amount = 0; // No amount
        bytes memory payload = hex"01"; // Single byte payload
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // single byte payload
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED for GAS_AND_PAYLOAD
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    function testFetchTxType_GAS_AND_PAYLOAD_LargePayload() public {
        uint256 amount = 0; // No amount
        // Create a large payload (10KB)
        bytes memory payload = new bytes(10240);
        for (uint256 i = 0; i < 10240; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // large payload
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED for GAS_AND_PAYLOAD
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    function testFetchTxType_FUNDS_AND_PAYLOAD_MinimalPayload() public {
        uint256 amount = 1000 * 1e6;
        bytes memory payload = hex"01"; // Minimal payload
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // minimal payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, payload, SOURCE_CHAIN_NAMESPACE, 0);

        // Expect TX_TYPE.FUNDS_AND_PAYLOAD
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            expectedGasFee,
            DEFAULT_GAS_LIMIT,
            payload,
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testFetchTxType_FUNDS_AND_PAYLOAD_LargePayloadLargeAmount() public {
        uint256 amount = LARGE_AMOUNT;
        // Create a large payload (10KB)
        bytes memory payload = new bytes(10240);
        for (uint256 i = 0; i < 10240; i++) {
            payload[i] = bytes1(uint8(i % 256));
        }
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // large payload
            revertRecipient
        );

        uint256 initialBalance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify both amount and gas fee were charged (TX_TYPE.FUNDS_AND_PAYLOAD)
        assertEq(prc20Token.balanceOf(user1), initialBalance - amount);
    }

    function testFetchTxType_AllZeros_ShouldBeFUNDS() public {
        uint256 amount = 0; // Zero amount
        bytes memory payload = bytes(""); // Empty payload
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // empty payload
            revertRecipient
        );

        // This should revert with InvalidInput since amount = 0 and no payload (empty transaction)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testFetchTxType_EmptyPayloadDifferentConstructions() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        // Test with bytes("")
        UniversalOutboundTxRequest memory req1 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 initialBalance1 = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req1);

        assertEq(prc20Token.balanceOf(user1), initialBalance1 - amount);

        // Reset balance
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        // Test with new bytes(0)
        UniversalOutboundTxRequest memory req2 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, new bytes(0), revertRecipient
        );

        uint256 initialBalance2 = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req2);

        // Both should behave the same (TX_TYPE.FUNDS)
        assertEq(prc20Token.balanceOf(user1), initialBalance2 - amount);
    }

    // Test Group C: Event Emission Verification (3 tests)

    function testEventEmission_CorrectTxType_FUNDS() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""), // empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0);

        // Verify event emits correct TX_TYPE.FUNDS
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            expectedGasFee,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS, // Verify this is FUNDS
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testEventEmission_CorrectTxType_GAS_AND_PAYLOAD() public {
        uint256 amount = 0; // No amount
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // non-empty payload
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED for GAS_AND_PAYLOAD
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded and emitted correct TX_TYPE
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    function testEventEmission_CorrectTxType_FUNDS_AND_PAYLOAD() public {
        uint256 amount = 1000 * 1e6;
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // non-empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);

        // Calculate expected subTxId (nonce should be 0 for first transaction)
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, payload, SOURCE_CHAIN_NAMESPACE, 0);

        // Verify event emits correct TX_TYPE.FUNDS_AND_PAYLOAD
        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId, // subTxId
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            expectedGasFee,
            DEFAULT_GAS_LIMIT,
            payload,
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD, // Verify this is FUNDS_AND_PAYLOAD
            DEFAULT_GAS_PRICE // gasPrice
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    // Test Group D: Validation Order Tests (4 tests)

    function testValidation_ZeroTokenRevertsBeforeTxType() public {
        uint256 amount = 1000 * 1e6;
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(0), // Invalid zero token
            amount,
            DEFAULT_GAS_LIMIT,
            payload,
            revertRecipient
        );

        // Should revert with ZeroAddress before TX_TYPE inference
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    function testValidation_ZeroAmountWithPayload_NotAllowedOnPC() public {
        uint256 amount = 0; // Zero amount
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            payload, // non-empty payload
            revertRecipient
        );

        // Payload-only transactions (amount=0 with payload) are NOW SUPPORTED
        // This enables users to execute payloads using existing CEA funds without burning tokens
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
    }

    function testValidation_ZeroAmountNoPayload_RevertsInValidation() public {
        uint256 amount = 0; // Zero amount
        bytes memory payload = bytes(""); // Empty payload
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req =
            _createOutboundRequest(bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, payload, revertRecipient);

        // Should revert with InvalidInput (from _fetchTxType for empty transactions)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    // Test Group E: Gas Fee Calculation per TX_TYPE (3 tests)

    function testGasFee_FUNDS_CorrectCalculation() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 250_000; // Custom gas limit
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            bytes(""), // empty payload for FUNDS
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasBalance = vaultPC.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify gas tokens were minted to vault via swap
        assertEq(vaultPC.balance, initialGasBalance + DEFAULT_PROTOCOL_FEE);
    }

    function testGasFee_GAS_AND_PAYLOAD_NotSupportedOnPC() public {
        uint256 amount = 0; // No amount
        uint256 gasLimit = 300_000; // Custom gas limit
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasBalance = vaultPC.balance;
        uint256 nonceBefore = gateway.nonce();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify transaction succeeded and gas tokens were minted to vault via swap
        assertEq(gateway.nonce(), nonceBefore + 1, "Nonce should increment");
        assertEq(vaultPC.balance, initialGasBalance + DEFAULT_PROTOCOL_FEE, "Only protocol fee should go to vault");
    }

    function testGasFee_FUNDS_AND_PAYLOAD_CorrectCalculation() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 350_000; // Custom gas limit
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit,
            payload, // non-empty payload for FUNDS_AND_PAYLOAD
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasBalance = vaultPC.balance;
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify gas tokens minted to vault via swap and PRC20 burned
        assertEq(vaultPC.balance, initialGasBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    // Test Group F: Struct Parameter Validation (5 tests)

    function testStruct_AllFieldsPopulated() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory payload = abi.encodeWithSignature("execute()");
        address revertRecipient = user2;

        // Create struct with all fields populated
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20Token),
            amount: amount,
            gasLimit: gasLimit,
            payload: payload,
            revertRecipient: revertRecipient
        });

        uint256 initialBalance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify all fields were correctly processed
        assertEq(prc20Token.balanceOf(user1), initialBalance - amount);
    }

    function testStruct_DefaultGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 0; // Use default
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            gasLimit, // 0 should use DEFAULT_GAS_LIMIT
            bytes(""),
            revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasBalance = vaultPC.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Verify DEFAULT_GAS_LIMIT was used for fee calculation
        assertEq(vaultPC.balance, initialGasBalance + DEFAULT_PROTOCOL_FEE);
    }

    function testStruct_EmptyPayloadBytes() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        // Test both bytes("") and new bytes(0) are treated the same
        UniversalOutboundTxRequest memory req1 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        UniversalOutboundTxRequest memory req2 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, new bytes(0), revertRecipient
        );

        // Both should be treated as TX_TYPE.FUNDS
        uint256 initialBalance1 = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req1);

        assertEq(prc20Token.balanceOf(user1), initialBalance1 - amount);

        // Reset and test second variant
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        uint256 initialBalance2 = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req2);

        assertEq(prc20Token.balanceOf(user1), initialBalance2 - amount);
    }


    function testNonceIncrementAndUniquesubTxId() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        // Verify initial nonce is 0
        assertEq(gateway.nonce(), 0);

        // First transaction
        UniversalOutboundTxRequest memory req1 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        bytes32 expectedsubTxId1 =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId1,
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            calculateExpectedGasFee(DEFAULT_GAS_LIMIT),
            DEFAULT_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req1);

        // Verify nonce incremented to 1
        assertEq(gateway.nonce(), 1);

        // Reset balances for second transaction
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        // Second transaction with same parameters
        UniversalOutboundTxRequest memory req2 = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        bytes32 expectedsubTxId2 = _calculateExpectedsubTxId(
            user1,
            bytes(""),
            address(prc20Token),
            amount,
            bytes(""),
            SOURCE_CHAIN_NAMESPACE,
            1 // nonce is now 1
        );

        // Verify that subTxId2 is different from subTxId1
        assertFalse(expectedsubTxId1 == expectedsubTxId2, "subTxIds should be unique");

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId2,
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            calculateExpectedGasFee(DEFAULT_GAS_LIMIT),
            DEFAULT_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req2);

        // Verify nonce incremented to 2
        assertEq(gateway.nonce(), 2);
    }

    // =========================
    //  RECIPIENT FIELD TESTS
    // =========================

    /// @notice G-R1: bytes("") recipient is emitted verbatim in event
    function testOutbound_RecipientEmpty_EmittedInEvent() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        bytes32 expectedsubTxId =
            _calculateExpectedsubTxId(user1, bytes(""), address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId,
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            bytes(""), // recipient
            amount,
            address(gasToken),
            expectedGasFee,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    /// @notice G-R2: arbitrary bytes recipient is emitted verbatim in event
    function testOutbound_RecipientNonEmpty_EmittedInEvent() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;
        bytes memory arbitraryRecipient = abi.encodePacked(address(0x1234567890123456789012345678901234567890));

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            arbitraryRecipient, address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        bytes32 expectedsubTxId = _calculateExpectedsubTxId(
            user1, arbitraryRecipient, address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedsubTxId,
            user1,
            SOURCE_CHAIN_NAMESPACE,
            address(prc20Token),
            arbitraryRecipient, // recipient emitted verbatim
            amount,
            address(gasToken),
            expectedGasFee,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            revertRecipient,
            TX_TYPE.FUNDS,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    /// @notice G-R3: two requests identical except recipient → different subTxId
    function testOutbound_RecipientIncludedInSubTxId() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;
        bytes memory recipientA = bytes("");
        bytes memory recipientB = abi.encodePacked(address(0xBEEF));

        bytes32 idA = _calculateExpectedsubTxId(
            user1, recipientA, address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0
        );
        bytes32 idB = _calculateExpectedsubTxId(
            user1, recipientB, address(prc20Token), amount, bytes(""), SOURCE_CHAIN_NAMESPACE, 0
        );

        assertFalse(idA == idB, "Different recipients must produce different subTxIds");
    }

    /// @notice G-R4: bytes("") recipient accepted for all outbound TX_TYPEs without revert
    function testOutbound_RecipientNotValidated_AllTxTypes() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;
        bytes memory payload = abi.encodeWithSignature("execute()");

        // FUNDS
        UniversalOutboundTxRequest memory reqFunds = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(reqFunds);

        // Replenish
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        // FUNDS_AND_PAYLOAD
        UniversalOutboundTxRequest memory reqFAP = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, payload, revertRecipient
        );
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(reqFAP);

        // GAS_AND_PAYLOAD (amount=0, payload non-empty)
        UniversalOutboundTxRequest memory reqGAP = _createOutboundRequest(
            bytes(""), address(prc20Token), 0, DEFAULT_GAS_LIMIT, payload, revertRecipient
        );
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(reqGAP);
    }

    // =========================
    //  AUTO-SWAP FEE TESTS
    // =========================

    function testSwapFees_ZeroPCAmount_Reverts() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        // msg.value = 0 but protocolFee > 0 → reverts with InvalidInput (insufficient for protocol fee)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: 0}(req);
    }

    function testSwapFees_PayableAcceptsPC() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);
        uint256 initialGasTokenBalance = vaultPC.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // User's PRC20 burned, gas tokens minted to vault via swap
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
        assertTrue(vaultPC.balance > initialGasTokenBalance);
    }

    function testBurnBeforeSwap_Ordering() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // PRC20 burned (balance decreased)
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
        // Gateway should not hold any PRC20 (burn pulls then burns)
        assertEq(prc20Token.balanceOf(address(gateway)), 0);
    }

    function testRefund_UserReceivesExcessPC() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 expectedTotal = calculateExpectedTotal(DEFAULT_GAS_LIMIT);
        uint256 userBalanceBefore = user1.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // User gets refund: PC_FEE - (gasFee + protocolFee) (mock uses 1:1 PC-to-gasToken ratio)
        uint256 expectedRefund = PC_FEE - expectedTotal;
        assertEq(user1.balance, userBalanceBefore - PC_FEE + expectedRefund);
    }

    function testRefund_NoRefundWhenExactAmount() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        uint256 expectedTotal = calculateExpectedTotal(DEFAULT_GAS_LIMIT);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        uint256 userBalanceBefore = user1.balance;

        // Send exactly gasFee + protocolFee as msg.value (no refund expected)
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: expectedTotal}(req);

        // User spent exactly total, no refund
        assertEq(user1.balance, userBalanceBefore - expectedTotal);
    }

    // =========================
    //  GAS TOKEN BURN VERIFICATION TESTS
    // =========================

    function testBurn_OnlyProtocolFeeInVault() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        uint256 initialVaultBalance = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Vault should only receive protocolFee, not gasFee
        assertEq(vaultPC.balance, initialVaultBalance + DEFAULT_PROTOCOL_FEE);
    }

    function testBurn_GasTokenBurnedNotAccumulated() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        uint256 supplyBefore = gasToken.totalSupply();
        uint256 initialVaultBalance = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // gasFee was minted then burned — net supply change is zero (protocolFee sent as native PC, not minted)
        assertEq(gasToken.totalSupply(), supplyBefore);
        // Vault only holds protocolFee
        assertEq(vaultPC.balance, initialVaultBalance + DEFAULT_PROTOCOL_FEE);
    }

    function testBurn_ZeroProtocolFee_VaultGetsNothing() public {
        // Deploy a token with zero protocol fee
        MockPRC20 zeroFeeToken = new MockPRC20(
            "Zero Fee Token",
            "ZFT",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );
        // protocolFeeByToken defaults to 0 — no setProtocolFeeByToken call needed

        uint256 amount = 1000 * 1e6;
        zeroFeeToken.mint(user1, amount);
        vm.prank(user1);
        zeroFeeToken.approve(address(gateway), amount);

        uint256 initialVaultBalance = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(zeroFeeToken), amount, DEFAULT_GAS_LIMIT, bytes(""), user2
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        // Vault gets nothing when protocolFee is 0
        assertEq(vaultPC.balance, initialVaultBalance);
    }

    function testRefund_ForwardFailure_Reverts() public {
        uint256 amount = 1000 * 1e6;
        address revertRecipient = user2;

        // Deploy a contract that rejects ETH transfers
        ETHRejecter rejecter = new ETHRejecter();
        vm.deal(address(rejecter), 100 ether);
        prc20Token.mint(address(rejecter), LARGE_AMOUNT);
        vm.prank(address(rejecter));
        prc20Token.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""), address(prc20Token), amount, DEFAULT_GAS_LIMIT, bytes(""), revertRecipient
        );

        // Rejecter sends more than gasFee, so UniversalCore's refund to caller fails
        vm.prank(address(rejecter));
        vm.expectRevert("MockUniversalCore: refund failed");
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);
    }

    // ============================================================
    //  msg.value < protocolFee
    // ============================================================

    function testVaultPCTransferFailure_Reverts() public {
        // Deploy a contract that rejects ETH as VaultPC
        ETHRejecter rejectingVault = new ETHRejecter();

        vm.prank(admin);
        gateway.setVaultPC(address(rejectingVault));

        uint256 amount = 1000 * 1e6;
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            user2
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function testZeroProtocolFee_VaultGetsNothing() public {
        // Token with no protocol fee set (defaults to 0)
        MockPRC20 noFeeToken = new MockPRC20(
            "No Fee Token",
            "NFT",
            6,
            SOURCE_CHAIN_NAMESPACE,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        uint256 amount = 1000 * 1e6;
        noFeeToken.mint(user1, amount);
        vm.prank(user1);
        noFeeToken.approve(address(gateway), amount);

        uint256 vaultBalBefore = vaultPC.balance;

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(noFeeToken),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            user2
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        // VaultPC should NOT have received any protocolFee
        assertEq(vaultPC.balance, vaultBalBefore);
    }

    function testRevert_InsufficientMsgValueForProtocolFee() public {
        uint256 amount = 1000 * 1e6;

        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        UniversalOutboundTxRequest memory req = _createOutboundRequest(
            bytes(""),
            address(prc20Token),
            amount,
            DEFAULT_GAS_LIMIT,
            bytes(""),
            user2
        );

        // protocolFee = DEFAULT_PROTOCOL_FEE = 0.01 ether
        // Send less than protocolFee
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{ value: 0.001 ether }(req);
    }
}

/// @dev Helper contract that rejects native token transfers (for testing refund failure)
contract ETHRejecter {
    // No receive() or fallback() — rejects all ETH transfers
}
