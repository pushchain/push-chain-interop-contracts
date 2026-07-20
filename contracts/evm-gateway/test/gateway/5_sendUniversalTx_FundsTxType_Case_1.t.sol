// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockFeeOnTransferERC20 } from "../mocks/MockFeeOnTransferERC20.sol";

/**
 * @title GatewaySendUniversalTxWithFunds Test Suite
 * @notice Comprehensive tests for FUNDS route (standard route) via sendUniversalTx
 * @dev Tests FUNDS and FUNDS_AND_PAYLOAD transaction types with focus on:
 *      All paths are exercised through sendUniversalTx() which internally routes to the standard route.
 *      Phase 1: TX_TYPE.FUNDS (native and ERC20)
 *      Phase 2: TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.1 (No batching)
 *      Phase 3: TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.2 (Native batching)
 *      Phase 4: TX_TYPE.FUNDS_AND_PAYLOAD - Case 2.3 (ERC20 + native batching)
 *
 * Current Implementation: Phase 1 - TX_TYPE.FUNDS
 */
contract GatewaySendUniversalTxWithFundsTest is BaseTest {
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
    //      PHASE 1: TX_TYPE.FUNDS TESTS
    // =========================================================================

    // =========================
    //      D1.1: NATIVE FUNDS (Case 1.1)
    // =========================

    /// @notice Test FUNDS with native token - happy path
    /// @dev Verifies:
    ///      - Native token forwarded to TSS
    ///      - Rate limit consumed correctly
    ///      - Event emitted with correct parameters
    ///      - Recipient must be address(0) for FUNDS type
    function test_SendTxWithFunds_FUNDS_Native_HappyPath() public {
        uint256 fundsAmount = 100 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0), // Native token
            fundsAmount,
            bytes("") // Empty payload for FUNDS
        );

        uint256 tssBalanceBefore = tss.balance;
        (uint256 usedBefore,) = gatewayTemp.currentTokenUsage(address(0));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0), // FUNDS always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: _pp(bytes("")),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        assertEq(tss.balance, tssBalanceBefore + fundsAmount, "TSS should receive native funds");

        (uint256 usedAfter,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(usedAfter, usedBefore + fundsAmount, "Rate limit should be consumed");
    }

    /// @notice Test FUNDS with native token - recipient can be zero
    /// @dev Unlike GAS routes, FUNDS allows zero recipient ( zero recipients = UEA on Push Chain)
    function test_SendTxWithFunds_FUNDS_Native_AllowsZeroRecipient() public {
        uint256 fundsAmount = 50 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // Zero recipient is allowed for FUNDS
            address(0), // Native token
            fundsAmount,
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        assertEq(tss.balance, tssBalanceBefore + fundsAmount, "TSS should receive funds even with zero recipient");
    }

    /// @notice Test FUNDS native - msg.value must equal amount
    /// @dev Revert if msg.value != amount
    function test_SendTxWithFunds_FUNDS_Native_RevertOn_MsgValueMismatch_TooLow() public {
        uint256 fundsAmount = 100 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 50 ether }(req); // msg.value < amount
    }

    /// @notice Test FUNDS native - zero amount reverts
    /// @dev Amount must be > 0
    function test_SendTxWithFunds_FUNDS_Native_RevertOn_ZeroAmount() public {
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            0, // Zero amount
            bytes("")
        );

        vm.expectRevert(Errors.InvalidInput.selector); // _fetchTxType throws InvalidInput for invalid combinations
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test FUNDS native - rate limit enforcement
    /// @dev Should revert when exceeding threshold
    function test_SendTxWithFunds_FUNDS_Native_RevertOn_RateLimitExceeded() public {
        // Set a low threshold for native token
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 100 ether; // Low threshold

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 fundsAmount = 150 ether; // Exceeds threshold

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);
    }

    /// @notice Test FUNDS native - cumulative rate limit exceeded
    /// @dev Third call should fail when cumulative exceeds threshold
    function test_SendTxWithFunds_FUNDS_Native_RevertOn_CumulativeRateLimitExceeded() public {
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 200 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 firstAmount = 120 ether;
        uint256 secondAmount = 90 ether; // Total 210 ether (exceeds 200)

        UniversalTxRequest memory req1 = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            firstAmount,
            bytes("")
        );

        UniversalTxRequest memory req2 = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            secondAmount,
            bytes("")
        );

        // First call succeeds
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: firstAmount }(req1);

        // Second call fails (cumulative 210 > 200)
        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: secondAmount }(req2);
    }

    /// @notice Test FUNDS native - rate limit resets in new epoch
    /// @dev After epoch duration, rate limit should reset
    function test_SendTxWithFunds_FUNDS_Native_RateLimitResetsInNewEpoch() public {
        // Set threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0);
        thresholds[0] = 100 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 fundsAmount = 90 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("")
        );

        // First call in epoch 1
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // Verify usage
        (uint256 usedEpoch1,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(usedEpoch1, fundsAmount, "Usage in epoch 1");

        // Advance time to next epoch (default epoch duration is 86400 seconds / 1 day)
        vm.warp(block.timestamp + 86400);

        // Second call in epoch 2 (should succeed as limit reset)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // Verify usage reset
        (uint256 usedEpoch2,) = gatewayTemp.currentTokenUsage(address(0));
        assertEq(usedEpoch2, fundsAmount, "Usage should reset in new epoch");
    }

    /// @notice Test FUNDS native - gateway does not accumulate ETH
    /// @dev All native ETH should be forwarded to TSS
    function test_SendTxWithFunds_FUNDS_Native_GatewayDoesNotAccumulate() public {
        uint256 fundsAmount = 100 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("")
        );

        uint256 gatewayBalanceBefore = address(gatewayTemp).balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // Gateway balance should remain unchanged
        assertEq(address(gatewayTemp).balance, gatewayBalanceBefore, "Gateway should not hold native ETH");
    }

    // =========================
    //      D1.2: ERC20 FUNDS (Case 1.2)
    // =========================

    /// @notice Test FUNDS with ERC20 - happy path
    /// @dev Verifies:
    ///      - ERC20 transferred to vault
    ///      - Rate limit consumed correctly
    ///      - Event emitted with correct parameters
    ///      - Recipient must be address(0) for FUNDS type
    function test_SendTxWithFunds_FUNDS_ERC20_HappyPath() public {
        uint256 fundsAmount = 1000 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA), // ERC20 token
            fundsAmount,
            bytes("")
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));
        (uint256 usedBefore,) = gatewayTemp.currentTokenUsage(address(tokenA));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0), // FUNDS always has recipient == address(0)
            token: address(tokenA),
            amount: fundsAmount,
            payload: _pp(bytes("")),
            revertRecipient: req.revertRecipient,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req); // No native value for ERC20

        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "Vault should receive ERC20");

        (uint256 usedAfter,) = gatewayTemp.currentTokenUsage(address(tokenA));
        assertEq(usedAfter, usedBefore + fundsAmount, "Rate limit should be consumed");
    }

    /// @notice Test FUNDS with ERC20 + msg.value > 0 routes excess native as gas top-up
    /// @dev Post-fee native is forwarded via _sendTxWithGas; ERC20 bridge proceeds normally
    function test_SendTxWithFunds_FUNDS_ERC20_WithNativeValue_RoutesAsGas() public {
        uint256 fundsAmount = 1000 ether;
        uint256 gasTopUp = 0.003 ether; // ~$6 at $2000/ETH, within $1-$10 USD cap

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            bytes("")
        );

        uint256 tssBalBefore = tss.balance;
        uint256 vaultBalBefore = tokenA.balanceOf(address(this)); // address(this) is the vault

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasTopUp }(req);

        assertEq(tss.balance - tssBalBefore, gasTopUp, "TSS should receive gas top-up");
        assertEq(tokenA.balanceOf(address(this)) - vaultBalBefore, fundsAmount, "Vault should receive ERC20");
    }

    /// @notice Test FUNDS with ERC20 - unsupported token reverts
    /// @dev Token with threshold=0 should revert with NotSupported
    function test_SendTxWithFunds_FUNDS_ERC20_RevertOn_UnsupportedToken() public {
        // Deploy a new token that's not configured
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNSUP", 18, 0);
        unsupportedToken.mint(user1, 1000 ether);

        vm.prank(user1);
        unsupportedToken.approve(address(gatewayTemp), type(uint256).max);

        uint256 fundsAmount = 100 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(unsupportedToken),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(Errors.NotSupported.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test FUNDS with ERC20 - insufficient allowance reverts
    /// @dev Should revert with ERC20InsufficientAllowance
    function test_SendTxWithFunds_FUNDS_ERC20_RevertOn_InsufficientAllowance() public {
        uint256 fundsAmount = 1000 ether;

        // Create a user with no approval
        address userNoApproval = address(0x7777);
        tokenA.mint(userNoApproval, fundsAmount);
        // No approval given

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(); // ERC20InsufficientAllowance
        vm.prank(userNoApproval);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test FUNDS with ERC20 - insufficient balance reverts
    /// @dev Should revert with ERC20InsufficientBalance
    function test_SendTxWithFunds_FUNDS_ERC20_RevertOn_InsufficientBalance() public {
        uint256 fundsAmount = 1000 ether;

        // Create a user with approval but no balance
        address userNoBalance = address(0x8888);
        // No tokens minted

        vm.prank(userNoBalance);
        tokenA.approve(address(gatewayTemp), type(uint256).max);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(); // ERC20InsufficientBalance
        vm.prank(userNoBalance);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test FUNDS with ERC20 - rate limit enforcement
    /// @dev Should revert when exceeding threshold
    function test_SendTxWithFunds_FUNDS_ERC20_RevertOn_RateLimitExceeded() public {
        // Set a low threshold for tokenA
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 500 ether; // Low threshold

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 fundsAmount = 600 ether; // Exceeds threshold

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            fundsAmount,
            bytes("")
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test FUNDS with ERC20 - different tokens have separate rate limits
    /// @dev tokenA and usdc should have independent rate limits
    function test_SendTxWithFunds_FUNDS_ERC20_SeparateRateLimitsPerToken() public {
        // Set thresholds
        address[] memory tokens = new address[](2);
        uint256[] memory thresholds = new uint256[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(usdc);
        thresholds[0] = 500 ether;
        thresholds[1] = 500e6; // USDC has 6 decimals

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        uint256 tokenAAmount = 400 ether;
        uint256 usdcAmount = 400e6;

        UniversalTxRequest memory reqA = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA),
            tokenAAmount,
            bytes("")
        );

        UniversalTxRequest memory reqU = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(usdc),
            usdcAmount,
            bytes("")
        );

        // Send tokenA
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(reqA);

        // Send usdc (should succeed - separate limit)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(reqU);

        // Verify separate usage tracking
        (uint256 usedA,) = gatewayTemp.currentTokenUsage(address(tokenA));
        (uint256 usedU,) = gatewayTemp.currentTokenUsage(address(usdc));
        assertEq(usedA, tokenAAmount, "TokenA usage");
        assertEq(usedU, usdcAmount, "USDC usage");
    }

    // =========================
    //      D1.3: VALIDATION TESTS (Common to both native and ERC20)
    // =========================

    /// @notice Test FUNDS - payload must be empty
    /// @dev Non-empty payload should revert
    function test_SendTxWithFunds_FUNDS_RevertOn_NonEmptyPayload() public {
        uint256 fundsAmount = 100 ether;
        bytes memory nonEmptyPayload = abi.encode(buildDefaultPayload());

        UniversalTxRequest memory req = buildUniversalTxRequest(
            // This field is ignored - matrix will infer FUNDS_AND_PAYLOAD
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            nonEmptyPayload // Has payload - matrix will route to FUNDS_AND_PAYLOAD (Case 2.2)
        );

        // Should succeed - matrix routes to FUNDS_AND_PAYLOAD (native batching)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);
    }

    /// @notice Test FUNDS - revertInstruction.revertRecipient must be non-zero
    /// @dev Zero revertRecipient should revert
    function test_SendTxWithFunds_FUNDS_RevertOn_ZerorevertRecipient() public {
        uint256 fundsAmount = 100 ether;

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS requires recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: bytes(""),
            revertRecipient: address(0), // Zero address not allowed
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);
    }

    /// @notice Test FUNDS - multiple users can send independently
    /// @dev Different users should be able to send funds independently
    function test_SendTxWithFunds_FUNDS_MultipleUsersIndependent() public {
        uint256 fundsAmount = 50 ether;

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0),
            fundsAmount,
            bytes("")
        );

        uint256 tssBalanceBefore = tss.balance;

        // user1 sends
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // user2 sends
        vm.prank(user2);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // user3 sends
        vm.prank(user3);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // Assert: All succeeded
        assertEq(tss.balance, tssBalanceBefore + (fundsAmount * 3), "All users should succeed");
    }

    /// @notice Test FUNDS - event preserves revertMsg
    /// @dev revertMsg should be emitted correctly
    function test_SendTxWithFunds_FUNDS_EventPreservesrevertMsg() public {
        uint256 fundsAmount = 100 ether;
        bytes memory revertMsg = abi.encodePacked("custom revert data", uint256(12345));

        RevertInstructions memory revertInst =
            RevertInstructions({ revertRecipient: address(0x999), revertMsg: revertMsg });

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0), // FUNDS requires recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: bytes(""),
            revertRecipient: revertInst.revertRecipient,
            signatureData: bytes("")
        });

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0), // FUNDS always has recipient == address(0)
            token: address(0),
            amount: fundsAmount,
            payload: _pp(bytes("")),
            revertRecipient: revertInst.revertRecipient, // Full struct with revertMsg
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);
    }

    // ============================================================
    //  _handleDeposits — Unsupported ERC20 Token (threshold == 0)
    // ============================================================

    /// @notice FUNDS with an ERC20 whose tokenToLimitThreshold == 0 reverts NotSupported
    function test_SendTxWithFunds_UnsupportedERC20_Reverts() public {
        MockERC20 unsupported = new MockERC20("Unsupported", "UNS", 18, 0);
        unsupported.mint(user1, 1000 ether);
        vm.prank(user1);
        unsupported.approve(address(gatewayTemp), type(uint256).max);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(unsupported),
            amount: 100 ether,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gatewayTemp.sendUniversalTx(req);
    }

    // ============================================================
    //  _handleDeposits — Fee-on-transfer token rejection
    // ============================================================

    /// @notice FUNDS deposit of a whitelisted fee-on-transfer ERC20 must revert InvalidAmount.
    /// @dev    Without the balance-before/after check, the Vault would receive less than `amount`
    ///         and the gateway's accounting/rate-limit/event emission would reference a phantom
    ///         amount that the Vault does not actually hold.
    function test_SendTxWithFunds_FeeOnTransferERC20_Reverts() public {
        // 2% fee-on-transfer token.
        MockFeeOnTransferERC20 fotToken = new MockFeeOnTransferERC20("FeeOnTransfer", "FOT", 200);
        fotToken.mint(user1, 1000 ether);
        vm.prank(user1);
        fotToken.approve(address(gatewayTemp), type(uint256).max);

        // Whitelist the token so the threshold check passes; the fee-on-transfer guard is the
        // actual gate we want to hit.
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(fotToken);
        thresholds[0] = 1_000_000 ether;
        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(fotToken),
            amount: 100 ether,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        uint256 vaultBalBefore = fotToken.balanceOf(address(this));

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gatewayTemp.sendUniversalTx(req);

        // Vault balance must be unchanged — the revert unwinds the partial transfer.
        assertEq(fotToken.balanceOf(address(this)), vaultBalBefore, "vault must hold zero fot tokens");
    }
}
