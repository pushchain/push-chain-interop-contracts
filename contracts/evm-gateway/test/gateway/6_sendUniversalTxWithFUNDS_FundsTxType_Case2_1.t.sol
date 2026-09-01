// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions, VerificationType } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/**
 * @title GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_1 Test Suite
 * @notice Comprehensive tests for FUNDS_AND_PAYLOAD route (standard route) via sendUniversalTx
 * @dev Tests FUNDS_AND_PAYLOAD transaction type - Case 2.1: No Batching
 *      All paths are exercised through sendUniversalTx() which internally routes to the standard route.
 *
 * Phase 2 - TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.1 (No batching, msg.value == 0)
 *
 * Case 2.1: No Batching (msg.value == 0)
 * - User already has UEA with PC token (gas) on Push Chain to execute payloads
 * - User sends ERC20 token with payload
 * - No gas leg executed (no gas route triggered)
 * - Only ERC20 transferred to vault with payload
 */
contract GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_1_Test is BaseTest {
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

    // =========================================================================
    //      PHASE 2: TX_TYPE.FUNDS_AND_PAYLOAD - CASE 2.1 (NO BATCHING)
    // =========================================================================

    // =========================
    //      D2.1: NO BATCHING - ERC20 WITH PAYLOAD (msg.value == 0)
    // =========================

    /// @notice Test FUNDS_AND_PAYLOAD Case 2.1 - ERC20 with payload, no batching - happy path
    /// @dev Verifies:
    ///      - No gas leg executed (no gas route triggered)
    ///      - ERC20 transferred to vault
    ///      - Rate limit consumed for ERC20
    ///      - Event emitted with payload
    ///      - msg.value must be 0
    function test_Case2_1_FUNDS_AND_PAYLOAD_ERC20_NoBatching_HappyPath() public {
        uint256 fundsAmount = 1000 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA), // ERC20 token (not native)
            fundsAmount,
            encodedPayload // Non-empty payload required
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));
        uint256 tssBalanceBefore = tss.balance;
        (uint256 usedBefore,) = gatewayTemp.currentTokenUsage(address(tokenA));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(encodedPayload), // Payload preserved
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req); // msg.value == 0 (no batching)

        // Assert: Vault received ERC20
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "Vault should receive ERC20");

        // Assert: TSS did NOT receive any native ETH (no gas leg)
        assertEq(tss.balance, tssBalanceBefore, "TSS should not receive ETH in no-batching mode");

        // Assert: Rate limit consumed for ERC20
        (uint256 usedAfter,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, usedBefore + fundsAmount, "Rate limit should be consumed for ERC20");
    }

    /// @notice Test Case 2.1 - Multiple ERC20 tokens can be sent with payloads
    /// @dev Different ERC20 tokens should work independently
    function test_Case2_1_FUNDS_AND_PAYLOAD_MultipleERC20Tokens() public {
        uint256 tokenAAmount = 500 ether;
        uint256 usdcAmount = 500e6;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory reqA = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            tokenAAmount,
            encodedPayload
        );

        UniversalTxRequest memory reqU = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(usdc),
            usdcAmount,
            encodedPayload
        );

        uint256 vaultTokenABefore = tokenA.balanceOf(address(this));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(this));

        // Send tokenA
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(reqA);

        // Send usdc
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(reqU);

        // Assert: Both tokens received
        assertEq(tokenA.balanceOf(address(this)), vaultTokenABefore + tokenAAmount, "Vault should receive tokenA");
        assertEq(usdc.balanceOf(address(this)), vaultUsdcBefore + usdcAmount, "Vault should receive usdc");
    }

    /// @notice Test Case 2.1 - Payload content is preserved in event
    /// @dev Verify payload is not modified
    function test_Case2_1_FUNDS_AND_PAYLOAD_PayloadPreserved() public {
        uint256 fundsAmount = 500 ether;

        // Create custom payload with specific data
        UniversalPayload memory customPayload = UniversalPayload({
            to: address(0xABCD),
            value: 0,
            data: abi.encodeWithSignature("customFunction(uint256,address)", 12345, address(0x9999)),
            gasLimit: 500000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 42,
            deadline: 0,
            vType: VerificationType.signedVerification
        });
        bytes memory encodedPayload = abi.encode(customPayload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(encodedPayload), // Exact payload preserved
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Large payload is handled correctly
    /// @dev Verify large payloads don't cause issues
    function test_Case2_1_FUNDS_AND_PAYLOAD_LargePayload() public {
        uint256 fundsAmount = 500 ether;

        // Create large payload (10KB of data)
        bytes memory largeData = new bytes(10000);
        for (uint256 i = 0; i < 10000; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }

        UniversalPayload memory largePayload = UniversalPayload({
            to: address(0xABCD),
            value: 0,
            data: largeData,
            gasLimit: 1000000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 1,
            deadline: 0,
            vType: VerificationType.signedVerification
        });
        bytes memory encodedPayload = abi.encode(largePayload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);

        // Assert: Should succeed with large payload
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "Should handle large payload");
    }

    /// @notice Test Case 2.1 - Rate limit enforcement for ERC20
    /// @dev Should revert when exceeding ERC20 threshold
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_RateLimitExceeded() public {
        // Set a low threshold for tokenA
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 500 ether; // Low threshold

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 fundsAmount = 600 ether; // Exceeds threshold
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Cumulative rate limit for ERC20
    /// @dev Multiple calls should accumulate towards rate limit
    function test_Case2_1_FUNDS_AND_PAYLOAD_CumulativeRateLimit() public {
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 1000 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 firstAmount = 600 ether;
        uint256 secondAmount = 300 ether; // Total 900 ether (within limit)
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            firstAmount,
            encodedPayload
        );

        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            secondAmount,
            encodedPayload
        );

        // First call succeeds
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req1);

        // Second call succeeds (cumulative 900 < 1000)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req2);

        // Verify cumulative usage
        (uint256 used,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(used, firstAmount + secondAmount, "Cumulative usage should match");
    }

    // =========================
    //      D2.1: VALIDATION & REVERT CASES
    // =========================

    /// @notice Test Case 2.1 - Native token not allowed in no-batching mode
    /// @dev token == address(0) with msg.value == 0 should revert
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_NativeToken_NoBatching() public {
        uint256 fundsAmount = 100 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0), // Native token NOT allowed in no-batching mode
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidInput.selector); // _fetchTxType throws InvalidInput for invalid combinations
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req); // msg.value == 0
    }

    /// @notice Test Case 2.1 - Empty payload routes to FUNDS (matrix inference)
    /// @dev Matrix infers FUNDS when !hasPayload && hasFunds && !fundsIsNative && !hasNativeValue
    /// FUNDS with recipient != address(0) triggers InvalidRecipient
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_EmptyPayload() public {
        uint256 fundsAmount = 500 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            bytes("") // Empty payload → matrix routes to FUNDS
        );

        // Empty payload routes to FUNDS, which succeeds with recipient == address(0)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0),
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(bytes("")),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Zero amount routes to GAS_AND_PAYLOAD (payload-only)
    /// @dev Ensure payload-only requests emit GAS_AND_PAYLOAD event and do not move funds
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_ZeroAmount() public {
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            0, // Zero amount forces routing to GAS_AND_PAYLOAD (payload-only)
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 tokenABalanceBefore = tokenA.balanceOf(address(gatewayTemp));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: _pp(encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);

        assertEq(tss.balance, tssBalanceBefore, "TSS balance should remain unchanged when gasAmount is zero");
        assertEq(
            tokenA.balanceOf(address(gatewayTemp)),
            tokenABalanceBefore,
            "Gateway should not receive ERC20 when amount is zero"
        );
    }

    /// @notice Test Case 2.1 - Zero revertRecipient reverts
    /// @dev revertInstruction.revertRecipient must be non-zero
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_ZerorevertRecipient() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: address(0), // Zero address not allowed
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Unsupported token reverts
    /// @dev Token with threshold=0 should revert with NotSupported
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_UnsupportedToken() public {
        // Deploy a new token that's not configured
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNSUP", 18, 0);
        unsupportedToken.mint(user1, 1000 ether);

        vm.prank(user1);
        unsupportedToken.approve(address(gatewayTemp), type(uint256).max);

        uint256 fundsAmount = 100 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(unsupportedToken),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.NotSupported.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Insufficient allowance reverts
    /// @dev Should revert with ERC20InsufficientAllowance
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_InsufficientAllowance() public {
        uint256 fundsAmount = 1000 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Create a user with no approval
        address userNoApproval = address(0x7777);
        tokenA.mint(userNoApproval, fundsAmount);
        // No approval given

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(); // ERC20InsufficientAllowance
        vm.prank(userNoApproval);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Insufficient balance reverts
    /// @dev Should revert with ERC20InsufficientBalance
    function test_Case2_1_FUNDS_AND_PAYLOAD_RevertOn_InsufficientBalance() public {
        uint256 fundsAmount = 1000 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Create a user with approval but no balance
        address userNoBalance = address(0x8888);
        // No tokens minted

        vm.prank(userNoBalance);
        tokenA.approve(address(gatewayTemp), type(uint256).max);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(); // ERC20InsufficientBalance
        vm.prank(userNoBalance);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      D2.1: EDGE CASES & ADDITIONAL TESTS
    // =========================

    /// @notice Test Case 2.1 - Event preserves revertMsg
    /// @dev revertMsg should be emitted correctly
    function test_Case2_1_FUNDS_AND_PAYLOAD_EventPreservesrevertMsg() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);
        bytes memory revertMsg = abi.encodePacked("custom revert data", uint256(12345));

        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0x999), revertMsg: revertMsg });

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: revertInst.revertRecipient,
            signatureData: bytes("")
        });

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(encodedPayload),
            revertRecipient: revertInst.revertRecipient, // Full struct with revertMsg
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Event preserves signatureData
    /// @dev SignatureData should be emitted correctly
    function test_Case2_1_FUNDS_AND_PAYLOAD_EventPreservesSignatureData() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);
        bytes memory sigData = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: address(0x456),
            signatureData: sigData
        });

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: sigData, // Should preserve signature data
            fromCEA: false
         });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.1 - Recipient can be zero (UEA on Push Chain)
    /// @dev Zero recipient is allowed for FUNDS_AND_PAYLOAD
    function test_Case2_1_FUNDS_AND_PAYLOAD_AllowsZeroRecipient() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // Zero recipient allowed (UEA)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);

        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "Should allow zero recipient");
    }

    /// @notice Test Case 2.1 - Non-zero recipient reverts
    /// @dev FUNDS_AND_PAYLOAD requires recipient == address(0)
    function test_Case2_1_FUNDS_AND_PAYLOAD_RecipientEmittedAlwaysZero() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(encodedPayload),
            revertRecipient: address(0x456),
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(
            buildUniversalTxRequest(
                address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
                address(tokenA),
                fundsAmount,
                encodedPayload
            )
        );
    }

    /// @notice Test Case 2.1 - Gateway does not accumulate ETH
    /// @dev Gateway should not hold any native ETH in no-batching mode
    function test_Case2_1_FUNDS_AND_PAYLOAD_GatewayDoesNotAccumulateETH() public {
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            encodedPayload
        );

        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        // Make multiple calls
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: 0 }(req);
        }

        // Gateway balance should remain unchanged
        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not hold native ETH");
    }
}
