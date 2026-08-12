// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { VaultPC20 } from "../../src/VaultPC20.sol";
import { TX_TYPE } from "../../src/libraries/Types.sol";
import { UniversalOutboundTxRequest, PC_20_SELECTOR as TYPES_PC_20_SELECTOR } from "../../src/libraries/TypesUGPC.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";
import { MockPC20Token, MockPlainERC20, MockFeeOnTransferPC20 } from "../mocks/MockPC20Token.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ExportPC20Test is Test {
    // ===== ACTORS =====
    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public attacker;
    address public uem;
    address public vaultPCAddr;

    // ===== CONTRACTS =====
    UniversalGatewayPC public gateway;
    TransparentUpgradeableProxy public gatewayProxy;
    ProxyAdmin public proxyAdmin;
    VaultPC20 public vaultPC20;
    MockUniversalCoreReal public universalCore;

    // ===== TOKENS =====
    MockPC20Token public pc20Token;
    MockPC20Token public pc20TokenB;
    MockPRC20 public gasToken;

    // ===== CONSTANTS =====
    uint256 public constant BASE_GAS_LIMIT = 100_000;
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0.01 ether;
    uint256 public constant PC_FEE = 1 ether;
    bytes4 public constant PC_20_SELECTOR = 0x50433230;
    string public constant DEST_CHAIN = "eip155:1";
    string public constant DEST_CHAIN_B = "eip155:42161";

    // ===== SETUP =====
    function setUp() public {
        _createActors();
        _deployMocks();
        _deployVaultPC20();
        _deployGateway();
        _wireGatewayToVaultPC20();
        _setupTokens();
    }

    function _createActors() internal {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        attacker = makeAddr("attacker");
        uem = makeAddr("uem");
        vaultPCAddr = makeAddr("vaultPC");

        vm.deal(admin, 100 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(attacker, 100 ether);
    }

    function _deployMocks() internal {
        universalCore = new MockUniversalCoreReal(uem);

        gasToken = new MockPRC20(
            "Push Chain Native", "PC", 18, DEST_CHAIN, MockPRC20.TokenType.PC, address(universalCore), ""
        );

        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN, BASE_GAS_LIMIT);

        pc20Token = new MockPC20Token("PushToken", "PTK", 18);
        pc20TokenB = new MockPC20Token("PushTokenB", "PTKB", 18);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(pc20Token), DEFAULT_PROTOCOL_FEE);
    }

    function _deployVaultPC20() internal {
        VaultPC20 impl = new VaultPC20();
        address tempGateway = makeAddr("tempGateway");
        bytes memory data = abi.encodeWithSelector(VaultPC20.initialize.selector, admin, pauser, tempGateway);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        vaultPC20 = VaultPC20(address(proxy));
    }

    function _deployGateway() internal {
        UniversalGatewayPC impl = new UniversalGatewayPC();
        proxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector, admin, pauser, address(universalCore), vaultPCAddr
        );
        gatewayProxy = new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        gateway = UniversalGatewayPC(address(gatewayProxy));

        vm.prank(admin);
        gateway.updateVaultPC20(address(vaultPC20));
    }

    function _wireGatewayToVaultPC20() internal {
        vm.prank(admin);
        vaultPC20.updateUniversalGatewayPC(address(gateway));
    }

    function _setupTokens() internal {
        pc20Token.mint(user1, 1_000_000e18);
        pc20Token.mint(user2, 1_000_000e18);
        pc20TokenB.mint(user1, 500_000e18);

        vm.prank(user1);
        pc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user2);
        pc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user1);
        pc20TokenB.approve(address(gateway), type(uint256).max);
    }

    // ===== HELPERS =====

    function _buildPC20Payload(
        string memory destChain,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes memory userCalldata
    ) internal view returns (bytes memory) {
        bytes memory metadata = abi.encode(destChain, name, symbol, decimals);
        return abi.encodePacked(PC_20_SELECTOR, metadata, userCalldata);
    }

    function _defaultPC20Payload() internal view returns (bytes memory) {
        return _buildPC20Payload(DEST_CHAIN, "PushToken", "PTK", 18, bytes(""));
    }

    function _tokenMeta(address token)
        internal
        view
        returns (string memory name, string memory symbol, uint8 decimals)
    {
        if (token == address(pc20Token)) {
            return ("PushToken", "PTK", 18);
        } else if (token == address(pc20TokenB)) {
            return ("PushTokenB", "PTKB", 18);
        }
        return (ERC20(token).name(), ERC20(token).symbol(), ERC20(token).decimals());
    }

    function _buildPC20Request(
        address token,
        uint256 amount,
        string memory destChain,
        uint256 gasLimit,
        uint256 maxPCForGas,
        bytes memory userCalldata,
        address revertRecipient
    ) internal view returns (UniversalOutboundTxRequest memory) {
        (string memory name, string memory symbol, uint8 decimals) = _tokenMeta(token);

        bytes memory payload = _buildPC20Payload(destChain, name, symbol, decimals, userCalldata);

        return UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: token,
            amount: amount,
            gasLimit: gasLimit,
            gasPrice: 0,
            maxPCForGas: maxPCForGas,
            payload: payload,
            revertRecipient: revertRecipient
        });
    }

    function _defaultReq(uint256 amount) internal view returns (UniversalOutboundTxRequest memory) {
        return _buildPC20Request(address(pc20Token), amount, DEST_CHAIN, 0, 0, bytes(""), user2);
    }

    function _expectedGasFee(uint256 limit) internal pure returns (uint256) {
        return DEFAULT_GAS_PRICE * limit;
    }

    function _dummyWrapper() internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address(0xCAFE))));
    }

    function _expectedSubTxId(
        address sender,
        bytes memory recipient,
        address token,
        uint256 amount,
        bytes memory payload,
        string memory dest,
        uint256 n
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, recipient, token, amount, keccak256(payload), dest, n));
    }

    // ================================================================
    // PC20 EXPORT VIA MERGED FUNCTION — HAPPY PATH
    // ================================================================

    function test_ExportPC20_DefaultGasLimit() public {
        uint256 amount = 100e18;
        UniversalOutboundTxRequest memory req = _defaultReq(amount);

        uint256 vaultBalBefore = pc20Token.balanceOf(address(vaultPC20));

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        assertEq(pc20Token.balanceOf(address(vaultPC20)), vaultBalBefore + amount);
        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
        assertEq(gateway.nonce(), 1);
    }

    function test_ExportPC20_CustomGasLimit() public {
        uint256 amount = 50e18;
        uint256 gasLimit = 200_000;

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), amount, DEST_CHAIN, gasLimit, 0, bytes(""), user2);

        uint256 gasFee = _expectedGasFee(gasLimit);
        bytes32 expectedId = _expectedSubTxId(
            user1, abi.encodePacked(address(0xDEAD)), address(pc20Token), amount, req.payload, DEST_CHAIN, 0
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            abi.encodePacked(address(0xDEAD)),
            amount,
            address(gasToken),
            gasFee,
            gasLimit,
            req.payload,
            DEFAULT_PROTOCOL_FEE,
            user2,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_WithUserCalldata() public {
        uint256 amount = 75e18;
        bytes memory userCalldata = abi.encodeWithSignature("doSomething(uint256)", 42);
        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), amount, DEST_CHAIN, 0, 0, userCalldata, user2);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
    }

    function test_ExportPC20_NoUserCalldata() public {
        uint256 amount = 30e18;
        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), amount, DEST_CHAIN, 0, 0, bytes(""), user2);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
    }

    function test_ExportPC20_SequentialNonce() public {
        UniversalOutboundTxRequest memory req = _defaultReq(10e18);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        assertEq(gateway.nonce(), 1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        assertEq(gateway.nonce(), 2);
    }

    function test_ExportPC20_DifferentSendersUniqueSubTxId() public {
        UniversalOutboundTxRequest memory req = _defaultReq(10e18);

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();

        vm.recordLogs();
        vm.prank(user2);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        bytes32 id1 = logs1[logs1.length - 1].topics[1];
        bytes32 id2 = logs2[logs2.length - 1].topics[1];
        assertFalse(id1 == id2);
    }

    function test_ExportPC20_ProtocolFeeToVaultPC() public {
        uint256 vaultBal = vaultPCAddr.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(10e18));

        assertEq(vaultPCAddr.balance, vaultBal + DEFAULT_PROTOCOL_FEE);
    }

    function test_ExportPC20_MaxPCForGas_RefundExcess() public {
        uint256 amount = 10e18;
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);
        uint256 maxPC = gasFee + 0.1 ether;

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), amount, DEST_CHAIN, 0, maxPC, bytes(""), user2);

        uint256 pcSent = 2 ether;
        uint256 balBefore = user1.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: pcSent }(req);

        uint256 totalSpent = balBefore - user1.balance;
        assertLe(totalSpent, DEFAULT_PROTOCOL_FEE + maxPC);
        assertGt(user1.balance, balBefore - pcSent);
    }

    function test_ExportPC20_DeploymentOverhead() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);

        uint256 amount = 10e18;
        uint256 expectedLimit = BASE_GAS_LIMIT + overhead;
        uint256 gasFee = _expectedGasFee(expectedLimit);

        UniversalOutboundTxRequest memory req = _defaultReq(amount);

        bytes32 expectedId = _expectedSubTxId(
            user1, abi.encodePacked(address(0xDEAD)), address(pc20Token), amount, req.payload, DEST_CHAIN, 0
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            abi.encodePacked(address(0xDEAD)),
            amount,
            address(gasToken),
            gasFee,
            expectedLimit,
            req.payload,
            DEFAULT_PROTOCOL_FEE,
            user2,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_DifferentDestChains() public {
        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN_B, 5 gwei);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN_B, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN_B, 200_000);

        UniversalOutboundTxRequest memory reqA =
            _buildPC20Request(address(pc20Token), 10e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        UniversalOutboundTxRequest memory reqB =
            _buildPC20Request(address(pc20Token), 20e18, DEST_CHAIN_B, 0, 0, bytes(""), user2);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(reqA);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(reqB);

        assertEq(vaultPC20.totalLocked(address(pc20Token)), 30e18);
        assertEq(gateway.nonce(), 2);
    }

    // ================================================================
    // PC20 EXPORT — VALIDATION REVERTS
    // ================================================================

    function test_ExportPC20_RevertsZeroToken() public {
        bytes memory payload = _buildPC20Payload(DEST_CHAIN, "PushToken", "PTK", 18, bytes(""));
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(0),
            amount: 10e18,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsZeroAmount() public {
        bytes memory payload = _defaultPC20Payload();
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: 0,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsZeroRevertRecipient() public {
        bytes memory payload = _defaultPC20Payload();
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: 10e18,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: address(0)
        });
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    /// @dev PC20 export is permissionless: a plain ERC-20 with no PC20-specific
    ///      surface exports normally. Destination metadata travels in the payload,
    ///      so the token itself needs no extra interface.
    function test_ExportPC20_PlainERC20Succeeds() public {
        MockPlainERC20 plainToken = new MockPlainERC20();
        plainToken.mint(user1, 100e18);
        vm.prank(user1);
        plainToken.approve(address(gateway), type(uint256).max);

        uint256 amount = 10e18;
        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(plainToken), amount, DEST_CHAIN, 0, 0, bytes(""), user2);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        assertEq(plainToken.balanceOf(address(vaultPC20)), amount);
        assertEq(vaultPC20.totalLocked(address(plainToken)), amount);
        assertEq(gateway.nonce(), 1);
    }

    function test_ExportPC20_RevertsEmptyDestChainNamespace() public {
        bytes memory payload = _buildPC20Payload("", "PushToken", "PTK", 18, bytes(""));
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: 10e18,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsUnconfiguredDestChain() public {
        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), 10e18, "eip155:999", 0, 0, bytes(""), user2);
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsInsufficientMsgValue() public {
        UniversalOutboundTxRequest memory req = _defaultReq(10e18);
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{ value: 0.001 ether }(req);
    }

    function test_ExportPC20_RevertsMalformedPayload() public {
        bytes memory payload = abi.encodePacked(PC_20_SELECTOR, bytes("not valid abi data"));
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: 10e18,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    // ================================================================
    // PC20 EXPORT — TOKEN TRANSFER EDGE CASES
    // ================================================================

    function test_ExportPC20_RevertsNoAllowance() public {
        MockPC20Token freshToken = new MockPC20Token("Fresh", "FRH", 18);
        freshToken.mint(user1, 100e18);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(freshToken), DEFAULT_PROTOCOL_FEE);

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(freshToken), 10e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsInsufficientBalance() public {
        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), 99_999_999e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_RevertsFeeOnTransfer() public {
        MockFeeOnTransferPC20 fot = new MockFeeOnTransferPC20(1e18);
        fot.mint(user1, 100e18);
        vm.prank(user1);
        fot.approve(address(gateway), type(uint256).max);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(fot), DEFAULT_PROTOCOL_FEE);

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(fot), 10e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        vm.prank(user1);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    // ================================================================
    // MAGIC SELECTOR EDGE CASES
    // ================================================================

    function test_MagicSelector_PayloadShorterThan4Bytes() public {
        MockPRC20 prc20 = new MockPRC20(
            "Push USDC",
            "pUSDC",
            6,
            DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20),
            amount: 1000e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: hex"AABB",
            revertRecipient: user2
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        assertEq(gateway.nonce(), 1);
    }

    function test_MagicSelector_EmptyPayloadPRC20() public {
        MockPRC20 prc20 = new MockPRC20(
            "Push USDC",
            "pUSDC",
            6,
            DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20),
            amount: 1000e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: user2
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        assertEq(gateway.nonce(), 1);
    }

    function test_MagicSelector_4BytesNotPC20_PRC20Path() public {
        MockPRC20 prc20 = new MockPRC20(
            "Push USDC",
            "pUSDC",
            6,
            DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20),
            amount: 1000e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: hex"DEADBEEF",
            revertRecipient: user2
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        assertEq(gateway.nonce(), 1);
    }

    function test_MagicSelector_Exactly4BytesIsPC20_Reverts() public {
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: 10e18,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: abi.encodePacked(PC_20_SELECTOR),
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    // ================================================================
    // PC20 EXPORT — GAS SWAP EDGE CASES
    // ================================================================

    function test_ExportPC20_MaxPCForGas_TightCap() public {
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), 10e18, DEST_CHAIN, 0, gasFee, bytes(""), user2);

        uint256 pcSent = 2 ether;
        uint256 balBefore = user1.balance;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: pcSent }(req);

        uint256 expectedSpent = DEFAULT_PROTOCOL_FEE + gasFee;
        assertEq(balBefore - user1.balance, expectedSpent);
    }

    function test_ExportPC20_MaxPCForGas_ExceedsPcForSwap() public {
        uint256 pcSent = 0.5 ether;
        uint256 maxPC = pcSent;

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20Token), 10e18, DEST_CHAIN, 0, maxPC, bytes(""), user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTxOutbound{ value: pcSent }(req);
    }

    // ================================================================
    // PAUSE AND ACCESS CONTROL
    // ================================================================

    function test_ExportPC20_RevertsWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(10e18));
    }

    function test_ExportPC20_WorksAfterUnpause() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(admin);
        gateway.unpause();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(10e18));

        assertEq(gateway.nonce(), 1);
    }

    // ================================================================
    // EVENT VERIFICATION
    // ================================================================

    function test_ExportPC20_EmitsUniversalTxOutbound() public {
        uint256 amount = 25e18;
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);
        bytes memory recipient = abi.encodePacked(address(0xDEAD));

        UniversalOutboundTxRequest memory req = _defaultReq(amount);

        bytes32 expectedId = _expectedSubTxId(user1, recipient, address(pc20Token), amount, req.payload, DEST_CHAIN, 0);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGatewayPC.UniversalTxOutbound(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            recipient,
            amount,
            address(gasToken),
            gasFee,
            BASE_GAS_LIMIT,
            req.payload,
            DEFAULT_PROTOCOL_FEE,
            user2,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
    }

    function test_ExportPC20_PayloadStartsWithSelector() public {
        UniversalOutboundTxRequest memory req = _defaultReq(10e18);

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory lastLog = logs[logs.length - 1];
        bytes memory payload = _decodePayloadFromEvent(lastLog);

        bytes4 selector;
        assembly { selector := mload(add(payload, 32)) }
        assertEq(selector, PC_20_SELECTOR);
    }

    function test_ExportPC20_TxTypeIsFundsAndPayload() public {
        UniversalOutboundTxRequest memory req = _defaultReq(10e18);

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory lastLog = logs[logs.length - 1];
        TX_TYPE txType = _decodeTxTypeFromEvent(lastLog);
        assertEq(uint8(txType), uint8(TX_TYPE.FUNDS_AND_PAYLOAD));
    }

    function _decodePayloadFromEvent(Vm.Log memory logEntry) internal pure returns (bytes memory payload) {
        (,,,,,, payload,,,,) = abi.decode(
            logEntry.data,
            (string, bytes, uint256, address, uint256, uint256, bytes, uint256, address, TX_TYPE, uint256)
        );
    }

    function _decodeTxTypeFromEvent(Vm.Log memory logEntry) internal pure returns (TX_TYPE txType) {
        (,,,,,,,,, txType,) = abi.decode(
            logEntry.data,
            (string, bytes, uint256, address, uint256, uint256, bytes, uint256, address, TX_TYPE, uint256)
        );
    }

    // ================================================================
    // ACCOUNTING INTEGRITY
    // ================================================================

    function test_ExportPC20_MultipleExportsSameToken() public {
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(100e18));

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(200e18));

        assertEq(vaultPC20.totalLocked(address(pc20Token)), 300e18);
        assertEq(pc20Token.balanceOf(address(vaultPC20)), 300e18);
    }

    function test_ExportPC20_MultipleTokens() public {
        vm.prank(uem);
        universalCore.setProtocolFeeByToken(address(pc20TokenB), DEFAULT_PROTOCOL_FEE);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(100e18));

        UniversalOutboundTxRequest memory reqB =
            _buildPC20Request(address(pc20TokenB), 50e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(reqB);

        assertEq(vaultPC20.totalLocked(address(pc20Token)), 100e18);
        assertEq(vaultPC20.totalLocked(address(pc20TokenB)), 50e18);
    }

    function test_ExportPC20_ZeroProtocolFee() public {
        uint256 vaultBal = vaultPCAddr.balance;

        UniversalOutboundTxRequest memory req =
            _buildPC20Request(address(pc20TokenB), 10e18, DEST_CHAIN, 0, 0, bytes(""), user2);
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(req);

        assertEq(vaultPCAddr.balance, vaultBal);
    }

    // ================================================================
    // PRC20 / PC20 INTERACTION
    // ================================================================

    function test_SharedNonce_PC20ThenPRC20() public {
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(10e18));
        assertEq(gateway.nonce(), 1);

        MockPRC20 prc20 = new MockPRC20(
            "Push USDC",
            "pUSDC",
            6,
            DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory outReq = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20),
            amount: 1000e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: user2
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(outReq);
        assertEq(gateway.nonce(), 2);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(10e18));
        assertEq(gateway.nonce(), 3);
    }

    function test_PRC20DoesNotAffectPC20Lock() public {
        MockPRC20 prc20 = new MockPRC20(
            "Push USDC",
            "pUSDC",
            6,
            DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        UniversalOutboundTxRequest memory outReq = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20),
            amount: 1000e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: user2
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(outReq);

        uint256 amount = 50e18;
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{ value: PC_FEE }(_defaultReq(amount));

        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
    }

    // ================================================================
    // UPDATE VAULT PC20
    // ================================================================

    function test_UpdateVaultPC20_Success() public {
        address newVault = makeAddr("newVault");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IUniversalGatewayPC.VaultPC20Updated(address(vaultPC20), newVault);
        gateway.updateVaultPC20(newVault);

        assertEq(address(gateway.vaultPC20()), newVault);
    }

    function test_UpdateVaultPC20_RevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.updateVaultPC20(address(0));
    }

    function test_UpdateVaultPC20_RevertsNonOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.updateVaultPC20(makeAddr("x"));
    }

    function test_UpdateVaultPC20_RevertsWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(admin);
        vm.expectRevert();
        gateway.updateVaultPC20(makeAddr("x"));
    }

    // ================================================================
    // PC_20_SELECTOR CONSTANT
    // ================================================================

    function test_PC20Selector_Value() public pure {
        assertEq(TYPES_PC_20_SELECTOR, bytes4(0x50433230));
        assertEq(TYPES_PC_20_SELECTOR, PC_20_SELECTOR);
    }

    // ================================================================
    // GET PC20 EXPORT GAS AND FEES (Mock UniversalCore)
    // ================================================================

    function test_GetPC20ExportGasAndFees_DefaultLimit() public view {
        (address gt, uint256 gasFee, uint256 protocolFee, uint256 gasPrice,, uint256 gasLimitUsed,) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));

        assertEq(gt, address(gasToken));
        assertEq(gasPrice, DEFAULT_GAS_PRICE);
        assertEq(gasLimitUsed, BASE_GAS_LIMIT);
        assertEq(gasFee, DEFAULT_GAS_PRICE * BASE_GAS_LIMIT);
        assertEq(protocolFee, DEFAULT_PROTOCOL_FEE);
    }

    function test_GetPC20ExportGasAndFees_CustomLimit() public view {
        uint256 customLimit = 300_000;
        (,,,,, uint256 gasLimitUsed,) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN, customLimit, address(pc20Token));
        assertEq(gasLimitUsed, customLimit);
    }

    function test_GetPC20ExportGasAndFees_WithOverhead() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);

        (,,,,, uint256 gasLimitUsed, bool isFirst) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));

        assertEq(gasLimitUsed, BASE_GAS_LIMIT + overhead);
        assertTrue(isFirst);
    }

    function test_GetPC20ExportGasAndFees_NoOverhead() public view {
        (,,,,,, bool isFirst) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));
        assertFalse(isFirst);
    }

    function test_GetPC20ExportGasAndFees_NoProtocolFee() public view {
        (,, uint256 protocolFee,,,,) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20TokenB));
        assertEq(protocolFee, 0);
    }

    function test_GetPC20ExportGasAndFees_RevertsNoGasToken() public {
        vm.expectRevert("MockUniversalCore: zero gas token");
        universalCore.getPC20ExportGasAndFees("eip155:999", 0, address(pc20Token));
    }

    function test_GetPC20ExportGasAndFees_RevertsNoGasPrice() public {
        vm.prank(uem);
        universalCore.setGasTokenPRC20("eip155:56", address(gasToken));
        universalCore.setBaseGasLimitByChain("eip155:56", 100_000);

        vm.expectRevert("MockUniversalCore: zero gas price");
        universalCore.getPC20ExportGasAndFees("eip155:56", 0, address(pc20Token));
    }

    function test_GetPC20ExportGasAndFees_RevertsNoBaseLimit() public {
        vm.prank(uem);
        universalCore.setGasTokenPRC20("eip155:137", address(gasToken));
        vm.prank(uem);
        universalCore.setGasPrice("eip155:137", DEFAULT_GAS_PRICE);

        vm.expectRevert("MockUniversalCore: zero base gas limit");
        universalCore.getPC20ExportGasAndFees("eip155:137", 0, address(pc20Token));
    }

    function test_GetPC20ExportGasAndFees_RevertsGasLimitBelowBase() public {
        vm.expectRevert("MockUniversalCore: gas limit below base");
        universalCore.getPC20ExportGasAndFees(DEST_CHAIN, BASE_GAS_LIMIT / 2, address(pc20Token));
    }

    function test_GetPC20ExportGasAndFees_MultiChainIndependent() public {
        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN_B, 5 gwei);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN_B, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN_B, 200_000);

        (,,,,, uint256 limitA,) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));
        (, uint256 feeB,,,, uint256 limitB,) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN_B, 0, address(pc20Token));

        assertEq(limitA, BASE_GAS_LIMIT);
        assertEq(limitB, 200_000);
        assertEq(feeB, 5 gwei * 200_000);
    }

    // ========================================
    //  getPC20ExportGasAndFees — Deploy Flag
    // ========================================

    function test_GetPC20ExportGasAndFees_DeployFlagSkipsOverhead() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);

        vm.prank(uem);
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN, _dummyWrapper());

        (,,,,, uint256 gasLimitUsed, bool isFirst) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));

        assertEq(gasLimitUsed, BASE_GAS_LIMIT);
        assertFalse(isFirst);
    }

    function test_GetPC20ExportGasAndFees_DeployFlagPerToken() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);

        vm.prank(uem);
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN, _dummyWrapper());

        (,,,,, uint256 limitA, bool isFirstA) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));
        assertEq(limitA, BASE_GAS_LIMIT);
        assertFalse(isFirstA);

        (,,,,, uint256 limitB, bool isFirstB) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20TokenB));
        assertEq(limitB, BASE_GAS_LIMIT + overhead);
        assertTrue(isFirstB);
    }

    function test_GetPC20ExportGasAndFees_DeployFlagPerChain() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);

        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN_B, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN_B, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN_B, BASE_GAS_LIMIT);
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN_B, overhead);

        vm.prank(uem);
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN, _dummyWrapper());

        (,,,,, uint256 limitA, bool isFirstA) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));
        assertEq(limitA, BASE_GAS_LIMIT);
        assertFalse(isFirstA);

        (,,,,, uint256 limitB, bool isFirstB) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN_B, 0, address(pc20Token));
        assertEq(limitB, BASE_GAS_LIMIT + overhead);
        assertTrue(isFirstB);
    }

    function test_GetPC20ExportGasAndFees_MultiChainDeployFlags() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN, overhead);
        universalCore.setPC20DeploymentGasOverhead(DEST_CHAIN_B, overhead);
        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN_B, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN_B, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN_B, BASE_GAS_LIMIT);

        vm.prank(uem);
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN, _dummyWrapper());
        vm.prank(uem);
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN_B, _dummyWrapper());

        (,,,,, uint256 limitA, bool isFirstA) = universalCore.getPC20ExportGasAndFees(DEST_CHAIN, 0, address(pc20Token));
        assertEq(limitA, BASE_GAS_LIMIT);
        assertFalse(isFirstA);

        (,,,,, uint256 limitB, bool isFirstB) =
            universalCore.getPC20ExportGasAndFees(DEST_CHAIN_B, 0, address(pc20Token));
        assertEq(limitB, BASE_GAS_LIMIT);
        assertFalse(isFirstB);
    }

    function test_SetWrapperDeployed_MockOnlyUEModule() public {
        vm.expectRevert("MockUniversalCore: caller is not UEM");
        vm.prank(makeAddr("notUem"));
        universalCore.setWrapperDeployed(address(pc20Token), DEST_CHAIN, _dummyWrapper());
    }
}
