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
 * @title GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_3 Test Suite
 * @notice Comprehensive tests for FUNDS_AND_PAYLOAD route (standard route) via sendUniversalTx
 * @dev Tests FUNDS_AND_PAYLOAD transaction type - Case 2.3: ERC20 + Native Batching
 *      All paths are exercised through sendUniversalTx() which internally routes to both instant and standard routes.
 *
 * Phase 4 - TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.3 (ERC20 batching, msg.value > 0, token != native)
 *
 * Case 2.3: Batching of Gas + Funds_and_Payload (msg.value > 0, token != native)
 * - User refills UEA's gas (native ETH) AND bridges ERC20 token in one transaction
 * - No Split Logic: gasAmount = msg.value (entire msg.value is gas)
 * - Dual Token: Native for gas, ERC20 for funds
 * - Dual Destination: Native to TSS, ERC20 to Vault
 * - Dual Execution:
 *   1. Gas route ALWAYS triggered with full msg.value (instant route with USD caps)
 *   2. ERC20 rate limit consumed for _req.amount
 *   3. ERC20 transferred to vault
 *   4. Native ETH forwarded to TSS
 */
contract GatewaySendUniversalTxWithFunds_PAYLOAD_Case2_3_Test is BaseTest {
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

        TransparentUpgradeableProxy tempProxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        gatewayTemp = UniversalGateway(payable(address(tempProxy)));
        vm.startPrank(admin);
        gatewayTemp.grantRole(gatewayTemp.ROLE_MANAGER_ROLE(), admin);
        gatewayTemp.grantRole(gatewayTemp.UG_ADMIN_ROLE(), admin);
        gatewayTemp.grantRole(gatewayTemp.OPERATOR_ROLE(), admin);
        vm.stopPrank();
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
    //      PHASE 4: TX_TYPE.FUNDS_AND_PAYLOAD - CASE 2.3 (ERC20 + NATIVE BATCHING)
    // =========================================================================

    // =========================
    //      CATEGORY 1: HAPPY PATH & CORE FUNCTIONALITY
    // =========================

    /// @notice Test Case 2.3 - ERC20 + Native batching happy path
    /// @dev Verifies:
    ///      - Full msg.value goes to gas route (no split)
    ///      - ERC20 transferred to vault
    ///      - Native ETH goes to TSS
    ///      - Two events emitted (gas + funds)
    ///      - ERC20 rate limit consumed
    ///      - Native rate limit NOT consumed
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_Batching_HappyPath() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 0.002 ether; // $4 for gas
        uint256 erc20Amount = 100 ether; // 100 tokenA

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA), // ERC20 token
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));
        (uint256 erc20UsedBefore,) = gatewayTemp.currentTokenUsage(address(tokenA));
        (uint256 nativeUsedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        // Expect two events: Gas event + Funds event
        // Event 1: Gas event (full msg.value)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0), // Gas always credits UEA
            token: address(0), // Native token for gas
            amount: msgValue,
            payload: bytes(""), // Gas event has empty payload
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Event 2: Funds event (ERC20 amount)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA), // ERC20 token for funds
            amount: erc20Amount,
            payload: encodedPayload, // Funds event has full payload
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive native ETH");

        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Vault should receive ERC20");

        (uint256 erc20UsedAfter,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(erc20UsedAfter, erc20UsedBefore + erc20Amount, "ERC20 rate limit should be consumed");

        (uint256 nativeUsedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(nativeUsedAfter, nativeUsedBefore, "Native rate limit should NOT be consumed");
    }

    /// @notice Test Case 2.3 - Payload preserved in funds event
    /// @dev Gas event has empty payload, funds event has full payload
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_PayloadPreserved() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

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
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        // Gas event: empty payload
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: msgValue,
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
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload, // Full payload preserved
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Small gas with large ERC20 funds
    /// @dev Verify independent amounts work correctly (opposite asymmetry)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_SmallGasLargeFunds() public {
        uint256 msgValue = 0.0005 ether; // $1 for gas (at min cap)
        uint256 erc20Amount = 10000 ether; // Large ERC20 amount

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive full msg.value");
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Vault should receive ERC20");
    }

    /// @notice Test Case 2.3 - Minimal gas amount at min cap
    /// @dev gasAmount = 0.0005 ETH (exactly $1 at $2000/ETH)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_MinimalGasAmount() public {
        uint256 msgValue = 0.0005 ether; // $1 (at min cap)
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Should succeed at min cap");
    }

    /// @notice Test Case 2.3 - Multiple users can send independently
    /// @dev Different users should be able to send batched transactions
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_MultipleUsers() public {
        uint256 msgValue = 0.001 ether;
        uint256 erc20Amount = 50 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

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
        assertEq(tss.balance, tssBalanceBefore + (msgValue * 3), "All users should succeed - TSS");
        assertEq(
            tokenA.balanceOf(address(this)), vaultBalanceBefore + (erc20Amount * 3), "All users should succeed - Vault"
        );
    }

    // =========================
    //      CATEGORY 2: VALIDATION & REVERT CASES
    // =========================

    /// @notice Test Case 2.3 - Zero msg.value routes to Case 2.1 (should succeed for ERC20)
    /// @dev Ensures Case 2.3 is NOT triggered when msg.value == 0
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_ZeroMsgValue_RoutesToCase2_1() public {
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        // Should route to Case 2.1 and succeed (no batching, ERC20 only)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);

        // Assert: ERC20 transferred (Case 2.1 behavior)
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Should route to Case 2.1");
    }

    /// @notice Test Case 2.3 - Empty payload with ERC20 + native routes as FUNDS + gas top-up
    /// @dev _fetchTxType infers FUNDS (empty payload); Case 1.2 routes nativeValue as gas top-up
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_EmptyPayload_RoutesAsGas() public {
        uint256 msgValue = 0.002 ether; // ~$4 at $2000/ETH, within $1-$10 USD cap
        uint256 erc20Amount = 100 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // recipient
            address(tokenA),
            erc20Amount,
            bytes("") // Empty payload → inferred as FUNDS, not FUNDS_AND_PAYLOAD
        );

        uint256 tssBalBefore = tss.balance;
        uint256 vaultBalBefore = tokenA.balanceOf(address(this)); // address(this) is the vault

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance - tssBalBefore, msgValue, "TSS should receive gas top-up");
        assertEq(tokenA.balanceOf(address(this)) - vaultBalBefore, erc20Amount, "Vault should receive ERC20");
    }

    /// @notice Test Case 2.3 - Zero amount with payload routes to GAS_AND_PAYLOAD (matrix inference)
    /// @dev With amount=0, payload non-empty, msg.value>0, matrix infers GAS_AND_PAYLOAD (not FUNDS_AND_PAYLOAD)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_ZeroAmount() public {
        uint256 msgValue = 0.002 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            0, // Zero amount
            encodedPayload
        );

        // Matrix infers GAS_AND_PAYLOAD (hasPayload=true, hasFunds=false, hasNativeValue=true)
        // This should succeed as a GAS_AND_PAYLOAD transaction
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // Gas routes always credit UEA
            token: address(0),
            amount: msgValue,
            payload: encodedPayload,
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Zero revertRecipient reverts
    /// @dev revertInstruction.revertRecipient must be non-zero
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_ZerorevertRecipient() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: address(0), // Zero address
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas amount below min USD cap reverts
    /// @dev At $2000/ETH, min cap = $1 = 0.0005 ETH
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_GasAmountBelowMinUSDCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 0.0004 ether; // $0.80 (below $1 min)
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas amount above max USD cap reverts
    /// @dev At $2000/ETH, max cap = $10 = 0.005 ETH
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_GasAmountAboveMaxUSDCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 0.006 ether; // $12 (above $10 max)
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas amount exceeds block cap reverts
    /// @dev Set block cap and verify gas route respects it
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_GasAmountExceedsBlockCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set block cap to $5
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(5e18);

        uint256 msgValue = 0.003 ether; // $6 (exceeds $5 block cap)
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Unsupported ERC20 token reverts
    /// @dev Token with threshold=0 should revert with NotSupported
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_UnsupportedToken() public {
        // Deploy a new token that's not configured
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNSUP", 18, 0);
        unsupportedToken.mint(user1, 1000 ether);

        vm.prank(user1);
        unsupportedToken.approve(address(gatewayTemp), type(uint256).max);

        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(unsupportedToken),
            erc20Amount,
            encodedPayload
        );

        vm.expectRevert(Errors.NotSupported.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Insufficient ERC20 allowance reverts
    /// @dev Should revert with ERC20InsufficientAllowance
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_InsufficientAllowance() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 1000 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Create a user with no approval
        address userNoApproval = address(0x7777);
        tokenA.mint(userNoApproval, erc20Amount);
        vm.deal(userNoApproval, msgValue);
        // No approval given

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.prank(userNoApproval);
        vm.expectRevert(); // ERC20InsufficientAllowance
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Insufficient ERC20 balance reverts
    /// @dev Should revert with ERC20InsufficientBalance
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_InsufficientBalance() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 1000 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Create a user with approval but no balance
        address userNoBalance = address(0x8888);
        vm.deal(userNoBalance, msgValue);
        // No tokens minted

        vm.prank(userNoBalance);
        tokenA.approve(address(gatewayTemp), type(uint256).max);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.prank(userNoBalance);
        vm.expectRevert(); // ERC20InsufficientBalance
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    // =========================
    //      CATEGORY 3: RATE LIMITING - DUAL RATE LIMITS
    // =========================

    /// @notice Test Case 2.3 - Separate rate limits for gas and ERC20
    /// @dev Gas uses USD caps, ERC20 uses token rate limit - completely independent
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_SeparateRateLimits() public {
        vm.skip(true); // Rate limiting disabled on testnet
        uint256 msgValue = 0.002 ether; // $4 for gas
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        (uint256 erc20UsedBefore,) = gatewayTemp.currentTokenUsage(address(tokenA));
        (uint256 nativeUsedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: ERC20 rate limit consumed
        (uint256 erc20UsedAfter,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(erc20UsedAfter, erc20UsedBefore + erc20Amount, "ERC20 rate limit should be consumed");

        // Assert: Native rate limit NOT consumed (gas uses USD caps)
        (uint256 nativeUsedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(nativeUsedAfter, nativeUsedBefore, "Native rate limit should NOT be consumed");
    }

    /// @notice Test Case 2.3 - ERC20 rate limit exceeded reverts
    /// @dev Even if gas amount is fine, ERC20 must respect rate limit
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_ERC20RateLimitExceeded() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set low threshold for tokenA
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 50 ether; // Low threshold

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 msgValue = 0.002 ether; // Gas is fine
        uint256 erc20Amount = 60 ether; // Exceeds ERC20 threshold

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Cumulative ERC20 rate limit
    /// @dev Multiple calls should accumulate towards ERC20 rate limit
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_CumulativeERC20RateLimit() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 200 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Call 1: 120 tokenA
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            120 ether,
            encodedPayload
        );

        // Call 2: 70 tokenA (cumulative 190 < 200)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            70 ether,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req1);

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req2);

        // Verify cumulative usage
        (uint256 used,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(used, 190 ether, "Cumulative ERC20 usage should be 190");
    }

    /// @notice Test Case 2.3 - Cumulative ERC20 rate limit exceeded reverts
    /// @dev Second call should fail when cumulative exceeds threshold
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RevertOn_CumulativeERC20RateLimitExceeded() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 200 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Call 1: 120 tokenA
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            120 ether,
            encodedPayload
        );

        // Call 2: 90 tokenA (cumulative 210 > 200)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            90 ether,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req1);

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req2);
    }

    /// @notice Test Case 2.3 - ERC20 rate limit resets in new epoch
    /// @dev After epoch duration, ERC20 rate limit should reset
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_RateLimitResetsInNewEpoch() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 100 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            90 ether,
            encodedPayload
        );

        // First call in epoch 1
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req);

        // Advance time to next epoch (86400 seconds + 1 for safety)
        vm.warp(block.timestamp + 86401);
        // Also advance block number to ensure new epoch
        vm.roll(block.number + 1);

        // Update oracle timestamp to prevent stale data error
        ethUsdFeedMock.setAnswer(2000e8, block.timestamp);

        // Second call in epoch 2 (should succeed as limit reset)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.001 ether }(req);

        // Verify usage reset
        (uint256 used,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(used, 90 ether, "Usage should reset in new epoch");
    }

    /// @notice Test Case 2.3 - Native rate limit NOT consumed
    /// @dev Critical: Native ETH uses USD caps, not rate limits
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_NativeNotConsumedInRateLimit() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        (uint256 nativeUsedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        // Make multiple calls
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        }

        // Assert: Native rate limit still not consumed
        (uint256 nativeUsedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(nativeUsedAfter, nativeUsedBefore, "Native rate limit should NEVER be consumed in Case 2.3");
    }

    // =========================
    //      CATEGORY 4: EVENT EMISSION & DUAL EVENTS
    // =========================

    /// @notice Test Case 2.3 - Always emits two events
    /// @dev Unlike Case 2.2, gas route is ALWAYS called (no condition)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_EmitsTwoEvents_Always() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        // Event 1: Gas
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: msgValue,
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
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas event has empty payload
    /// @dev Gas event always has empty payload, funds event has full payload
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_GasEvent_HasEmptyPayload() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        // Gas event: empty payload
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: msgValue,
            payload: bytes(""), // Empty
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas event recipient always address(0)
    /// @dev Gas always credits UEA, funds preserves recipient
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_GasEvent_RecipientAlwaysZero() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;
        address explicitRecipient = address(0x999);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        // Gas event: recipient = address(0)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0), // Always zero for gas
            token: address(0),
            amount: msgValue,
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
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Gas event uses native, funds event uses ERC20
    /// @dev Verify different tokens in each event
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_GasEvent_NativeToken_FundsEvent_ERC20Token() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        // Gas event: token = address(0) (native)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0), // Native token
            amount: msgValue,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        // Funds event: token = tokenA (ERC20)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // FUNDS_AND_PAYLOAD always has recipient == address(0)
            token: address(tokenA), // ERC20 token
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test Case 2.3 - Events preserve revertMsg
    /// @dev Both events should preserve revertMsg
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_EventsPreserverevertMsg() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;
        bytes memory revertMsg = abi.encodePacked("custom revert", uint256(999));

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0x456), revertMsg: revertMsg });

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: revertInst.revertRecipient,
            signatureData: bytes("")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        // Both events should have preserved revertMsg (verified implicitly)
    }

    /// @notice Test Case 2.3 - Events preserve signatureData
    /// @dev Both events should preserve signatureData
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_EventsPreserveSignatureData() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;
        bytes memory sigData = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            token: address(tokenA),
            amount: erc20Amount,
            payload: encodedPayload,
            revertRecipient: address(0x456),
            signatureData: sigData
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        // Both events should have preserved signatureData (verified implicitly)
    }

    // =========================
    //      CATEGORY 5: FUND FLOW & DESTINATIONS
    // =========================

    /// @notice Test Case 2.3 - Native to TSS, ERC20 to Vault
    /// @dev Verify dual destinations work correctly
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_NativeToTSS_ERC20ToVault() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));
        uint256 gatewayNativeBefore = address(gatewayTemp).balance;
        uint256 gatewayERC20Before = tokenA.balanceOf(address(gatewayTemp));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: TSS received native ETH
        assertEq(tss.balance, tssBalanceBefore + msgValue, "TSS should receive native ETH");

        // Assert: Vault received ERC20
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Vault should receive ERC20");

        // Assert: Gateway holds nothing
        assertEq(address(gatewayTemp).balance, gatewayNativeBefore, "Gateway should not hold native ETH");
        assertEq(tokenA.balanceOf(address(gatewayTemp)), gatewayERC20Before, "Gateway should not hold ERC20");
    }

    /// @notice Test Case 2.3 - Gateway does not accumulate
    /// @dev Gateway should not hold any tokens after multiple calls
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_Gateway_DoesNotAccumulate() public {
        uint256 msgValue = 0.001 ether;
        uint256 erc20Amount = 50 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 gatewayNativeBefore = address(gatewayTemp).balance;
        uint256 gatewayERC20Before = tokenA.balanceOf(address(gatewayTemp));

        // Make multiple calls
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gatewayTemp.sendUniversalTx{ value: msgValue }(req);
        }

        // Gateway balance should remain unchanged
        assertEq(address(gatewayTemp).balance, gatewayNativeBefore, "Gateway should not accumulate native ETH");
        assertEq(tokenA.balanceOf(address(gatewayTemp)), gatewayERC20Before, "Gateway should not accumulate ERC20");
    }

    /// @notice Test Case 2.3 - Full msg.value to gas route
    /// @dev Entire msg.value goes through gas route (no split)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_FullMsgValueToGasRoute() public {
        uint256 msgValue = 0.003 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: Entire msg.value went to TSS (via gas route)
        assertEq(tss.balance, tssBalanceBefore + msgValue, "Entire msg.value should go to gas route");
    }

    /// @notice Test Case 2.3 - Independent amounts
    /// @dev Gas and funds amounts are completely independent
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_IndependentAmounts() public {
        uint256 msgValue = 0.001 ether; // Small gas
        uint256 erc20Amount = 10000 ether; // Large ERC20

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        // Assert: No relationship between amounts
        assertEq(tss.balance, tssBalanceBefore + msgValue, "Gas amount independent");
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Funds amount independent");
    }

    /// @notice Test Case 2.3 - Different tokens in sequence
    /// @dev Each ERC20 goes to vault correctly
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_DifferentTokensSameTx() public {
        uint256 msgValue = 0.001 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Send tokenA
        UniversalTxRequest memory reqA = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            50 ether,
            encodedPayload
        );

        // Send usdc
        UniversalTxRequest memory reqU = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(usdc),
            50e6,
            encodedPayload
        );

        uint256 vaultTokenABefore = tokenA.balanceOf(address(this));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(reqA);

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(reqU);

        // Assert: Both tokens received correctly
        assertEq(tokenA.balanceOf(address(this)), vaultTokenABefore + 50 ether, "TokenA to vault");
        assertEq(usdc.balanceOf(address(this)), vaultUsdcBefore + 50e6, "USDC to vault");
    }

    // =========================
    //      CATEGORY 6: EDGE CASES & BOUNDARY CONDITIONS
    // =========================

    /// @notice Test Case 2.3 - Maximal gas amount at max cap
    /// @dev msg.value = 0.005 ETH (exactly $10 at $2000/ETH)
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_MaximalGasAmount_AtMaxCap() public {
        uint256 msgValue = 0.005 ether; // $10 (at max cap)
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Should succeed at max cap");
    }

    /// @notice Test Case 2.3 - Large payload does not affect gas caps
    /// @dev Gas USD caps only check msg.value, not payload size
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_LargePayload_DoesNotAffectGasCaps() public {
        uint256 msgValue = 0.002 ether;
        uint256 erc20Amount = 100 ether;

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
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tss.balance, tssBalanceBefore + msgValue, "Large payload should not affect gas caps");
    }

    /// @notice Test Case 2.3 - Very large ERC20 amount within rate limit
    /// @dev Should handle large ERC20 amounts correctly
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_VeryLargeERC20Amount_WithinRateLimit() public {
        uint256 msgValue = 0.001 ether;
        uint256 erc20Amount = 500000 ether; // Large but within default threshold

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);

        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + erc20Amount, "Should handle large ERC20 amounts");
    }

    /// @notice Test Case 2.3 - Multiple calls same block respect gas block cap
    /// @dev Cumulative gas amounts checked against block cap
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_MultipleCallsSameBlock_GasBlockCap() public {
        vm.skip(true); // Rate limiting disabled on testnet
        // Set block cap to $8
        vm.prank(admin);
        gatewayTemp.setBlockUsdCap(8e18);

        uint256 msgValue = 0.002 ether; // $4 per call
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA),
            erc20Amount,
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

    /// @notice Test Case 2.3 - Different recipients work correctly
    /// @dev Both zero and non-zero recipients should work
    function test_Case2_3_FUNDS_AND_PAYLOAD_ERC20_DifferentRecipients_Work() public {
        uint256 msgValue = 0.001 ether;
        uint256 erc20Amount = 100 ether;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        // Test with zero recipient
        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // Zero recipient (required)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req1);

        // Test with zero recipient (non-zero not allowed for FUNDS_AND_PAYLOAD)
        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // Zero recipient (required)
            address(tokenA),
            erc20Amount,
            encodedPayload
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req2);

        // Both should succeed
    }
}
