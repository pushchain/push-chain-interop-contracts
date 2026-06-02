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
import { UniversalOutboundTxRequest, PC20ExportRequest } from "../../src/libraries/TypesUGPC.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";
import { MockPC20Token, MockNonPC20Token, MockFeeOnTransferPC20 } from "../mocks/MockPC20Token.sol";

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
    string public constant DEST_CHAIN = "eip155:1";
    string public constant DEST_CHAIN_B = "eip155:42161";

    // ===== EVENTS =====
    event PC20ExportInitiated(
        bytes32 indexed subTxId,
        address indexed sender,
        string  destChainNamespace,
        address indexed token,
        bytes   recipient,
        uint256 amount,
        address gasToken_,
        uint256 gasFee,
        uint256 gasLimitUsed,
        bytes   payload,
        uint256 protocolFee,
        address revertRecipient,
        uint256 gasPrice
    );

    event VaultPC20Updated(
        address indexed oldVaultPC20,
        address indexed newVaultPC20
    );

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
            "Push Chain Native", "PC", 18, DEST_CHAIN,
            MockPRC20.TokenType.PC, address(universalCore), ""
        );

        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN, BASE_GAS_LIMIT);

        pc20Token = new MockPC20Token("PushToken", "PTK", 18);
        pc20TokenB = new MockPC20Token("PushTokenB", "PTKB", 18);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(pc20Token), DEFAULT_PROTOCOL_FEE
        );
    }

    function _deployVaultPC20() internal {
        VaultPC20 impl = new VaultPC20();
        // We'll use a temporary gateway address, then update after gateway is deployed
        address tempGateway = makeAddr("tempGateway");
        bytes memory data = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            admin, pauser, tss, tempGateway
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        vaultPC20 = VaultPC20(address(proxy));
    }

    function _deployGateway() internal {
        UniversalGatewayPC impl = new UniversalGatewayPC();
        proxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin, pauser, address(universalCore), vaultPCAddr
        );
        gatewayProxy = new TransparentUpgradeableProxy(
            address(impl), address(proxyAdmin), initData
        );
        gateway = UniversalGatewayPC(address(gatewayProxy));

        // Set vaultPC20 on gateway
        vm.prank(admin);
        gateway.updateVaultPC20(address(vaultPC20));
    }

    function _wireGatewayToVaultPC20() internal {
        // Update VaultPC20 to point to the real gateway
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

    function _buildExportReq(
        address token,
        uint256 amount,
        string memory dest,
        uint256 gasLimit,
        uint256 maxPCForGas,
        bytes memory payload,
        address revertRecipient
    ) internal pure returns (PC20ExportRequest memory) {
        return PC20ExportRequest({
            recipient: abi.encodePacked(
                address(0xDEAD)
            ),
            token: token,
            amount: amount,
            destChainNamespace: dest,
            gasLimit: gasLimit,
            maxPCForGas: maxPCForGas,
            payload: payload,
            revertRecipient: revertRecipient
        });
    }

    function _defaultReq(uint256 amount)
        internal
        view
        returns (PC20ExportRequest memory)
    {
        return _buildExportReq(
            address(pc20Token),
            amount,
            DEST_CHAIN,
            0,
            0,
            bytes(""),
            user2
        );
    }

    function _expectedGasFee(uint256 limit)
        internal
        pure
        returns (uint256)
    {
        return DEFAULT_GAS_PRICE * limit;
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
        return keccak256(abi.encode(
            sender, recipient, token, amount,
            keccak256(payload), dest, n
        ));
    }

    // ================================================================
    // EXPORT PC20 — HAPPY PATH
    // ================================================================

    function test_ExportPC20_DefaultGasLimit() public {
        uint256 amount = 100e18;
        PC20ExportRequest memory req = _defaultReq(amount);

        uint256 vaultBalBefore = pc20Token.balanceOf(address(vaultPC20));

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);

        assertEq(
            pc20Token.balanceOf(address(vaultPC20)),
            vaultBalBefore + amount
        );
        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
        assertEq(gateway.nonce(), 1);
    }

    function test_ExportPC20_CustomGasLimit() public {
        uint256 amount = 50e18;
        uint256 gasLimit = 200_000;

        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), amount, DEST_CHAIN,
            gasLimit, 0, bytes(""), user2
        );

        uint256 gasFee = _expectedGasFee(gasLimit);
        bytes32 expectedId = _expectedSubTxId(
            user1,
            abi.encodePacked(address(0xDEAD)),
            address(pc20Token),
            amount,
            bytes(""),
            DEST_CHAIN,
            0
        );

        vm.expectEmit(true, true, true, true);
        emit PC20ExportInitiated(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            abi.encodePacked(address(0xDEAD)),
            amount,
            address(gasToken),
            gasFee,
            gasLimit,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            user2,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_WithPayload() public {
        uint256 amount = 75e18;
        bytes memory payload = abi.encodeWithSignature(
            "doSomething(uint256)", 42
        );
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), amount, DEST_CHAIN,
            0, 0, payload, user2
        );

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);

        assertEq(vaultPC20.totalLocked(address(pc20Token)), amount);
    }

    function test_ExportPC20_SequentialNonce() public {
        PC20ExportRequest memory req = _defaultReq(10e18);

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);
        assertEq(gateway.nonce(), 1);

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);
        assertEq(gateway.nonce(), 2);
    }

    function test_ExportPC20_DifferentSendersUniqueSubTxId() public {
        PC20ExportRequest memory req = _defaultReq(10e18);

        vm.recordLogs();
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();

        vm.recordLogs();
        vm.prank(user2);
        gateway.exportPC20{value: PC_FEE}(req);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        // subTxId is topics[1] on the last event
        bytes32 id1 = logs1[logs1.length - 1].topics[1];
        bytes32 id2 = logs2[logs2.length - 1].topics[1];
        assertFalse(id1 == id2);
    }

    function test_ExportPC20_ProtocolFeeToVaultPC() public {
        uint256 vaultBal = vaultPCAddr.balance;

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(10e18));

        assertEq(vaultPCAddr.balance, vaultBal + DEFAULT_PROTOCOL_FEE);
    }

    function test_ExportPC20_MaxPCForGas_RefundExcess() public {
        uint256 amount = 10e18;
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);
        uint256 maxPC = gasFee + 0.1 ether;

        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), amount, DEST_CHAIN,
            0, maxPC, bytes(""), user2
        );

        uint256 pcSent = 2 ether;
        uint256 balBefore = user1.balance;

        vm.prank(user1);
        gateway.exportPC20{value: pcSent}(req);

        uint256 totalSpent = balBefore - user1.balance;
        assertLe(totalSpent, DEFAULT_PROTOCOL_FEE + maxPC);
        assertGt(user1.balance, balBefore - pcSent);
    }

    function test_ExportPC20_DeploymentOverhead() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(
            DEST_CHAIN, overhead
        );

        uint256 amount = 10e18;
        uint256 expectedLimit = BASE_GAS_LIMIT + overhead;
        uint256 gasFee = _expectedGasFee(expectedLimit);

        bytes32 expectedId = _expectedSubTxId(
            user1,
            abi.encodePacked(address(0xDEAD)),
            address(pc20Token),
            amount,
            bytes(""),
            DEST_CHAIN,
            0
        );

        vm.expectEmit(true, true, true, true);
        emit PC20ExportInitiated(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            abi.encodePacked(address(0xDEAD)),
            amount,
            address(gasToken),
            gasFee,
            expectedLimit,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            user2,
            DEFAULT_GAS_PRICE
        );

        PC20ExportRequest memory req = _defaultReq(amount);

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    // ================================================================
    // EXPORT PC20 — VALIDATION REVERTS
    // ================================================================

    function test_ExportPC20_RevertsZeroToken() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(0), 10e18, DEST_CHAIN, 0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsZeroAmount() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 0, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsZeroRevertRecipient() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 10e18, DEST_CHAIN,
            0, 0, bytes(""), address(0)
        );
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsEmptyRecipient() public {
        PC20ExportRequest memory req = PC20ExportRequest({
            recipient: bytes(""),
            token: address(pc20Token),
            amount: 10e18,
            destChainNamespace: DEST_CHAIN,
            gasLimit: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: user2
        });
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsEmptyDestChain() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 10e18, "",
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsNonIPC20Token() public {
        MockNonPC20Token badToken = new MockNonPC20Token();
        badToken.mint(user1, 100e18);
        vm.prank(user1);
        badToken.approve(address(gateway), type(uint256).max);

        PC20ExportRequest memory req = _buildExportReq(
            address(badToken), 10e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert();
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsInsufficientMsgValue() public {
        PC20ExportRequest memory req = _defaultReq(10e18);
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.exportPC20{value: 0.001 ether}(req);
    }

    function test_ExportPC20_RevertsUnconfiguredDestChain() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 10e18, "eip155:999",
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert();
        gateway.exportPC20{value: PC_FEE}(req);
    }

    // ================================================================
    // EXPORT PC20 — TOKEN TRANSFER EDGE CASES
    // ================================================================

    function test_ExportPC20_RevertsNoAllowance() public {
        MockPC20Token freshToken = new MockPC20Token("F", "F", 18);
        freshToken.mint(user1, 100e18);
        // NO approval

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(freshToken), DEFAULT_PROTOCOL_FEE
        );

        PC20ExportRequest memory req = _buildExportReq(
            address(freshToken), 10e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert();
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsInsufficientBalance() public {
        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 99_999_999e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert();
        gateway.exportPC20{value: PC_FEE}(req);
    }

    function test_ExportPC20_RevertsFeeOnTransfer() public {
        MockFeeOnTransferPC20 fot = new MockFeeOnTransferPC20(1e18);
        fot.mint(user1, 100e18);
        vm.prank(user1);
        fot.approve(address(gateway), type(uint256).max);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(fot), DEFAULT_PROTOCOL_FEE
        );

        PC20ExportRequest memory req = _buildExportReq(
            address(fot), 10e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        gateway.exportPC20{value: PC_FEE}(req);
    }

    // ================================================================
    // EXPORT PC20 — GAS SWAP EDGE CASES
    // ================================================================

    function test_ExportPC20_MaxPCForGas_TightCap() public {
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);

        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 10e18, DEST_CHAIN,
            0, gasFee, bytes(""), user2
        );

        uint256 pcSent = 2 ether;
        uint256 balBefore = user1.balance;

        vm.prank(user1);
        gateway.exportPC20{value: pcSent}(req);

        // UGPC refunds: pcSent - protocolFee - maxPC
        // Core refunds: maxPC - gasFee = 0
        uint256 expectedSpent = DEFAULT_PROTOCOL_FEE + gasFee;
        assertEq(balBefore - user1.balance, expectedSpent);
    }

    function test_ExportPC20_MaxPCForGas_ExceedsPcForSwap() public {
        uint256 pcSent = 0.5 ether;
        uint256 maxPC = pcSent;

        PC20ExportRequest memory req = _buildExportReq(
            address(pc20Token), 10e18, DEST_CHAIN,
            0, maxPC, bytes(""), user2
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.exportPC20{value: pcSent}(req);
    }

    // ================================================================
    // EXPORT PC20 — PAUSE AND ACCESS CONTROL
    // ================================================================

    function test_ExportPC20_RevertsWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(user1);
        vm.expectRevert();
        gateway.exportPC20{value: PC_FEE}(_defaultReq(10e18));
    }

    function test_ExportPC20_WorksAfterUnpause() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(admin);
        gateway.unpause();

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(10e18));

        assertEq(gateway.nonce(), 1);
    }

    // ================================================================
    // UPDATE VAULT PC20
    // ================================================================

    function test_UpdateVaultPC20_Success() public {
        address newVault = makeAddr("newVault");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit VaultPC20Updated(address(vaultPC20), newVault);
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
    // NONCE AND SUBTXID
    // ================================================================

    function test_SubTxId_Deterministic() public {
        uint256 amount = 10e18;
        bytes memory recipient = abi.encodePacked(address(0xDEAD));

        bytes32 expectedId = _expectedSubTxId(
            user1, recipient, address(pc20Token),
            amount, bytes(""), DEST_CHAIN, 0
        );

        vm.recordLogs();
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 emittedId = logs[logs.length - 1].topics[1];
        assertEq(emittedId, expectedId);
    }

    function test_SharedNonce_WithSendUniversalTxOutbound() public {
        // Export PC20 uses nonce 0
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(10e18));
        assertEq(gateway.nonce(), 1);

        // Deploy and setup a PRC20 for sendUniversalTxOutbound
        MockPRC20 prc20 = new MockPRC20(
            "Push USDC", "pUSDC", 6, DEST_CHAIN,
            MockPRC20.TokenType.ERC20,
            address(universalCore),
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        );
        prc20.mint(user1, 1_000_000e6);
        vm.prank(user1);
        prc20.approve(address(gateway), type(uint256).max);

        // sendUniversalTxOutbound uses nonce 1
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
        gateway.sendUniversalTxOutbound{value: PC_FEE}(outReq);
        assertEq(gateway.nonce(), 2);

        // Another exportPC20 uses nonce 2
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(10e18));
        assertEq(gateway.nonce(), 3);
    }

    // ================================================================
    // EVENT VERIFICATION
    // ================================================================

    function test_PC20ExportInitiated_AllFields() public {
        uint256 amount = 25e18;
        uint256 gasFee = _expectedGasFee(BASE_GAS_LIMIT);
        bytes memory recipient = abi.encodePacked(address(0xDEAD));

        bytes32 expectedId = _expectedSubTxId(
            user1, recipient, address(pc20Token),
            amount, bytes(""), DEST_CHAIN, 0
        );

        vm.expectEmit(true, true, true, true);
        emit PC20ExportInitiated(
            expectedId,
            user1,
            DEST_CHAIN,
            address(pc20Token),
            recipient,
            amount,
            address(gasToken),
            gasFee,
            BASE_GAS_LIMIT,
            bytes(""),
            DEFAULT_PROTOCOL_FEE,
            user2,
            DEFAULT_GAS_PRICE
        );

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(amount));
    }

    // ================================================================
    // ACCOUNTING INTEGRITY
    // ================================================================

    function test_ExportPC20_MultipleExportsSameToken() public {
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(100e18));

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(200e18));

        assertEq(vaultPC20.totalLocked(address(pc20Token)), 300e18);
        assertEq(pc20Token.balanceOf(address(vaultPC20)), 300e18);
    }

    function test_ExportPC20_MultipleTokens() public {
        // Setup chain config for tokenB
        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(pc20TokenB), DEFAULT_PROTOCOL_FEE
        );

        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(_defaultReq(100e18));

        PC20ExportRequest memory reqB = _buildExportReq(
            address(pc20TokenB), 50e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(reqB);

        assertEq(
            vaultPC20.totalLocked(address(pc20Token)), 100e18
        );
        assertEq(
            vaultPC20.totalLocked(address(pc20TokenB)), 50e18
        );
    }

    function test_ExportPC20_ZeroProtocolFee() public {
        // Use tokenB which has no protocol fee set
        // But we need to set up protocolFee for gasToken to pass _fetchPC20ExportGasAndFees
        // Actually the check is gasFee + protocolFee > 0, and gasFee > 0 since gasPrice * baseGasLimit > 0
        // so protocolFee = 0 is valid

        uint256 vaultBal = vaultPCAddr.balance;

        PC20ExportRequest memory req = _buildExportReq(
            address(pc20TokenB), 10e18, DEST_CHAIN,
            0, 0, bytes(""), user2
        );
        vm.prank(user1);
        gateway.exportPC20{value: PC_FEE}(req);

        assertEq(vaultPCAddr.balance, vaultBal);
    }

    // ================================================================
    // GET PC20 EXPORT GAS AND FEES (Mock UniversalCore)
    // ================================================================

    function test_GetPC20ExportGasAndFees_DefaultLimit() public view {
        (
            address gt,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            ,
            uint256 gasLimitUsed,
        ) = universalCore.getPC20ExportGasAndFees(
            DEST_CHAIN, 0, address(pc20Token)
        );

        assertEq(gt, address(gasToken));
        assertEq(gasPrice, DEFAULT_GAS_PRICE);
        assertEq(gasLimitUsed, BASE_GAS_LIMIT);
        assertEq(gasFee, DEFAULT_GAS_PRICE * BASE_GAS_LIMIT);
        assertEq(protocolFee, DEFAULT_PROTOCOL_FEE);
    }

    function test_GetPC20ExportGasAndFees_CustomLimit() public view {
        uint256 customLimit = 300_000;
        (,,,,, uint256 gasLimitUsed,) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN, customLimit, address(pc20Token)
            );
        assertEq(gasLimitUsed, customLimit);
    }

    function test_GetPC20ExportGasAndFees_WithOverhead() public {
        uint256 overhead = 500_000;
        universalCore.setPC20DeploymentGasOverhead(
            DEST_CHAIN, overhead
        );

        (,,,,,uint256 gasLimitUsed, bool isFirst) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN, 0, address(pc20Token)
            );

        assertEq(gasLimitUsed, BASE_GAS_LIMIT + overhead);
        assertTrue(isFirst);
    }

    function test_GetPC20ExportGasAndFees_NoOverhead() public view {
        (,,,,,, bool isFirst) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN, 0, address(pc20Token)
            );
        assertFalse(isFirst);
    }

    function test_GetPC20ExportGasAndFees_NoProtocolFee() public view {
        (,,uint256 protocolFee,,,,) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN, 0, address(pc20TokenB)
            );
        assertEq(protocolFee, 0);
    }

    function test_GetPC20ExportGasAndFees_RevertsNoGasToken() public {
        vm.expectRevert("MockUniversalCore: zero gas token");
        universalCore.getPC20ExportGasAndFees(
            "eip155:999", 0, address(pc20Token)
        );
    }

    function test_GetPC20ExportGasAndFees_RevertsNoGasPrice()
        public
    {
        // Set gasToken but not gasPrice for a new chain
        vm.prank(uem);
        universalCore.setGasTokenPRC20("eip155:56", address(gasToken));
        universalCore.setBaseGasLimitByChain("eip155:56", 100_000);

        vm.expectRevert("MockUniversalCore: zero gas price");
        universalCore.getPC20ExportGasAndFees(
            "eip155:56", 0, address(pc20Token)
        );
    }

    function test_GetPC20ExportGasAndFees_RevertsNoBaseLimit()
        public
    {
        // Set gasToken and gasPrice but not baseGasLimit
        vm.prank(uem);
        universalCore.setGasTokenPRC20(
            "eip155:137", address(gasToken)
        );
        vm.prank(uem);
        universalCore.setGasPrice("eip155:137", DEFAULT_GAS_PRICE);

        vm.expectRevert("MockUniversalCore: zero base gas limit");
        universalCore.getPC20ExportGasAndFees(
            "eip155:137", 0, address(pc20Token)
        );
    }

    function test_GetPC20ExportGasAndFees_RevertsGasLimitBelowBase()
        public
    {
        vm.expectRevert(
            "MockUniversalCore: gas limit below base"
        );
        universalCore.getPC20ExportGasAndFees(
            DEST_CHAIN, BASE_GAS_LIMIT / 2, address(pc20Token)
        );
    }

    function test_GetPC20ExportGasAndFees_MultiChainIndependent()
        public
    {
        // Setup second chain
        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN_B, 5 gwei);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(
            DEST_CHAIN_B, address(gasToken)
        );
        universalCore.setBaseGasLimitByChain(
            DEST_CHAIN_B, 200_000
        );

        (,,,,, uint256 limitA,) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN, 0, address(pc20Token)
            );
        (,uint256 feeB,,,, uint256 limitB,) = universalCore
            .getPC20ExportGasAndFees(
                DEST_CHAIN_B, 0, address(pc20Token)
            );

        assertEq(limitA, BASE_GAS_LIMIT);
        assertEq(limitB, 200_000);
        assertEq(feeB, 5 gwei * 200_000);
    }
}
