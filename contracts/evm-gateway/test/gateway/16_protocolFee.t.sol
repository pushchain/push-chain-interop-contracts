// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, PRC_20_SELECTOR } from "../../src/libraries/Types.sol";
import { UniversalTxRequest, UniversalPayload } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";

/**
 * @title ProtocolFeeTest
 * @notice Tests for inboundFee mechanics on UniversalGateway.
 * @dev Covers: admin management, fee enforcement across all TX_TYPEs,
 *      accumulator tracking, CEA path, and ERC20 gas token path.
 */
contract ProtocolFeeTest is BaseTest {
    // =========================
    //           EVENTS
    // =========================
    event UniversalTx(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes payload,
        address revertRecipient,
        TX_TYPE txType,
        bytes signatureData,
        bool fromCEA
    );

    event ProtocolFeeUpdated(uint256 newFee);

    // =========================
    //        TEST STATE
    // =========================
    UniversalGateway public gw;
    MockCEAFactory public ceaFactory;
    MockCEA public cea;
    address public mappedUEA;

    uint256 public constant PROTOCOL_FEE_WEI = 0.001 ether;
    // ETH price = $2000; $1 cap → 0.0005 ether; $10 cap → 0.005 ether; use 0.003 ether ($6) for GAS tests
    uint256 public constant GAS_AMOUNT = 0.003 ether;
    uint256 public constant FUNDS_AMOUNT = 5 ether;

    // =========================
    //          SETUP
    // =========================
    function setUp() public override {
        super.setUp();
        _deployFeeGateway();

        // Wire oracle
        vm.prank(admin);
        gw.setEthUsdFeed(address(ethUsdFeedMock));

        // Support native + tokenA
        address[] memory tokens = new address[](2);
        uint256[] memory thresholds = new uint256[](2);
        tokens[0] = address(0);
        tokens[1] = address(tokenA);
        thresholds[0] = 1_000_000 ether;
        thresholds[1] = 1_000_000 ether;
        vm.prank(admin);
        gw.setTokenLimitThresholds(tokens, thresholds);

        // Approve tokenA for users
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            tokenA.approve(address(gw), type(uint256).max);
        }

        // CEA setup
        ceaFactory = new MockCEAFactory();
        ceaFactory.setVault(address(this));
        vm.prank(admin);
        gw.updateCEAFactory(address(ceaFactory));

        mappedUEA = address(0xBEEF);
        address ceaAddr = ceaFactory.deployCEA(mappedUEA);
        cea = MockCEA(payable(ceaAddr));

        vm.deal(address(cea), 100 ether);
        tokenA.mint(address(cea), 1_000_000 ether);
        vm.prank(address(cea));
        tokenA.approve(address(gw), type(uint256).max);
    }

    function _deployFeeGateway() internal {
        UniversalGateway impl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            address(weth),
            address(0),
            address(0),
            address(0)
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), address(proxyAdmin), initData);
        gw = UniversalGateway(payable(address(proxy)));
        vm.startPrank(admin);
        gw.grantRole(gw.ROLE_MANAGER_ROLE(), admin);
        gw.grantRole(gw.UG_ADMIN_ROLE(), admin);
        gw.grantRole(gw.OPERATOR_ROLE(), admin);
        vm.stopPrank();
        _configureGatewayPostDeploy(gw, admin, address(this));
        vm.label(address(gw), "GW_FeeTest");
    }

    function _buildReq(address token, uint256 amount, bytes memory payload)
        internal
        pure
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: address(0),
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    function _buildCEAReq(address token, uint256 amount, bytes memory payload)
        internal
        view
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: mappedUEA,
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    function _defaultPayload() internal view returns (bytes memory) {
        return abi.encode(buildDefaultPayload());
    }

    // =========================
    //      GROUP 1: ADMIN
    // =========================

    /// @notice Admin can set protocol fee and event is emitted
    function testSetProtocolFee_Admin() public {
        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(PROTOCOL_FEE_WEI);

        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        assertEq(gw.INBOUND_FEE(), PROTOCOL_FEE_WEI);
    }

    /// @notice Non-admin cannot set protocol fee
    function testSetProtocolFee_NonAdmin_Reverts() public {
        vm.expectRevert();
        vm.prank(user1);
        gw.setInboundFee(PROTOCOL_FEE_WEI);
    }

    /// @notice Setting fee to 0 disables it (accumulator unaffected)
    function testSetProtocolFee_Zero_Disables() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        vm.prank(admin);
        gw.setInboundFee(0);

        assertEq(gw.INBOUND_FEE(), 0);
        // With fee=0, GAS tx with any native value succeeds without fee deduction
        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: GAS_AMOUNT }(req);
        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    // =========================
    //      GROUP 2: GAS TX_TYPE
    // =========================

    /// @notice GAS tx: fee deducted, TSS receives deposit + fee, accumulator increments
    function testGAS_WithFee_TSSReceivesFee() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 totalSend = GAS_AMOUNT + PROTOCOL_FEE_WEI;
        uint256 tssBalBefore = tss.balance;

        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: totalSend }(req);

        // TSS receives both gasAmount and fee
        assertEq(tss.balance - tssBalBefore, totalSend);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    /// @notice GAS tx: msg.value < inboundFee reverts with InsufficientProtocolFee
    function testGAS_InsufficientFee_Reverts() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI - 1 }(req);
    }

    /// @notice GAS tx event emits gasAmount (post-fee) not total msg.value
    function testGAS_EventAmountIsPostFee() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 totalSend = GAS_AMOUNT + PROTOCOL_FEE_WEI;

        vm.expectEmit(true, true, false, true);
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            GAS_AMOUNT,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            address(0x456),
            TX_TYPE.GAS,
            bytes(""),
            false
        );

        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: totalSend }(req);
    }

    // =========================
    //      GROUP 3: GAS_AND_PAYLOAD
    // =========================

    /// @notice Payload-only GAS_AND_PAYLOAD: user must supply exactly inboundFee
    function testGAS_AND_PAYLOAD_PayloadOnly_RequiresFee() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        UniversalTxRequest memory req = _buildReq(address(0), 0, _defaultPayload());

        // Sending exactly inboundFee: should succeed, gasAmount=0 after fee extraction
        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI }(req);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    /// @notice Payload-only with insufficient native reverts
    function testGAS_AND_PAYLOAD_PayloadOnly_InsufficientFee_Reverts() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        UniversalTxRequest memory req = _buildReq(address(0), 0, _defaultPayload());

        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI - 1 }(req);
    }

    /// @notice Payload-only: event emits amount=0 (nothing bridged, only fee collected)
    function testGAS_AND_PAYLOAD_PayloadOnly_EventAmountIsZero() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        bytes memory payload = _defaultPayload();

        vm.expectEmit(true, true, false, true);
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            0,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            false
        );

        UniversalTxRequest memory req = _buildReq(address(0), 0, payload);
        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI }(req);
    }

    // =========================
    //      GROUP 4: FUNDS (native)
    // =========================

    /// @notice FUNDS native: user sends req.amount + fee, event emits req.amount (bridge amount unchanged)
    function testFUNDS_Native_AmountUnchanged() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 tssBalBefore = tss.balance;

        vm.expectEmit(true, true, false, true);
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            FUNDS_AMOUNT,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            address(0x456),
            TX_TYPE.FUNDS,
            bytes(""),
            false
        );

        UniversalTxRequest memory req = _buildReq(address(0), FUNDS_AMOUNT, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: FUNDS_AMOUNT + PROTOCOL_FEE_WEI }(req);

        // TSS receives req.amount (bridged) + fee (protocol)
        assertEq(tss.balance - tssBalBefore, FUNDS_AMOUNT + PROTOCOL_FEE_WEI);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    /// @notice FUNDS native: sending msg.value != req.amount + fee reverts with InvalidAmount
    /// @dev req.amount is the bridge amount; msg.value must equal req.amount + inboundFee.
    ///      Sending msg.value = req.amount (omitting fee) passes _collectProtocolFee but fails
    ///      the Case 1.1 equality check (adjustedNative = req.amount - fee != req.amount).
    function testFUNDS_Native_WrongMsgValue_Reverts() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        // Send req.amount only (forgot the fee): passes fee guard but fails amount check
        UniversalTxRequest memory req = _buildReq(address(0), FUNDS_AMOUNT, bytes(""));
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gw.sendUniversalTx{ value: FUNDS_AMOUNT }(req);
    }

    /// @notice FUNDS native: exact mismatch (msg.value - fee != req.amount) reverts with InvalidAmount
    function testFUNDS_Native_AmountMismatch_Reverts() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        // req.amount != msg.value - fee
        UniversalTxRequest memory req = _buildReq(address(0), FUNDS_AMOUNT, bytes(""));
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gw.sendUniversalTx{ value: FUNDS_AMOUNT + PROTOCOL_FEE_WEI + 1 }(req);
    }

    // =========================
    //      GROUP 5: FUNDS (ERC20)
    // =========================

    /// @notice ERC20 FUNDS: requires msg.value == inboundFee alongside ERC20 deposit
    function testFUNDS_ERC20_RequiresNativeFee() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 tssBalBefore = tss.balance;
        uint256 erc20Amount = 100 ether;

        UniversalTxRequest memory req = _buildReq(address(tokenA), erc20Amount, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI }(req);

        // TSS receives the fee in native
        assertEq(tss.balance - tssBalBefore, PROTOCOL_FEE_WEI);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    /// @notice ERC20 FUNDS: msg.value > inboundFee routes excess as gas top-up
    function testFUNDS_ERC20_ExcessNative_RoutesAsGas() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 erc20Amount = 100 ether;
        uint256 extraNative = 0.003 ether; // ~$6 at $2000/ETH, within $1-$10 USD cap
        UniversalTxRequest memory req = _buildReq(address(tokenA), erc20Amount, bytes(""));

        uint256 tssBalBefore = tss.balance;

        vm.prank(user1);
        gw.sendUniversalTx{ value: PROTOCOL_FEE_WEI + extraNative }(req);

        // TSS receives: inboundFee (from fee collection) + extraNative (gas top-up)
        assertEq(tss.balance - tssBalBefore, PROTOCOL_FEE_WEI + extraNative);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    /// @notice ERC20 FUNDS: msg.value = 0 reverts when fee > 0
    function testFUNDS_ERC20_ZeroNative_WithFeeEnabled_Reverts() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 erc20Amount = 100 ether;
        UniversalTxRequest memory req = _buildReq(address(tokenA), erc20Amount, bytes(""));

        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        vm.prank(user1);
        gw.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 6: ACCUMULATOR
    // =========================

    /// @notice totalProtocolFeesCollected accumulates across multiple transactions
    function testProtocolFeeAccumulator_MultipleTransactions() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 txCount = 3;

        // 3x GAS transactions
        for (uint256 i = 0; i < txCount; i++) {
            UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
            vm.prank(user1);
            gw.sendUniversalTx{ value: GAS_AMOUNT + PROTOCOL_FEE_WEI }(req);
        }

        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI * txCount);
    }

    /// @notice Accumulator is zero before any fees are collected
    function testProtocolFeeAccumulator_StartsAtZero() public {
        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    // =========================
    //      GROUP 7: CEA PATH (fee skipped — already paid on Push Chain)
    // =========================

    /// @notice CEA GAS tx: no fee deducted, full msg.value forwarded
    function testCEAPath_NoFee_GAS() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 tssBalBefore = tss.balance;

        UniversalTxRequest memory req = _buildCEAReq(address(0), 0, bytes(""));
        vm.prank(address(cea));
        gw.sendUniversalTxFromCEA{ value: GAS_AMOUNT }(req);

        assertEq(tss.balance - tssBalBefore, GAS_AMOUNT);
        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    /// @notice CEA native FUNDS tx: no fee deducted, full amount bridged
    function testCEAPath_NoFee_FUNDS_Native() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 tssBalBefore = tss.balance;

        UniversalTxRequest memory req = _buildCEAReq(address(0), FUNDS_AMOUNT, bytes(""));
        vm.prank(address(cea));
        gw.sendUniversalTxFromCEA{ value: FUNDS_AMOUNT }(req);

        assertEq(tss.balance - tssBalBefore, FUNDS_AMOUNT);
        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    /// @notice CEA ERC20 FUNDS tx: no native fee required
    function testCEAPath_NoFee_FUNDS_ERC20() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        uint256 erc20Amount = 100 ether;
        UniversalTxRequest memory req = _buildCEAReq(address(tokenA), erc20Amount, bytes(""));

        vm.prank(address(cea));
        gw.sendUniversalTxFromCEA{ value: 0 }(req);

        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    /// @notice Normal tx increments accumulator; CEA tx leaves it unchanged
    function testCEAPath_NoFee_AccumulatorUnchanged() public {
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        // Normal tx: accumulator increments
        UniversalTxRequest memory normalReq = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: GAS_AMOUNT + PROTOCOL_FEE_WEI }(normalReq);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);

        // CEA tx: accumulator unchanged
        UniversalTxRequest memory ceaReq = _buildCEAReq(address(0), 0, bytes(""));
        vm.prank(address(cea));
        gw.sendUniversalTxFromCEA{ value: GAS_AMOUNT }(ceaReq);
        assertEq(gw.totalProtocolFeesCollected(), PROTOCOL_FEE_WEI);
    }

    // =========================
    //      GROUP 8: FEE DISABLED
    // =========================

    /// @notice When inboundFee=0, GAS tx with any native value works (original behavior)
    function testFeeDisabled_GAS_Works() public {
        // Fee is 0 by default
        assertEq(gw.INBOUND_FEE(), 0);

        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: GAS_AMOUNT }(req);

        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    /// @notice When inboundFee=0, ERC20 FUNDS still requires msg.value == 0
    function testFeeDisabled_ERC20_FUNDS_ZeroMsgValue_Works() public {
        uint256 erc20Amount = 100 ether;
        UniversalTxRequest memory req = _buildReq(address(tokenA), erc20Amount, bytes(""));
        vm.prank(user1);
        gw.sendUniversalTx{ value: 0 }(req);

        assertEq(gw.totalProtocolFeesCollected(), 0);
    }

    // =========================
    //  GROUP 9: TSS TRANSFER FAILURE
    // =========================

    /// @notice When TSS is a contract that rejects ETH, _collectProtocolFee reverts
    function testFeeForward_TSSRejectsETH_Reverts() public {
        // Set fee on gw
        vm.prank(admin);
        gw.setInboundFee(PROTOCOL_FEE_WEI);

        // Replace TSS with a contract that rejects ETH
        ProtocolFeeEthRejecter rejecter = new ProtocolFeeEthRejecter();
        vm.prank(admin);
        gw.setTSS(address(rejecter));

        UniversalTxRequest memory req = _buildReq(address(0), 0, bytes(""));
        vm.prank(user1);
        vm.expectRevert(Errors.DepositFailed.selector);
        gw.sendUniversalTx{ value: GAS_AMOUNT + PROTOCOL_FEE_WEI }(req);
    }
}

/// @dev Contract that rejects all ETH transfers
contract ProtocolFeeEthRejecter {
    receive() external payable {
        revert("ETH rejected");
    }
}
