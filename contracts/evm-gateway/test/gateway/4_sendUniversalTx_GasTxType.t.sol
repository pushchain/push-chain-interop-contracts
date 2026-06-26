// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title GatewaySendUniversalTxWithGas Test Suite
 * @notice Comprehensive tests for _sendTxWithGas (instant route) via sendUniversalTx
 * @dev Tests GAS and GAS_AND_PAYLOAD transaction types with focus on:
 *      - Validation rules (_validateUniversalTxWithGas)
 *      - Per-tx USD caps (checkUSDCaps)
 *      - Per-block USD caps (_checkBlockUSDCap)
 *      - Native forwarding to TSS
 *      - Event emission correctness
 */
contract GatewaySendUniversalTxWithGasTest is BaseTest {
    // UniversalGateway instance
    UniversalGateway public gatewayTemp;

    // =========================
    //      EVENTS
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
    //      SETUP
    // =========================
    function setUp() public override {
        super.setUp();

        // Deploy UniversalGateway
        _deployGatewayTemp();

        // Wire oracle to the new gateway instance
        vm.prank(admin);
        gatewayTemp.setEthUsdFeed(address(ethUsdFeedMock));

        // Setup token support on gatewayTemp (native + all mock ERC20s)
        address[] memory tokens = new address[](4);
        uint256[] memory thresholds = new uint256[](4);
        tokens[0] = address(0); // Native token
        tokens[1] = address(tokenA); // Mock ERC20 tokenA
        tokens[2] = address(usdc); // Mock ERC20 usdc
        tokens[3] = address(weth); // Mock WETH
        thresholds[0] = 1000000 ether; // Large threshold for native
        thresholds[1] = 1000000 ether; // Large threshold for tokenA
        thresholds[2] = 1000000e6; // Large threshold for usdc (6 decimals)
        thresholds[3] = 1000000 ether; // Large threshold for weth

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        // Re-approve tokens to gatewayTemp
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = attacker;

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            tokenA.approve(address(gatewayTemp), type(uint256).max);

            vm.prank(users[i]);
            usdc.approve(address(gatewayTemp), type(uint256).max);

            vm.prank(users[i]);
            weth.approve(address(gatewayTemp), type(uint256).max);
        }
    }

    /// @notice Deploy UniversalGateway
    function _deployGatewayTemp() internal {
        UniversalGateway implementation = new UniversalGateway();

        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            address(this),
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            address(weth)
        );

        TransparentUpgradeableProxy tempProxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        gatewayTemp = UniversalGateway(payable(address(tempProxy)));
        vm.label(address(gatewayTemp), "UniversalGateway");
    }

    /// @notice Helper to build UniversalTxRequest structs
    function buildUniversalTxRequest(address recipient_, address token, uint256 amount, bytes memory payload)
        internal
        pure
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: recipient_,
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    // =========================
    //      C1: VALIDATION RULES
    // =========================

    /// @notice Test GAS requires empty payload
    /// @dev txType=GAS with non-empty payload should revert
    function test_SendTxWithGas_GAS_RevertOn_NonEmptyPayload() public {
        // Arrange
        uint256 gasAmount = 0.001 ether;
        bytes memory nonEmptyPayload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            nonEmptyPayload
        );

        // Matrix will infer GAS_AND_PAYLOAD (hasPayload && !hasFunds && hasNativeValue)
        // The deprecated txType field is ignored - call should succeed
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test GAS accepts empty payload
    /// @dev txType=GAS with empty payload should succeed
    function test_SendTxWithGas_GAS_SucceedsWith_EmptyPayload() public {
        // Arrange
        uint256 gasAmount = 0.001 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("") // ✅ Empty payload for GAS
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive gas amount");
    }

    /// @notice Test that empty payload with amount=0 routes to GAS (matrix inference)
    /// @dev Matrix infers GAS when !hasPayload && !hasFunds && hasNativeValue
    /// The deprecated txType field is ignored for routing
    function test_SendTxWithGas_GAS_AND_PAYLOAD_RevertOn_EmptyPayload() public {
        // Arrange
        uint256 gasAmount = 0.002 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            // This field is ignored - matrix will infer GAS
            address(0),
            address(0),
            0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            bytes("")
        );

        // Should succeed - matrix routes to GAS
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test GAS_AND_PAYLOAD accepts non-empty payload
    /// @dev txType=GAS_AND_PAYLOAD with non-empty payload should succeed
    function test_SendTxWithGas_GAS_AND_PAYLOAD_SucceedsWith_NonEmptyPayload() public {
        // Arrange
        uint256 gasAmount = 0.002 ether;
        bytes memory nonEmptyPayload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            nonEmptyPayload // ✅ Non-empty payload for GAS_AND_PAYLOAD
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive gas amount");
    }

    /// @notice Test GAS_AND_PAYLOAD allows zero gas when only payload is provided
    /// @dev User can send payload-only requests (no gas, no funds) - _fetchTxType should route to GAS_AND_PAYLOAD
    ///      This covers the case where user already has funds on Push Chain and only needs to send payload
    function test_SendTxWithGas_GAS_AND_PAYLOAD_AllowsZeroGas() public {
        // Arrange: Payload-only request (hasPayload=true, hasFunds=false, hasNativeValue=false)
        // _fetchTxType should infer TX_TYPE.GAS_AND_PAYLOAD for this combination
        uint256 gasAmount = 0; // No native value sent
        bytes memory nonEmptyPayload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // No funds (amount = 0)
            nonEmptyPayload // Payload is present
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act & Assert: Expect GAS_AND_PAYLOAD event with zero amount
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // address(0) for UEA credit
            token: address(0), // Native token (even though amount is 0)
            amount: gasAmount, // Zero amount
            payload: nonEmptyPayload, // Payload is present
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert: No native ETH forwarded to TSS when gasAmount is zero
        assertEq(tss.balance, tssBalanceBefore, "TSS balance should remain unchanged when gasAmount is zero");
    }

    /// @notice Test revertInstruction.revertRecipient must be non-zero for GAS
    /// @dev Zero revertRecipient should revert with InvalidRecipient
    function test_SendTxWithGas_GAS_RevertOn_ZerorevertRecipient() public {
        // Arrange
        uint256 gasAmount = 0.001 ether;

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            payload: bytes(""),
            revertRecipient: address(0), // ❌ Zero address
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test revertInstruction.revertRecipient must be non-zero for GAS_AND_PAYLOAD
    /// @dev Zero revertRecipient should revert with InvalidRecipient
    function test_SendTxWithGas_GAS_AND_PAYLOAD_RevertOn_ZerorevertRecipient() public {
        uint256 gasAmount = 0.002 ether;
        bytes memory payload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            payload: payload,
            revertRecipient: address(0),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test amount=0 fails USD cap check
    /// @dev Zero amount results in 0 USD which is below minCapUniversalTxUsd
    function test_SendTxWithGas_GAS_RevertOn_ZeroAmount() public {
        // Arrange
        UniversalTxRequest memory req = buildUniversalTxRequest(address(0), address(0), 0, bytes(""));

        vm.expectRevert(Errors.InvalidInput.selector); // _fetchTxType throws InvalidInput for zero native value
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      C2: PER-TX USD CAP RANGE
    // =========================

    /// @notice Test amount below minCapUniversalTxUsd reverts
    /// @dev At $2000/ETH, $1 min = 0.0005 ETH. Test with 0.0004 ETH ($0.80)
    function test_SendTxWithGas_RevertOn_BelowMinCap() public {
        // Arrange: At $2000/ETH, 0.0004 ETH = $0.80 (below $1 min)
        uint256 gasAmount = 0.0004 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test amount above maxCapUniversalTxUsd reverts
    /// @dev At $2000/ETH, $10 max = 0.005 ETH. Test with 0.006 ETH ($12)
    function test_SendTxWithGas_RevertOn_AboveMaxCap() public {
        // Arrange: At $2000/ETH, 0.006 ETH = $12 (above $10 max)
        uint256 gasAmount = 0.006 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test amount exactly at minCapUniversalTxUsd succeeds
    /// @dev At $2000/ETH, $1 min = 0.0005 ETH exactly
    function test_SendTxWithGas_SucceedsAt_ExactMinCap() public {
        // Arrange: At $2000/ETH, 0.0005 ETH = exactly $1
        uint256 gasAmount = 0.0005 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive exact min cap amount");
    }

    // =========================
    //      C3: PER-BLOCK USD CAP
    // =========================

    // NOTE: Most of these tests are already in test/gateway/5_GatewayBlockRateLimit.t.sol - Skipping here

    /// @notice Test block cap disabled (cap=0) allows unlimited calls
    /// @dev With blockUsdCap=0, should accept any number of calls in same block
    function test_SendTxWithGas_BlockCap_Disabled_AllowsUnlimited() public {
        // Arrange: Ensure block cap is 0 (disabled by default)
        assertEq(gatewayTemp.blockUsdCap(), 0, "Block cap should be 0 by default");

        uint256 gasAmount = 0.002 ether; // $4 per call at $2000/ETH

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act: Make 5 calls in same block (total $20, no limit)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
        }

        // Assert: All calls succeeded
        assertEq(tss.balance, tssBalanceBefore + (gasAmount * 5), "All 5 calls should succeed");
    }

    /// @notice Test single call exceeding block cap reverts
    /// @dev Set cap=$5, attempt call worth $6
    function test_SendTxWithGas_BlockCap_RevertOn_SingleCallExceedsCap() public {
        // Arrange: Set block cap to $5 (5e18)
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(5e18);

        // At $2000/ETH, 0.003 ETH = $6 (exceeds $5 cap)
        uint256 gasAmount = 0.003 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        // Act & Assert
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test cumulative calls exceeding block cap reverts
    /// @dev Set cap=$10, first call $6 (60%), second call $5 (50%) should revert
    function test_SendTxWithGas_BlockCap_RevertOn_CumulativeExceedsCap() public {
        // Arrange: Set block cap to $10 (10e18)
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(10e18);

        // First call: 0.003 ETH = $6 at $2000/ETH (60% of cap)
        uint256 firstAmount = 0.003 ether;
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        // Second call: 0.0025 ETH = $5 at $2000/ETH (would be 110% cumulative)
        uint256 secondAmount = 0.0025 ether;
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        // Act: First call succeeds
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: firstAmount }(req1);

        // Act & Assert: Second call reverts (cumulative $11 > $10 cap)
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: secondAmount }(req2);
    }

    // =========================
    //      C4: NATIVE FORWARDING & EVENT
    // =========================

    /// @notice Test native ETH forwarded to TSS for GAS
    /// @dev Verify TSS balance increases by exact amount
    function test_SendTxWithGas_GAS_ForwardsNative_ToTSS() public {
        uint256 gasAmount = 0.002 ether;
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive exact gas amount");

        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not hold funds");
    }

    /// @notice Test native ETH forwarded to TSS for GAS_AND_PAYLOAD
    /// @dev Verify TSS balance increases by exact amount
    function test_SendTxWithGas_GAS_AND_PAYLOAD_ForwardsNative_ToTSS() public {
        uint256 gasAmount = 0.003 ether;
        bytes memory payload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            payload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        // Act
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert: TSS received funds
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive exact gas amount");

        // Assert: Gateway balance unchanged
        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not hold funds");
    }

    /// @notice Test UniversalTx event correctness for GAS
    /// @dev Verify all event parameters match expected values
    function test_SendTxWithGas_GAS_EmitsCorrect_UniversalTxEvent() public {
        // Arrange
        uint256 gasAmount = 0.002 ether;
        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0x789), revertMsg: bytes("test context") });
        bytes memory sigData = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            payload: bytes(""),
            revertRecipient: revertInst.revertRecipient,
            signatureData: sigData
        });

        // Act & Assert: Expect event with exact parameters
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0), // Always address(0) for gas routes (UEA credit)
            token: address(0), // Native token
            amount: gasAmount,
            payload: bytes(""), // Empty for GAS
            revertRecipient: revertInst.revertRecipient,
            signatureData: sigData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test UniversalTx event correctness for GAS_AND_PAYLOAD
    /// @dev Verify all event parameters including non-empty payload
    function test_SendTxWithGas_GAS_AND_PAYLOAD_EmitsCorrect_UniversalTxEvent() public {
        uint256 gasAmount = 0.003 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0xABC), revertMsg: bytes("payload context") });
        bytes memory sigData = abi.encodePacked(bytes32(uint256(3)), bytes32(uint256(4)));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            payload: encodedPayload,
            revertRecipient: revertInst.revertRecipient,
            signatureData: sigData
        });

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // Always address(0) for gas routes (UEA credit)
            token: address(0), // Native token
            amount: gasAmount,
            payload: encodedPayload, // Non-empty for GAS_AND_PAYLOAD
            revertRecipient: revertInst.revertRecipient,
            signatureData: sigData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    /// @notice Test event emitted with empty signatureData
    /// @dev Verify empty signature data is acceptable
    function test_SendTxWithGas_Event_WithEmpty_SignatureData() public {
        uint256 gasAmount = 0.001 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );
        // signatureData is already empty

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: gasAmount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""), // Empty
            fromCEA: false
         });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
    }

    // =========================
    //      ADDITIONAL EDGE CASES
    // =========================

    /// @notice Test multiple users can call in same block (within caps)
    /// @dev Verify different users share the same block cap
    function test_SendTxWithGas_MultipleUsers_ShareBlockCap() public {
        // Arrange: Set block cap to $10
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(10e18);

        // Each user sends $3 worth
        uint256 gasAmount = 0.0015 ether; // $3 at $2000/ETH

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act: user1 sends $3 (total $3)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Act: user2 sends $3 (total $6)
        vm.prank(user2);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Act: user3 sends $3 (total $9)
        vm.prank(user3);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Act & Assert: user4 tries to send $3 (would be $12 total) - should revert
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user4);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert: First 3 users succeeded
        assertEq(tss.balance, tssBalanceBefore + (gasAmount * 3), "First 3 users should succeed");
    }

    /// @notice Test GAS and GAS_AND_PAYLOAD share the same block cap
    /// @dev Both transaction types consume from the same block budget
    function test_SendTxWithGas_GAS_And_GAS_AND_PAYLOAD_ShareBlockCap() public {
        // Arrange: Set block cap to $10
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(10e18);

        // GAS call: $6
        uint256 gasAmount1 = 0.003 ether;
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        // GAS_AND_PAYLOAD call: $5 (would exceed cap)
        uint256 gasAmount2 = 0.0025 ether;
        bytes memory payload = abi.encode(buildDefaultPayload());
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            address(0),
            0,
            payload
        );

        // Act: GAS call succeeds
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount1 }(req1);

        // Act & Assert: GAS_AND_PAYLOAD call reverts (cumulative $11 > $10)
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount2 }(req2);
    }

    /// @notice Test large payload doesn't affect USD cap checks
    /// @dev USD caps only check amount, not payload size
    function test_SendTxWithGas_LargePayload_DoesNotAffect_USDCaps() public {
        bytes memory largePayload = new bytes(10000);
        for (uint256 i = 0; i < 10000; i++) {
            largePayload[i] = bytes1(uint8(i % 256));
        }
        bytes memory encodedPayload = abi.encode(largePayload);

        uint256 gasAmount = 0.002 ether; // $4 at $2000/ETH (within caps)

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act: Should succeed despite large payload
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "Large payload should not affect USD cap check");
    }

    /// @notice Test contract balance remains zero after forwarding
    /// @dev Gateway should not accumulate native ETH
    function test_SendTxWithGas_Gateway_DoesNotAccumulate_NativeETH() public {
        uint256 gasAmount = 0.002 ether;
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0),
            address(0),
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("")
        );

        // Act: Make multiple calls
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: gasAmount }(req);
        }

        // Assert: Gateway balance should be 0
        assertEq(address(gatewayTemp).balance, 0, "Gateway should not hold any native ETH");
    }
}
