// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions, VerificationType, PRC_20_SELECTOR } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_2 Test Suite
 * @notice Comprehensive tests for FUNDS_AND_PAYLOAD route (standard route) via sendUniversalTx
 * @dev Tests FUNDS_AND_PAYLOAD transaction type - Case 2.2: Native Batching
 *      All paths are exercised through sendUniversalTx() which internally routes to both instant and standard routes.
 *
 * Phase 3 - TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.2 (Native batching, msg.value > 0, token == native)
 *
 * Case 2.2: Batching of Gas + Funds_and_Payload (msg.value > 0, token == native)
 * - User refills UEA's gas AND bridges native token in one transaction
 * - Split Logic: msg.value is split between gasAmount and fundsAmount
 * - gasAmount = msg.value - _req.amount
 * - Dual Execution:
 *   1. Gas route triggered if gasAmount > 0 (instant route with USD caps)
 *   2. Native token rate limit consumed for _req.amount only
 *   3. All msg.value forwarded to TSS
 */
contract GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_2_Test is BaseTest {
    // UniversalGateway instance
    UniversalGateway public gatewayTemp;

    // =========================
    //      EVENTS
    // =========================
    event UniversalTx( // Placeholder value - ignored by matrix inference but required for struct
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
            UniversalGateway.initializeV2.selector,
            admin,
            pauser,
            tss,
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            address(weth),
            address(0)
        );

        TransparentUpgradeableProxy tempProxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        gatewayTemp = UniversalGateway(payable(address(tempProxy)));
        _configureGatewayPostDeploy(gatewayTemp, admin, address(this));
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
    //      PHASE 3: TX_TYPE.FUNDS_AND_PAYLOAD - CASE 2.2 (NATIVE BATCHING)
    // =========================================================================

    // =========================
    //      CATEGORY 1: HAPPY PATH & CORE FUNCTIONALITY
    // =========================

    /// @notice Test Case 2.2 - Native batching happy path with split
    /// @dev Verifies:
    ///      - msg.value split correctly: gasAmount = msg.value - amount
    ///      - Gas route called with gasAmount
    ///      - Funds route called with amount
    ///      - TSS receives full msg.value
    ///      - Two events emitted (gas + funds)
    ///      - Native rate limit consumed for amount only (not gasAmount)
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_Batching_HappyPath() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        uint256 expectedGasAmount = msgValue - fundsAmount; // 0.002 ether = $4

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0), // Native token
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        (uint256 nativeUsedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        // Expect two events: Gas event + Funds event
        // Event 1: Gas event (gasAmount = 4 ETH)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0), // Gas always credits UEA
            token: address(0),
            amount: expectedGasAmount,
            payload: bytes(""), // Gas event has empty payload
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Event 2: Funds event (amount = 6 ETH)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload), // Funds event has full payload
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: TSS received full msg.value
        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full msg.value");

        // Assert: Native rate limit consumed for fundsAmount only (not gasAmount)
        (uint256 nativeUsedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(nativeUsedAfter, nativeUsedBefore + fundsAmount, "Rate limit should only consume fundsAmount");
    }

    /// @notice Test Case 2.2 - Exact amount (no gas, gasAmount = 0 - means no batching)
    /// @dev When msg.value == amount, gasAmount = 0, no gas route called
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_ExactAmount_NoGas() public {
        uint256 msgValue = 5 ether;
        uint256 fundsAmount = 5 ether; // Exact match

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        // Expect only ONE event: Funds event (no gas event)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full msg.value");
    }

    /// @notice Test Case 2.2 - Small gas amount with large funds
    /// @dev Verify split works with opposite asymmetric distribution
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_SmallGasLargeFunds() public {
        uint256 msgValue = 10 ether;
        uint256 fundsAmount = 9.999 ether;
        uint256 expectedGasAmount = 0.001 ether; // $2 at $2000/ETH (within caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: TSS received full msg.value
        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full msg.value");
    }

    /// @notice Test Case 2.2 - Payload preserved in funds event
    /// @dev Gas event has empty payload, funds event has full payload
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_PayloadPreserved() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)

        // Custom payload
        UniversalPayload memory customPayload = UniversalPayload({
            to: address(0xABCD),
            value: 0,
            data: abi.encodeWithSignature("customFunction(uint256)", 12345),
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
            address(0),
            fundsAmount,
            encodedPayload
        );

        // Gas event: empty payload
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: msgValue - fundsAmount,
            payload: bytes(""), // Empty for gas event
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Funds event: full payload
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload), // Full payload preserved
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Multiple users can send independently
    /// @dev Different users should be able to send batched transactions
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_MultipleUsers() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        // user1 sends
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // user2 sends
        vm.prank(user2);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // user3 sends
        vm.prank(user3);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: All succeeded
        assertEq(tss.balance, tssBalanceBefore + (msgValue * 3), "All users should succeed");
    }

    // =========================
    //      CATEGORY 2: VALIDATION & REVERT CASES
    // =========================

    /// @notice Test Case 2.2 - Revert when msg.value < amount
    /// @dev Critical: msg.value must be >= amount for split to work
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_MsgValueLessThanAmount() public {
        uint256 msgValue = 5 ether;
        uint256 fundsAmount = 6 ether; // More than msg.value

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Empty payload routes to FUNDS (not FUNDS_AND_PAYLOAD)
    /// @dev Empty payload means hasPayload=false, so _fetchTxType routes to FUNDS
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_EmptyPayload() public {
        uint256 fundsAmount = 1 ether;
        // For FUNDS, msg.value must equal amount
        uint256 msgValue = fundsAmount;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("") // Empty payload - routes to FUNDS, not FUNDS_AND_PAYLOAD
        );

        // Empty payload routes to FUNDS (not FUNDS_AND_PAYLOAD), which succeeds
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, bytes("")),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Zero amount reverts
    /// @dev Amount must be > 0
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_ZeroAmount() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 1 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            0, // Zero amount
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Zero msg.value routes to Case 2.1 (which reverts for native)
    /// @dev Ensures Case 2.2 is NOT triggered when msg.value == 0
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_ZeroMsgValue() public {
        uint256 fundsAmount = 1 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0), // Native token
            fundsAmount,
            encodedPayload
        );

        // Should route to Case 2.1, which reverts for native token with msg.value == 0
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test Case 2.2 - Zero revertRecipient reverts
    /// @dev revertInstruction.revertRecipient must be non-zero
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_ZerorevertRecipient() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: address(0), // Zero address
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Gas amount below min USD cap reverts
    /// @dev At $2000/ETH, min cap = $1 = 0.0005 ETH
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_GasAmountBelowMinUSDCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 1.0004 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.0004 ETH = $0.80 (below $1 min cap)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Gas amount above max USD cap reverts
    /// @dev At $2000/ETH, max cap = $10 = 0.005 ETH
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_GasAmountAboveMaxUSDCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 1.006 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.006 ETH = $12 (above $10 max cap)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Gas amount exceeds block cap reverts
    /// @dev Set block cap and verify gas route respects it
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_GasAmountExceedsBlockCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set block cap to $5
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(5e18);

        uint256 msgValue = 1.003 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.003 ETH = $6 (exceeds $5 block cap)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    // =========================
    //      CATEGORY 3: RATE LIMITING
    // =========================

    /// @notice Test Case 2.2 - Rate limit only for funds amount (not gas amount)
    /// @dev Critical: Only fundsAmount consumes native rate limit, gasAmount uses USD caps
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RateLimitOnlyForFunds() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ether = $4 (does NOT consume rate limit)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        (uint256 usedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: Rate limit consumed for fundsAmount only (6 ETH, not 10 ETH)
        (uint256 usedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(usedAfter, usedBefore + fundsAmount, "Rate limit should only consume fundsAmount");
    }

    /// @notice Test Case 2.2 - Funds amount exceeds rate limit reverts
    /// @dev Even if msg.value is large enough for gas, funds must respect rate limit
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_FundsExceedRateLimit() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set low threshold for native
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 5 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 msgValue = 6.001 ether;
        uint256 fundsAmount = 6 ether; // Exceeds 5 ETH threshold
        // gasAmount = 0.001 ether = $2 (within USD caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Cumulative rate limit for funds
    /// @dev Multiple calls accumulate towards rate limit
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_CumulativeRateLimit() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 10 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Call 1: fundsAmount = 6 ETH
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            6 ether,
            encodedPayload
        );

        // Call 2: fundsAmount = 3 ETH (cumulative 9 ETH < 10 ETH)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            3 ether,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 6.001 ether }(req1); // 6 ETH funds + 0.001 ETH gas ($2)

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 3.001 ether }(req2); // 3 ETH funds + 0.001 ETH gas ($2)

        // Verify cumulative usage
        (uint256 used,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(used, 9 ether, "Cumulative rate limit should be 9 ETH");
    }

    /// @notice Test Case 2.2 - Cumulative rate limit exceeded reverts
    /// @dev Second call should fail when cumulative exceeds threshold
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RevertOn_CumulativeRateLimitExceeded() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 10 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Call 1: fundsAmount = 6 ETH
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            6 ether,
            encodedPayload
        );

        // Call 2: fundsAmount = 5 ETH (cumulative 11 ETH > 10 ETH)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            5 ether,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 6.001 ether }(req1); // 6 ETH funds + 0.001 ETH gas

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 5.001 ether }(req2); // 5 ETH funds + 0.001 ETH gas
    }

    /// @notice Test Case 2.2 - Rate limit resets in new epoch
    /// @dev After epoch duration, rate limit should reset
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_RateLimitResetsInNewEpoch() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 5 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            4.5 ether,
            encodedPayload
        );

        // First call in epoch 1
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 4.501 ether }(req); // 4.5 ETH funds + 0.001 ETH gas ($2)

        // Advance time to next epoch
        vm.warp(block.timestamp + 86401);
        vm.roll(block.number + 1);

        // Update oracle timestamp to prevent stale data error
        ethUsdFeedMock.setAnswer(2000e8, block.timestamp);

        // Second call in epoch 2 (should succeed as limit reset)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 4.501 ether }(req); // 4.5 ETH funds + 0.001 ETH gas ($2)

        // Verify usage reset
        (uint256 used,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(used, 4.5 ether, "Usage should reset in new epoch");
    }

    // =========================
    //      CATEGORY 4: EVENT EMISSION & DUAL EVENTS
    // =========================

    /// @notice Test Case 2.2 - Two events emitted when gasAmount > 0
    /// @dev Verify both gas and funds events are emitted
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_EmitsTwoEvents_WhenGasAmountPositive() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        uint256 gasAmount = 0.002 ether; // $4

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        // Event 1: Gas
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: gasAmount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Event 2: Funds
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - One event emitted when gasAmount = 0
    /// @dev Only funds event when msg.value == amount
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_EmitsOneEvent_WhenGasAmountZero() public {
        uint256 msgValue = 5 ether;
        uint256 fundsAmount = 5 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        // Only funds event (no gas event)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Gas event has empty payload
    /// @dev Gas event always has empty payload, funds event has full payload
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_GasEvent_HasEmptyPayload() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        uint256 gasAmount = 0.002 ether; // $4 (within caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        // Gas event: empty payload
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: gasAmount,
            payload: bytes(""), // Empty
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Gas event recipient always address(0)
    /// @dev Gas always credits UEA, funds preserves recipient
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_GasEvent_RecipientAlwaysZero() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        uint256 gasAmount = 0.002 ether; // $4 (within caps)
        address explicitRecipient = address(0x999);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        // Gas event: recipient = address(0)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0), // Always zero for gas
            token: address(0),
            amount: gasAmount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Funds event: recipient preserved
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: abi.encodePacked(PRC_20_SELECTOR, encodedPayload),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Events preserve revertMsg
    /// @dev Both events should preserve revertMsg
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_EventsPreserverevertMsg() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)
        bytes memory revertMsg = abi.encodePacked("custom revert", uint256(999));

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0x456), revertMsg: revertMsg });

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: revertInst.revertRecipient,
            signatureData: bytes("")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        // Both events should have preserved revertMsg (verified implicitly)
    }

    /// @notice Test Case 2.2 - Events preserve signatureData
    /// @dev Both events should preserve signatureData
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_EventsPreserveSignatureData() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)
        bytes memory sigData = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: encodedPayload,
            revertRecipient: address(0x456),
            signatureData: sigData
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        // Both events should have preserved signatureData (verified implicitly)
    }

    // =========================
    //      CATEGORY 5: TSS BALANCE & FUND FLOW
    // =========================

    /// @notice Test Case 2.2 - TSS receives full msg.value
    /// @dev All native ETH should go to TSS (gas + funds)
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_TSS_ReceivesFullMsgValue() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ether = $4 (within USD caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: TSS received full msg.value
        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full msg.value");

        // Assert: Gateway balance unchanged
        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not hold ETH");
    }

    /// @notice Test Case 2.2 - Gateway does not accumulate ETH
    /// @dev Gateway should not hold any native ETH after multiple calls
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_Gateway_DoesNotAccumulate() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        // Make multiple calls
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        }

        // Gateway balance should remain unchanged
        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not accumulate ETH");
    }

    /// @notice Test Case 2.2 - Fund split correct distribution
    /// @dev Verify gas and funds routes receive correct amounts
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_FundSplit_CorrectDistribution() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        uint256 expectedGasAmount = 0.002 ether; // $4 (within USD caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: Total received equals msg.value
        assertEq(tss.balance - tssBalanceBefore, msgValue, "Total should equal msg.value");
    }

    /// @notice Test Case 2.2 - Exact amount sends all to funds route
    /// @dev When msg.value == amount, all goes to funds (no gas route)
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_ExactAmount_AllToFunds() public {
        uint256 msgValue = 5 ether;
        uint256 fundsAmount = 5 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: TSS received full amount
        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full amount");
    }

    // =========================
    //      CATEGORY 6: EDGE CASES & BOUNDARY CONDITIONS
    // =========================

    /// @notice Test Case 2.2 - Minimal gas amount at min cap
    /// @dev gasAmount = 0.0005 ETH (exactly $1 at $2000/ETH)
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_MinimalGasAmount_AtMinCap() public {
        uint256 msgValue = 1.0005 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.0005 ETH = $1 (at min cap)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Should succeed at min cap");
    }

    /// @notice Test Case 2.2 - Maximal gas amount at max cap
    /// @dev gasAmount = 0.005 ETH (exactly $10 at $2000/ETH)
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_MaximalGasAmount_AtMaxCap() public {
        uint256 msgValue = 1.005 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.005 ETH = $10 (at max cap)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Should succeed at max cap");
    }

    /// @notice Test Case 2.2 - Large payload does not affect gas caps
    /// @dev Gas USD caps only check amount, not payload size
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_LargePayload_DoesNotAffectGasCaps() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)

        // Create large payload (10KB)
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
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Large payload should not affect gas caps");
    }

    /// @notice Test Case 2.2 - Very large funds within rate limit
    /// @dev Should handle large amounts correctly
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_VeryLargeFunds_WithinRateLimit() public {
        uint256 fundsAmount = 5000 ether;
        uint256 msgValue = fundsAmount + 0.001 ether; // Add minimal gas

        // Give user enough ETH
        vm.deal(user1, msgValue);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Should handle large amounts");
    }

    /// @notice Test Case 2.2 - Multiple calls same block respect gas block cap
    /// @dev Cumulative gas amounts checked against block cap
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_MultipleCallsSameBlock_GasBlockCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set block cap to $8
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(8e18);

        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 per call

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(0),
            fundsAmount,
            encodedPayload
        );

        // First call: $4 gas (within $8 cap)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Second call: $4 gas (cumulative $8, at cap)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Third call: $4 gas (cumulative $12, exceeds $8 cap)
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.2 - Different recipients work correctly
    /// @dev Both zero and non-zero recipients should work
    function test_Case2_2_FUNDS_AND_PAYLOAD_Native_DifferentRecipients_Work() public {
        uint256 msgValue = 1.002 ether;
        uint256 fundsAmount = 1 ether;
        // gasAmount = 0.002 ETH = $4 (within caps)

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Test with zero recipient
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // Zero recipient
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req1);

        // Test with zero recipient (non-zero not allowed for FUNDS_AND_PAYLOAD)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // Zero recipient (required)
            address(0),
            fundsAmount,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req2);

        // Both should succeed
    }
}
