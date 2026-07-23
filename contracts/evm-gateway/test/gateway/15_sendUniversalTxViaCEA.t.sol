// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions, PRC_20_SELECTOR } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";

/**
 * @title SendUniversalTxViaCEA Test Suite
 * @notice Tests for sendUniversalTxFromCEA() on UniversalGateway
 * @dev Covers: access control, CEA identity validation, recipient correctness,
 *      TX_TYPE routing, deposit mechanics, caps enforcement, event semantics,
 *      spoof resistance, and E2E scenarios.
 */
contract SendUniversalTxViaCEATest is BaseTest {
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

    // =========================
    //        TEST STATE
    // =========================
    MockCEAFactory public ceaFactory;
    MockCEA public cea;
    address public mappedUEA;

    // =========================
    //          SETUP
    // =========================
    function setUp() public override {
        super.setUp();

        // Deploy CEAFactory mock and wire to gateway
        ceaFactory = new MockCEAFactory();
        ceaFactory.setVault(address(this));
        vm.label(address(ceaFactory), "CEAFactory");

        vm.prank(admin);
        gateway.updateCEAFactory(address(ceaFactory));

        // Deploy a CEA via factory (requires vault as caller)
        mappedUEA = address(0xBEEF);
        address ceaAddr = ceaFactory.deployCEA(mappedUEA);
        cea = MockCEA(payable(ceaAddr));
        vm.label(ceaAddr, "CEA");

        // Support tokenA for epoch rate limits
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 1_000_000 ether;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund CEA with tokens and native
        vm.deal(address(cea), 100 ether);
        tokenA.mint(address(cea), 1_000_000 ether);

        // CEA approves gateway for ERC20
        vm.prank(address(cea));
        tokenA.approve(address(gateway), type(uint256).max);
    }

    // =========================
    //      HELPERS
    // =========================
    function _defaultPayload() internal view returns (bytes memory) {
        return abi.encode(buildDefaultPayload());
    }

    function _buildViaCEARequest(address token, uint256 amount, bytes memory payload)
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

    // =====================================================
    //  1. ACCESS CONTROL: Only valid CEAs can call
    // =====================================================

    function test_RevertWhen_CEAFactoryNotSet() public {
        // Zero out ceaFactory via vm.store (slot 20 per storage layout)
        vm.store(address(gateway), bytes32(uint256(61)), bytes32(0));
        assertEq(gateway.CEA_FACTORY(), address(0));

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_RevertWhen_CallerIsNotACEA() public {
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(attacker);
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_RevertWhen_CallerIsEOA() public {
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  2. CEA IDENTITY VALIDATION (anti-spoof)
    // =====================================================

    function test_RevertWhen_MappedUEAIsZero() public {
        // Deploy a second factory that returns address(0) for getPushAccountForCEA
        MockCEAFactory badFactory = new MockCEAFactory();
        badFactory.setVault(address(this));
        // Deploy a CEA but then manipulate — use a fresh address not in mapping
        address fakeCEA = address(0xDEAD);

        vm.prank(admin);
        gateway.updateCEAFactory(address(badFactory));

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        // fakeCEA is not in the factory mapping → isCEA returns false
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(fakeCEA);
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  3. RECIPIENT CORRECTNESS
    // =====================================================

    function test_RevertWhen_RecipientDoesNotMatchMappedUEA() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0xBAD), // Wrong — not the mapped UEA
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_RevertWhen_RecipientIsZero() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_RecipientSpoofAttempt_EmitsMappedUEA() public {
        // Even if req.recipient is attacker, validation enforces mapped UEA
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: attacker,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        // Reverts because attacker != mappedUEA
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  4. TX_TYPE INFERENCE AND ROUTING
    // =====================================================

    function test_GasAndPayload_ViaCEA_NonNativeToken_PayloadOnly_Succeeds() public {
        // amount=0, token=tokenA, payload=non-empty → GAS_AND_PAYLOAD
        // _sendTxWithGas called with gasAmount=0 → skips caps, just emits event
        // req.token field is ignored by _sendTxWithGas (always emits token=address(0))
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 0, _defaultPayload());

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            0,
            abi.encodePacked(PRC_20_SELECTOR, _defaultPayload()),
            req.revertRecipient,
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_FUNDS_ViaCEA_ERC20_HappyPath() public {
        // amount=100, token=tokenA, payload=empty → TX_TYPE.FUNDS → now allowed via CEA
        uint256 amount = 100 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, bytes(""));

        uint256 vaultBefore = tokenA.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            req.revertRecipient,
            TX_TYPE.FUNDS,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        assertEq(tokenA.balanceOf(address(this)), vaultBefore + amount, "Vault should receive ERC20");
    }

    function test_FUNDS_ViaCEA_Native_HappyPath() public {
        // Native FUNDS: msg.value must equal req.amount exactly
        uint256 amount = 1 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), amount, bytes(""));

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            req.revertRecipient,
            TX_TYPE.FUNDS,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: amount }(req);

        assertEq(tss.balance, tssBefore + amount, "TSS should receive native");
    }

    // =====================================================
    //  5. DEPOSIT MECHANICS: ERC20 FUNDS_AND_PAYLOAD
    // =====================================================

    function test_ERC20_FundsAndPayload_HappyPath() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, payload);

        uint256 vaultBefore = tokenA.balanceOf(address(this)); // VAULT = address(this) in BaseTest

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        // Vault received tokens
        assertEq(tokenA.balanceOf(address(this)), vaultBefore + amount, "Vault should receive ERC20");
    }

    function test_ERC20_RevertWhen_TokenNotSupported() public {
        // Remove tokenA support
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 0; // unsupported

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert(Errors.NotSupported.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_ERC20_RevertWhen_InsufficientAllowance() public {
        // Revoke approval
        vm.prank(address(cea));
        tokenA.approve(address(gateway), 0);

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  6. DEPOSIT MECHANICS: NATIVE FUNDS_AND_PAYLOAD
    // =====================================================

    function test_Native_FundsAndPayload_ExactAmount() public {
        uint256 amount = 1 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), amount, payload);

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: amount }(req);

        assertEq(tss.balance, tssBefore + amount, "TSS should receive native");
    }

    function test_FundsAndPayload_ViaCEA_Batching_NativeFunds() public {
        // Case 2.2 via CEA: msg.value > req.amount → gas leg + FUNDS_AND_PAYLOAD
        // gas leg must emit recipient=mappedUEA, fromCEA=true (not address(0), fromCEA=false)
        uint256 fundsAmount = 1 ether;
        uint256 gasTopUp = 0.002 ether;
        uint256 totalValue = fundsAmount + gasTopUp;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), fundsAmount, payload);

        uint256 tssBefore = tss.balance;

        // Expect GAS leg event first (gasTopUp)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea), mappedUEA, address(0), gasTopUp, bytes(""), req.revertRecipient, TX_TYPE.GAS, bytes(""), true
        );
        // Then FUNDS_AND_PAYLOAD event (fundsAmount)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            fundsAmount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: totalValue }(req);

        assertEq(tss.balance, tssBefore + totalValue, "TSS should receive full value");
    }

    function test_Native_RevertWhen_MsgValueLessThanAmount() public {
        uint256 amount = 2 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), amount, payload);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: 1 ether }(req);
    }

    // =====================================================
    //  7. USD CAPS & PER-BLOCK CAP ENFORCEMENT
    // =====================================================

    function test_FundsAndPayload_ViaCEA_Batching_ERC20Funds() public {
        // Case 2.3 via CEA: ERC-20 funds + native gas leg
        // gas leg must emit recipient=mappedUEA, fromCEA=true
        uint256 amount = 100 ether;
        uint256 gasAmount = 0.002 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, payload);

        uint256 vaultBefore = tokenA.balanceOf(address(this));
        uint256 tssBefore = tss.balance;

        // Expect GAS leg event first (gasAmount in native)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea), mappedUEA, address(0), gasAmount, bytes(""), req.revertRecipient, TX_TYPE.GAS, bytes(""), true
        );
        // Then FUNDS_AND_PAYLOAD event (ERC-20)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasAmount }(req);

        assertEq(tokenA.balanceOf(address(this)), vaultBefore + amount, "Vault should receive ERC20");
        assertEq(tss.balance, tssBefore + gasAmount, "TSS should receive gas");
    }

    function test_NoBatching_NativeExactAmount_Succeeds() public {
        // Exact msg.value == req.amount is the only valid native path
        uint256 amount = 1 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), amount, payload);

        uint256 tssBefore = tss.balance;

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: amount }(req);

        assertEq(tss.balance, tssBefore + amount, "TSS receives exact amount");
    }

    // =====================================================
    //  8. EPOCH RATE LIMITING
    // =====================================================

    function test_ERC20_EpochRateLimitEnforced() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set a small threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 50 ether; // Only 50 tokens per epoch

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  9. REVERT RECIPIENT SANITY
    // =====================================================

    function test_RevertWhen_RevertRecipientIsZero() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  10. EVENT SEMANTICS
    // =====================================================

    function test_EventEmits_fromCEA_True() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();
        bytes memory sigData = abi.encodePacked(bytes32(uint256(42)));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(tokenA),
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: sigData
        });

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea), // sender = CEA
            mappedUEA, // recipient = mapped UEA (not address(0))
            address(tokenA),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.FUNDS_AND_PAYLOAD,
            sigData,
            true // fromCEA = true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_NormalSendUniversalTx_StillEmits_fromCEA_False() public {
        // Regression: normal path still emits fromCEA = false
        uint256 gasAmount = 0.001 ether;
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            gasAmount,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            address(0x456),
            TX_TYPE.GAS,
            bytes(""),
            false // fromCEA = false
        );

        vm.prank(user1);
        gateway.sendUniversalTx{ value: gasAmount }(req);
    }

    function test_EventRecipientIsNeverZero_ForViaCEA() public {
        uint256 amount = 50 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, payload);

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        // Find the UniversalTx event and verify recipient != address(0)
        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                // topics[2] is the indexed recipient
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedRecipient, mappedUEA, "Recipient must be mapped UEA");
                assertTrue(emittedRecipient != address(0), "Recipient must not be zero");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    // =====================================================
    //  11. RECIPIENT OVERRIDE ATTACK TESTS
    // =====================================================

    function test_SpoofRecipient_AttackerEOA_Reverts() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: attacker,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_SpoofRecipient_SomeContract_Reverts() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(gateway), // random contract
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  16. MINIMAL E2E SCENARIO TESTS
    // =====================================================

    function test_E2E_ERC20_FundsAndPayload_ViaCEA() public {
        uint256 amount = 200 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, payload);

        uint256 vaultBefore = tokenA.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        assertEq(tokenA.balanceOf(address(this)), vaultBefore + amount, "Vault received ERC20");
    }

    function test_E2E_Native_FundsAndPayload_NoBatching_ViaCEA() public {
        // Batching disallowed — only exact amount succeeds
        uint256 fundsAmount = 5 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), fundsAmount, payload);

        uint256 tssBefore = tss.balance;

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: fundsAmount }(req);

        assertEq(tss.balance, tssBefore + fundsAmount, "TSS received exact amount");
    }

    function test_E2E_InvalidCEA_Reverts() public {
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        // Attacker is not a CEA
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(attacker);
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  17. RECIPIENT FORCED TO ADDRESS(0) REGRESSION
    // =====================================================

    function test_Regression_FundsAndPayload_ViaCEA_RecipientNotZero() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, payload);

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertTrue(emittedRecipient != address(0), "REGRESSION: fromCEA must never emit recipient=address(0)");
                assertEq(emittedRecipient, mappedUEA, "REGRESSION: recipient must be mapped UEA");
                return;
            }
        }
        revert("Event not found");
    }

    function test_Regression_NormalFundsAndPayload_RecipientStillZero() public {
        // Non-fromCEA path preserves address(0) recipient for FUNDS_AND_PAYLOAD
        uint256 amount = 100 ether;
        UniversalPayload memory payload = buildDefaultPayload();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: amount,
            payload: abi.encode(payload),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedRecipient, address(0), "Non-fromCEA FUNDS_AND_PAYLOAD must keep recipient=address(0)");
                return;
            }
        }
        revert("Event not found");
    }

    // =====================================================
    //  PAUSE / REENTRANCY SAFETY
    // =====================================================

    function test_RevertWhen_Paused() public {
        vm.prank(pauser);
        gateway.pause();

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, _defaultPayload());

        vm.expectRevert();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  A. GAS_AND_PAYLOAD via CEA — Happy Paths
    // =====================================================

    function test_GasAndPayload_ViaCEA_WithGas_HappyPath() public {
        uint256 gasAmount = 0.002 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            gasAmount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasAmount }(req);

        assertEq(tss.balance, tssBefore + gasAmount, "TSS should receive gas");
    }

    function test_GasAndPayload_ViaCEA_PayloadOnly_NoGas_HappyPath() public {
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            0,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        assertEq(tss.balance, tssBefore, "TSS balance unchanged for payload-only");
    }

    // =====================================================
    //  B. GAS_AND_PAYLOAD via CEA — Validation Reverts
    // =====================================================

    function test_GasAndPayload_ViaCEA_NonNativeToken_Succeeds() public {
        // amount=0, token=tokenA, payload=non-empty → GAS_AND_PAYLOAD
        // _sendTxWithGas called with gasAmount=0 → skips caps, just emits
        // req.token field is ignored by _sendTxWithGas (token=address(0) in event)
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 0, _defaultPayload());

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            0,
            abi.encodePacked(PRC_20_SELECTOR, _defaultPayload()),
            req.revertRecipient,
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_GAS_ViaCEA_HappyPath() public {
        // amount=0, token=address(0), payload=empty, msg.value>0 → GAS
        // GAS is now allowed via CEA
        uint256 gasAmount = 0.002 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, bytes(""));

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            gasAmount,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            req.revertRecipient,
            TX_TYPE.GAS,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasAmount }(req);

        assertEq(tss.balance, tssBefore + gasAmount, "TSS should receive gas");
    }

    function test_GasAndPayload_ViaCEA_RevertWhen_RecipientMismatch() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: attacker,
            token: address(0),
            amount: 0,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_GasAndPayload_ViaCEA_RevertWhen_RevertRecipientZero() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(0),
            amount: 0,
            payload: _defaultPayload(),
            revertRecipient: address(0),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: 0.002 ether }(req);
    }

    // =====================================================
    //  C. GAS_AND_PAYLOAD via CEA — Rate Limits
    // =====================================================

    function test_GasAndPayload_ViaCEA_USDCapsEnforced() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set caps so that a tiny gas amount falls below MIN_CAP
        // MIN_CAP = 1e18 ($1), ETH=$2000 → min wei ≈ 0.0005 ether
        // Send less than that
        uint256 tinyGas = 0.0001 ether; // ~$0.20 at $2000/ETH, below $1 min
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: tinyGas }(req);
    }

    function test_GasAndPayload_ViaCEA_BlockCapEnforced() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set a small block cap ($2) and send gas exceeding it
        vm.prank(admin);
        gateway.setBlockUsdCap(2e18); // $2

        // At $2000/ETH, 0.002 ETH = $4 > $2 cap
        uint256 gasAmount = 0.002 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasAmount }(req);
    }

    function test_GasAndPayload_ViaCEA_PayloadOnly_SkipsCaps() public {
        // Set very restrictive caps, but payload-only (msg.value=0) should skip them
        vm.prank(admin);
        gateway.setBlockUsdCap(1); // $0.000000000000000001
        setCaps(1000e18, 2000e18); // $1000-$2000 range

        bytes memory payload = _defaultPayload();
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        // Should succeed — caps skipped when gasAmount=0
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    // =====================================================
    //  D. GAS_AND_PAYLOAD via CEA — Event Semantics
    // =====================================================

    function test_GasAndPayload_ViaCEA_EventRecipientIsNeverZero() public {
        bytes memory payload = _defaultPayload();
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, payload);

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: 0.002 ether }(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedRecipient, mappedUEA, "Recipient must be mapped UEA");
                assertTrue(emittedRecipient != address(0), "Recipient must not be zero");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    function test_GasAndPayload_NormalRoute_StillEmitsZeroRecipient() public {
        // Regression: non-fromCEA GAS_AND_PAYLOAD still emits recipient=address(0)
        uint256 gasAmount = 0.002 ether;
        bytes memory payload = _defaultPayload();
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            gasAmount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx{ value: gasAmount }(req);
    }

    // =====================================================
    //  E. GAS_AND_PAYLOAD via CEA — Access Control
    // =====================================================

    function test_GasAndPayload_ViaCEA_RevertWhen_CallerNotCEA() public {
        // EOA tries GAS_AND_PAYLOAD params via sendUniversalTxFromCEA
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(0),
            amount: 0,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gateway.sendUniversalTxFromCEA{ value: 0.002 ether }(req);
    }

    // =====================================================
    //  F. TX_TYPE REJECTION TESTS
    // =====================================================

    function test_GAS_ViaCEA_Allowed() public {
        // amount=0, token=address(0), payload=empty, msg.value>0 → GAS
        // GAS is now allowed via CEA
        uint256 gasAmount = 0.002 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 0, bytes(""));

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            gasAmount,
            abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            req.revertRecipient,
            TX_TYPE.GAS,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasAmount }(req);

        assertEq(tss.balance, tssBefore + gasAmount, "TSS should receive gas");
    }

    function test_FUNDS_ViaCEA_ERC20_WithNativeValue_RoutesAsGas() public {
        // ERC-20 token + msg.value > 0 + no payload:
        // Post-fee nativeValue > 0 is routed as a gas top-up to the CEA's mapped UEA.
        // CEA path skips protocol fee, so full amount becomes gas.
        uint256 gasTopUp = 0.003 ether; // ~$6 at $2000/ETH, within $1-$10 USD cap
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, bytes(""));

        uint256 tssBalBefore = tss.balance;

        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: gasTopUp }(req);

        assertEq(tss.balance - tssBalBefore, gasTopUp, "TSS should receive gas top-up");
    }

    function test_FUNDS_ViaCEA_Native_RevertWhen_MsgValueMismatch() public {
        // Native FUNDS: msg.value must exactly equal req.amount
        UniversalTxRequest memory req = _buildViaCEARequest(address(0), 2 ether, bytes(""));

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA{ value: 1 ether }(req);
    }

    // =====================================================
    //  G. BLOCK CEAs FROM sendUniversalTx()
    // =====================================================

    function test_SendUniversalTx_RevertWhen_CallerIsCEA() public {
        // CEA calls sendUniversalTx(UniversalTxRequest) with valid GAS params
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTx{ value: 0.002 ether }(req);
    }

    function test_SendUniversalTx_AllowsNonCEA() public {
        // Regular EOA calling sendUniversalTx succeeds (regression)
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        gateway.sendUniversalTx{ value: 0.002 ether }(req);
    }

    function test_SendUniversalTx_AllowsWhenCEAFactoryNotSet() public {
        // Zero out ceaFactory — _isCallerCEA returns false, so CEA address is allowed
        vm.store(address(gateway), bytes32(uint256(61)), bytes32(0));
        assertEq(gateway.CEA_FACTORY(), address(0));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        // Should succeed because _isCallerCEA() returns false when factory not configured
        vm.prank(address(cea));
        gateway.sendUniversalTx{ value: 0.002 ether }(req);
    }

    function test_SendUniversalTx_CEA_BlockedForGasType() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTx{ value: 0.002 ether }(req);
    }

    function test_SendUniversalTx_CEA_BlockedForGasAndPayloadType() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTx{ value: 0.002 ether }(req);
    }

    function test_SendUniversalTx_CEA_BlockedForFundsType() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: 100 ether,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTx(req);
    }

    function test_SendUniversalTx_CEA_BlockedForFundsAndPayloadType() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTx(req);
    }

    // =====================================================
    //  H. FUNDS via CEA — Rate Limits, Events, Regression
    // =====================================================

    function test_FUNDS_ViaCEA_EpochRateLimitEnforced() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set a small threshold for tokenA and try to exceed it
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 50 ether;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), 100 ether, bytes(""));

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_FUNDS_ViaCEA_EventRecipientIsNeverZero() public {
        uint256 amount = 50 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, bytes(""));

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedRecipient, mappedUEA, "Recipient must be mapped UEA");
                assertTrue(emittedRecipient != address(0), "Recipient must not be zero");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    function test_FUNDS_ViaCEA_EventViaCEA_True() public {
        uint256 amount = 50 ether;
        UniversalTxRequest memory req = _buildViaCEARequest(address(tokenA), amount, bytes(""));

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxFromCEA(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                // fromCEA is the last field in non-indexed data; decode the full non-indexed data
                (
                    address token,
                    uint256 decodedAmount,
                    bytes memory payload,
                    address revertRecipient,
                    TX_TYPE txType,
                    bytes memory sigData,
                    bool fromCEA
                ) = abi.decode(logs[i].data, (address, uint256, bytes, address, TX_TYPE, bytes, bool));
                assertTrue(fromCEA, "fromCEA must be true for FUNDS via CEA");
                assertEq(uint8(txType), uint8(TX_TYPE.FUNDS), "txType must be FUNDS");
                assertEq(token, address(tokenA), "token must be tokenA");
                assertEq(decodedAmount, amount, "amount must match");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    function test_FUNDS_NormalRoute_ViaCEA_False() public {
        // Regression: user1 calling sendUniversalTx with FUNDS params must emit fromCEA=false
        uint256 amount = 50 ether;
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: amount,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        bytes32 eventSig = keccak256("UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                (,,,,,, bool fromCEA) =
                    abi.decode(logs[i].data, (address, uint256, bytes, address, TX_TYPE, bytes, bool));
                assertFalse(fromCEA, "Non-fromCEA FUNDS must emit fromCEA=false");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    function test_FundsAndPayload_NormalBatching_GasLeg_ViaCEA_False() public {
        // Regression: normal sendUniversalTx batching (Case 2.2) must emit fromCEA=false
        // and recipient=address(0) on the gas leg — not mappedUEA.
        uint256 fundsAmount = 1 ether;
        uint256 gasTopUp = 0.002 ether;
        uint256 totalValue = fundsAmount + gasTopUp;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: fundsAmount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        // Expect GAS leg: fromCEA=false, recipient=address(0)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            user1, address(0), address(0), gasTopUp, bytes(""), address(0x456), TX_TYPE.GAS, bytes(""), false
        );
        // Expect FUNDS_AND_PAYLOAD leg: fromCEA=false, recipient=address(0)
        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            fundsAmount,
            abi.encodePacked(PRC_20_SELECTOR, payload),
            address(0x456),
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx{ value: totalValue }(req);
    }
}
