// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
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
import { MockPC20Token } from "../mocks/MockPC20Token.sol";

contract OutboundRateLimitTest is Test {
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
    MockPRC20 public prc20Token;
    MockPRC20 public gasToken;
    MockPC20Token public pc20Token;

    // ===== CONSTANTS =====
    uint256 public constant BASE_GAS_LIMIT = 100_000;
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0.01 ether;
    uint256 public constant PC_FEE = 1 ether;
    bytes4 public constant PC_20_SELECTOR = 0x50433230;
    string public constant SOURCE_CHAIN = "1";
    string public constant SOURCE_TOKEN_ADDR = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    string public constant DEST_CHAIN = "eip155:1";

    uint256 public constant EPOCH_DURATION = 6 hours;
    uint256 public constant RATE_LIMIT_BPS = 100; // 1%

    uint256 public constant TOTAL_SUPPLY = 10_000_000e18;

    // ===== SETUP =====
    function setUp() public {
        _createActors();
        _deployMocks();
        _deployVaultPC20();
        _deployGateway();
        _wireGatewayToVaultPC20();
        _setupTokens();
        _configureRateLimits();
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
            "Push Chain Native", "PC", 18, SOURCE_CHAIN,
            MockPRC20.TokenType.PC, address(universalCore), ""
        );

        prc20Token = new MockPRC20(
            "USDC on Push Chain", "USDC", 6, SOURCE_CHAIN,
            MockPRC20.TokenType.ERC20, address(universalCore),
            SOURCE_TOKEN_ADDR
        );

        pc20Token = new MockPC20Token("PushToken", "PTK", 18);

        vm.prank(uem);
        universalCore.setGasPrice(SOURCE_CHAIN, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(SOURCE_CHAIN, address(gasToken));
        universalCore.setBaseGasLimitByChain(SOURCE_CHAIN, BASE_GAS_LIMIT);

        vm.prank(uem);
        universalCore.setGasPrice(DEST_CHAIN, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(DEST_CHAIN, address(gasToken));
        universalCore.setBaseGasLimitByChain(DEST_CHAIN, BASE_GAS_LIMIT);

        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(prc20Token), DEFAULT_PROTOCOL_FEE
        );
        vm.prank(uem);
        universalCore.setProtocolFeeByToken(
            address(pc20Token), DEFAULT_PROTOCOL_FEE
        );
    }

    function _deployVaultPC20() internal {
        VaultPC20 impl = new VaultPC20();
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

        vm.prank(admin);
        gateway.updateVaultPC20(address(vaultPC20));
    }

    function _wireGatewayToVaultPC20() internal {
        vm.prank(admin);
        vaultPC20.updateUniversalGatewayPC(address(gateway));
    }

    function _setupTokens() internal {
        prc20Token.mint(user1, TOTAL_SUPPLY / 2);
        prc20Token.mint(user2, TOTAL_SUPPLY / 2);

        pc20Token.mint(user1, TOTAL_SUPPLY / 2);
        pc20Token.mint(user2, TOTAL_SUPPLY / 2);

        vm.prank(user1);
        prc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user2);
        prc20Token.approve(address(gateway), type(uint256).max);

        vm.prank(user1);
        pc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user2);
        pc20Token.approve(address(gateway), type(uint256).max);
    }

    function _configureRateLimits() internal {
        vm.startPrank(admin);
        gateway.updateOutboundEpochDuration(EPOCH_DURATION);
        gateway.updateOutboundLimitBps(
            address(prc20Token), RATE_LIMIT_BPS
        );
        gateway.updateOutboundLimitBps(
            address(pc20Token), RATE_LIMIT_BPS
        );
        vm.stopPrank();
    }

    // ===== HELPERS =====

    function _prc20Request(
        uint256 amount
    ) internal view returns (UniversalOutboundTxRequest memory) {
        return UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20Token),
            amount: amount,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: bytes(""),
            revertRecipient: user1
        });
    }

    function _pc20Payload() internal pure returns (bytes memory) {
        bytes memory metadata = abi.encode(
            DEST_CHAIN, "PushToken", "PTK", uint8(18)
        );
        return abi.encodePacked(PC_20_SELECTOR, metadata);
    }

    function _pc20Request(
        uint256 amount
    ) internal view returns (UniversalOutboundTxRequest memory) {
        return UniversalOutboundTxRequest({
            recipient: abi.encodePacked(address(0xDEAD)),
            token: address(pc20Token),
            amount: amount,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: _pc20Payload(),
            revertRecipient: user1
        });
    }

    function _threshold() internal pure returns (uint256) {
        return (TOTAL_SUPPLY * RATE_LIMIT_BPS) / 10_000;
    }

    // ================================================================
    //  ADMIN: updateOutboundEpochDuration
    // ================================================================

    function test_UpdateEpochDuration_Success() public {
        uint256 newDuration = 12 hours;

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit IUniversalGatewayPC.OutboundEpochDurationUpdated(
            EPOCH_DURATION, newDuration
        );
        gateway.updateOutboundEpochDuration(newDuration);

        assertEq(gateway.outboundEpochDurationSec(), newDuration);
    }

    function test_UpdateEpochDuration_OnlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.updateOutboundEpochDuration(1 hours);
    }

    function test_UpdateEpochDuration_SetToZeroDisables() public {
        vm.prank(admin);
        gateway.updateOutboundEpochDuration(0);
        assertEq(gateway.outboundEpochDurationSec(), 0);
    }

    // ================================================================
    //  ADMIN: updateOutboundLimitBps
    // ================================================================

    function test_UpdateLimitBps_Success() public {
        uint256 newBps = 500; // 5%

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit IUniversalGatewayPC.OutboundLimitBpsUpdated(
            address(prc20Token), newBps
        );
        gateway.updateOutboundLimitBps(address(prc20Token), newBps);

        assertEq(
            gateway.outboundLimitBps(address(prc20Token)), newBps
        );
    }

    function test_UpdateLimitBps_OnlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.updateOutboundLimitBps(address(prc20Token), 100);
    }

    function test_UpdateLimitBps_RevertAbove10000() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidBps.selector);
        gateway.updateOutboundLimitBps(address(prc20Token), 10_001);
    }

    function test_UpdateLimitBps_Max10000Allowed() public {
        vm.prank(admin);
        gateway.updateOutboundLimitBps(address(prc20Token), 10_000);
        assertEq(
            gateway.outboundLimitBps(address(prc20Token)), 10_000
        );
    }

    function test_UpdateLimitBps_ZeroRemovesLimit() public {
        vm.prank(admin);
        gateway.updateOutboundLimitBps(address(prc20Token), 0);

        assertEq(gateway.outboundLimitBps(address(prc20Token)), 0);
    }

    // ================================================================
    //  PRC20: Rate limit enforcement
    // ================================================================

    function test_PRC20_UnderLimitSucceeds() public {
        uint256 amount = _threshold() / 2;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(uint256(used), amount);
    }

    function test_PRC20_ExactLimitSucceeds() public {
        uint256 amount = _threshold();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(uint256(used), amount);
    }

    function test_PRC20_OverLimitReverts() public {
        uint256 amount = _threshold() + 1;

        vm.prank(user1);
        vm.expectRevert(Errors.OutboundRateLimitExceeded.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );
    }

    function test_PRC20_CumulativeOverLimitReverts() public {
        uint256 quarter = _threshold() / 4;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(quarter)
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(quarter)
        );

        uint256 currentSupply = prc20Token.totalSupply();
        uint256 currentThreshold =
            (currentSupply * RATE_LIMIT_BPS) / 10_000;
        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        uint256 remaining = currentThreshold - uint256(used);

        vm.prank(user1);
        vm.expectRevert(Errors.OutboundRateLimitExceeded.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(remaining + 1)
        );
    }

    function test_PRC20_MultipleUsersShareEpoch() public {
        uint256 quarter = _threshold() / 4;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(quarter)
        );

        vm.prank(user2);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(quarter)
        );

        uint256 currentSupply = prc20Token.totalSupply();
        uint256 currentThreshold =
            (currentSupply * RATE_LIMIT_BPS) / 10_000;
        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        uint256 remaining = currentThreshold - uint256(used);

        vm.prank(user2);
        vm.expectRevert(Errors.OutboundRateLimitExceeded.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(remaining + 1)
        );
    }

    function test_PRC20_EpochResetAllowsNewTx() public {
        uint256 amount = _threshold();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );

        vm.warp(block.timestamp + EPOCH_DURATION);

        uint256 postBurnSupply = prc20Token.totalSupply();
        uint256 newThreshold =
            (postBurnSupply * RATE_LIMIT_BPS) / 10_000;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(newThreshold)
        );

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(uint256(used), newThreshold);
    }

    function test_PRC20_GasAndPayloadAmountZeroSkipsRateLimit()
        public
    {
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: bytes(""),
            token: address(prc20Token),
            amount: 0,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: abi.encodeWithSignature("foo()"),
            revertRecipient: user1
        });

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(req);

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(uint256(used), 0);
    }

    // ================================================================
    //  PC20: Rate limit enforcement
    // ================================================================

    function test_PC20_UnderLimitSucceeds() public {
        uint256 amount = _threshold() / 2;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _pc20Request(amount)
        );

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(pc20Token)
        );
        assertEq(uint256(used), amount);
    }

    function test_PC20_OverLimitReverts() public {
        uint256 amount = _threshold() + 1;

        vm.prank(user1);
        vm.expectRevert(Errors.OutboundRateLimitExceeded.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _pc20Request(amount)
        );
    }

    function test_PC20_EpochResetAllowsNewTx() public {
        uint256 amount = _threshold();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _pc20Request(amount)
        );

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _pc20Request(amount)
        );
    }

    // ================================================================
    //  Token independence
    // ================================================================

    function test_DifferentTokensTrackIndependently() public {
        uint256 amount = _threshold();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _pc20Request(amount)
        );

        (, uint192 prc20Used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        (, uint192 pc20Used) = gateway.getOutboundEpochUsage(
            address(pc20Token)
        );

        assertEq(uint256(prc20Used), amount);
        assertEq(uint256(pc20Used), amount);
    }

    // ================================================================
    //  No limit configured (bps == 0)
    // ================================================================

    function test_NoLimitConfigured_AllowsAnyAmount() public {
        vm.prank(admin);
        gateway.updateOutboundLimitBps(address(prc20Token), 0);

        uint256 largeAmount = TOTAL_SUPPLY / 2;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(largeAmount)
        );

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(uint256(used), 0);
    }

    // ================================================================
    //  Epoch duration == 0 with bps > 0 reverts
    // ================================================================

    function test_ZeroEpochDuration_WithBps_Reverts() public {
        vm.prank(admin);
        gateway.updateOutboundEpochDuration(0);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(1e18)
        );
    }

    // ================================================================
    //  Supply-proportional: threshold scales with totalSupply
    // ================================================================

    function test_ThresholdScalesWithSupply() public {
        uint256 currentThreshold = _threshold();

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(currentThreshold)
        );

        vm.warp(block.timestamp + EPOCH_DURATION);

        prc20Token.mint(user1, TOTAL_SUPPLY);

        uint256 newSupply = prc20Token.totalSupply();
        uint256 newThreshold = (newSupply * RATE_LIMIT_BPS) / 10_000;

        assertGt(newThreshold, currentThreshold);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(newThreshold)
        );
    }

    // ================================================================
    //  PRC20 supply shrinks after burn (self-tightening)
    // ================================================================

    function test_PRC20_SupplyShrinksTightensLimit() public {
        uint256 firstAmount = _threshold() / 2;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(firstAmount)
        );

        uint256 newSupply = prc20Token.totalSupply();
        uint256 newThreshold = (newSupply * RATE_LIMIT_BPS) / 10_000;

        (, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        uint256 remaining = newThreshold > uint256(used)
            ? newThreshold - uint256(used)
            : 0;

        if (remaining > 0) {
            vm.prank(user1);
            gateway.sendUniversalTxOutbound{value: PC_FEE}(
                _prc20Request(remaining)
            );
        }

        vm.prank(user1);
        vm.expectRevert(Errors.OutboundRateLimitExceeded.selector);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(1)
        );
    }

    // ================================================================
    //  getOutboundEpochUsage view
    // ================================================================

    function test_GetOutboundEpochUsage_InitiallyZero() public view {
        (uint64 epoch, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        assertEq(epoch, 0);
        assertEq(used, 0);
    }

    function test_GetOutboundEpochUsage_UpdatesAfterTx() public {
        uint256 amount = 1000e18;

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: PC_FEE}(
            _prc20Request(amount)
        );

        (uint64 epoch, uint192 used) = gateway.getOutboundEpochUsage(
            address(prc20Token)
        );
        uint64 expectedEpoch = uint64(
            block.timestamp / EPOCH_DURATION
        );
        assertEq(epoch, expectedEpoch);
        assertEq(uint256(used), amount);
    }
}
