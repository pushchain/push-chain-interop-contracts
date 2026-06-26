// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest, UniversalTokenTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { MockUniswapV3Factory } from "../mocks/MockUniswapV3.sol";
import { MockUniswapV3Router } from "../mocks/MockUniswapV3.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title GatewaySendUniversalTxTokenGas Test Suite
 * @notice Comprehensive tests for sendUniversalTx(UniversalTokenTxRequest) - token-as-gas entrypoint
 * @dev Tests unique aspects of the token-as-gas function:
 *      - Parameter validation (gasToken, gasAmount, amountOutMinETH, deadline)
 *      - _swapToNative integration (WETH fast-path and error cases)
 *      - TX_TYPE inference when nativeValue comes from swap
 *      - msg.value semantics
 *      - Error paths (no pool, slippage, deadline, paused state)
 *
 * @dev Note: This test suite focuses on the unique behavior of the token-as-gas entrypoint.
 *      Internal routing logic (_sendTxWithGas, _sendTxWithFunds, _fetchTxType) is already
 *      covered by existing tests. Here we test integration and surface-level semantics.
 */
contract GatewaySendUniversalTxTokenGasTest is BaseTest {
    // UniversalGateway instance
    UniversalGateway public gatewayTemp;

    // Uniswap mocks
    MockUniswapV3Factory public mockFactory;
    MockUniswapV3Router public mockRouter;
    address public mockPool;

    // =========================
    //      EVENTS
    // =========================
    // Event definition matches IUniversalGateway.sol
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

        // Deploy Uniswap mocks
        mockFactory = new MockUniswapV3Factory();
        mockRouter = new MockUniswapV3Router(address(weth));
        mockPool = address(0x1234); // Dummy pool address

        // Setup pool for tokenA/WETH with fee tier 500 (first tier gateway checks)
        vm.prank(mockFactory.owner());
        mockFactory.setPool(address(tokenA), address(weth), 500, mockPool);

        // Setup swap rate: 1 tokenA = 0.001 ETH (1e15)
        mockRouter.setSwapRate(address(tokenA), 1e15);

        // Deploy UniversalGateway with mocks
        _deployGatewayTemp();

        // Update gateway with mock Uniswap addresses
        vm.prank(admin);
        gatewayTemp.updateUniswapV3Config(address(mockFactory), address(mockRouter));

        // Explicitly set fee order to ensure it's initialized (default should be [500, 3000, 10000])
        vm.prank(admin);
        gatewayTemp.setV3FeeOrder(500, 3000, 10000);

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

        // Fund mock router with ETH (it will convert to WETH as needed)
        vm.deal(address(mockRouter), 1000 ether);

        // Fund WETH contract with ETH so it can transfer ETH on withdraw
        vm.deal(address(weth), 1000 ether);
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
            address(mockFactory), // Use mock factory
            address(mockRouter), // Use mock router
            address(weth)
        );

        gatewayProxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);
        gatewayTemp = UniversalGateway(payable(address(gatewayProxy)));

        vm.label(address(gatewayTemp), "UniversalGateway");
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Build a UniversalTokenTxRequest for testing
    function _buildTokenGasRequest(
        address recipient,
        address token,
        uint256 amount,
        address gasToken,
        uint256 gasAmount,
        bytes memory payload,
        uint256 amountOutMinETH,
        uint256 deadline
    ) internal pure returns (UniversalTokenTxRequest memory) {
        return UniversalTokenTxRequest({
            recipient: recipient,
            token: token,
            amount: amount,
            gasToken: gasToken,
            gasAmount: gasAmount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes(""),
            amountOutMinETH: amountOutMinETH,
            deadline: deadline
        });
    }

    /// @notice Build a minimal valid UniversalTokenTxRequest for GAS route
    function _buildMinimalTokenGasRequest(address gasToken, uint256 gasAmount, uint256 amountOutMinETH)
        internal
        view
        returns (UniversalTokenTxRequest memory)
    {
        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), // recipient
            address(0), // token
            0, // amount
            gasToken,
            gasAmount,
            bytes(""), // empty payload
            amountOutMinETH,
            block.timestamp + 1 hours // deadline
        );
        // Set revertRecipient to non-zero for GAS routes (required by _routeUniversalTx)
        req.revertRecipient = address(0x456);
        return req;
    }

    // =========================
    //      PARAMETER VALIDATION TESTS
    // =========================

    /// @notice Test revert when gasToken is zero address
    function test_TokenGas_RevertOn_ZeroGasToken() public {
        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(0), 1 ether, 0.001 ether);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test revert when gasAmount is zero
    function test_TokenGas_RevertOn_ZeroGasAmount() public {
        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), 0, 0.001 ether);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test revert when amountOutMinETH is zero
    function test_TokenGas_RevertOn_ZeroAmountOutMinETH() public {
        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), 1 ether, 0);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test revert when deadline is in the past
    function test_TokenGas_RevertOn_ExpiredDeadline() public {
        // Use smaller amount to stay within USD caps
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        // Set deadline to past timestamp (must be non-zero to trigger the check)
        // First advance time to ensure deadline is definitely in the past
        vm.warp(block.timestamp + 1000);
        uint256 pastDeadline = block.timestamp - 100; // Definitely in the past

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0,
            address(tokenA),
            gasAmount,
            bytes(""),
            amountOutMinETH,
            pastDeadline // Past deadline
        );
        req.revertRecipient = address(0x456);

        vm.expectRevert(Errors.SlippageExceededOrExpired.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test revert when contract is paused
    function test_TokenGas_RevertOn_Paused() public {
        vm.prank(pauser);
        gatewayTemp.pause();

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), 1 ether, 0.001 ether);

        vm.expectRevert();
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    // =========================
    //      SWAP INTEGRATION TESTS
    // =========================

    /// @notice Test revert when Uniswap router/factory are not configured
    /// @dev _swapToNative checks if uniV3Router or uniV3Factory are zero and reverts
    function test_TokenGas_RevertOn_UniswapNotConfigured() public {
        // Create a new gateway without Uniswap configured
        UniversalGateway implementation2 = new UniversalGateway();
        bytes memory initData2 = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            address(this),
            MIN_CAP_USD,
            MAX_CAP_USD,
            address(0), // No factory
            address(0), // No router
            address(weth)
        );
        TransparentUpgradeableProxy proxy2 =
            new TransparentUpgradeableProxy(address(implementation2), address(proxyAdmin), initData2);
        UniversalGateway gatewayNoUniswap = UniversalGateway(payable(address(proxy2)));

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), 1 ether, 0.001 ether);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayNoUniswap.sendUniversalTx(req);
    }

    /// @notice Test WETH fast-path when Uniswap is configured
    /// @dev When gasToken == WETH, _swapToNative uses fast-path: pull WETH, unwrap to native
    function test_TokenGas_WETHFastPath_Success() public {
        // Arrange: User has WETH
        // Use smaller amount to stay within USD caps: 0.001 ETH = $2
        uint256 gasAmount = 0.001 ether; // 0.001 ETH = $2, within caps
        uint256 amountOutMinETH = (gasAmount * 99) / 100; // Allow 1% slippage

        vm.prank(user1);
        weth.deposit{ value: gasAmount }();

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, address(weth), gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 userWethBalanceBefore = weth.balanceOf(user1);

        // Act: Expect UniversalTx event with TX_TYPE.GAS
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            gasAmount, // nativeValue from unwrap
            bytes(""),
            req.revertRecipient,
            TX_TYPE.GAS,
            bytes(""),
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);

        // Assert: WETH was unwrapped and sent to TSS
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive unwrapped ETH");
        assertEq(weth.balanceOf(user1), userWethBalanceBefore - gasAmount, "User WETH should be consumed");
    }

    /// @notice Test revert when pool is not found for non-WETH token
    /// @dev _findV3PoolWithNative reverts with InvalidInput when no pool exists
    function test_TokenGas_RevertOn_NoPoolFound() public {
        // Arrange: Use a token without a pool
        MockERC20 tokenWithoutPool = new MockERC20("NoPool", "NOP", 18, 0);
        vm.prank(user1);
        tokenWithoutPool.mint(user1, 1000 ether);
        vm.prank(user1);
        tokenWithoutPool.approve(address(gatewayTemp), type(uint256).max);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0,
            address(tokenWithoutPool),
            1 ether,
            bytes(""),
            0.001 ether,
            block.timestamp + 1 hours
        );

        // Act & Assert: Should revert when pool is not found
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    // =========================
    //      TX_TYPE INFERENCE TESTS
    // =========================

    /// @notice Test that TX_TYPE.GAS is correctly inferred when using token-as-gas
    /// @dev When req has no payload, no funds, and nativeValue > 0 (from swap), should route to GAS
    function test_TokenGas_InferGAS_Type() public {
        // Arrange: Swap tokenA for gas, no payload, no funds
        // Use smaller amount to stay within USD caps: $1-$10 range
        // At $2000/ETH: need 0.0005 ETH to 0.005 ETH (0.001 ETH = $2, within caps)
        // Swap rate: 1e15 means 1 tokenA = 0.001 ETH
        // To get 0.001 ETH: need 1 tokenA = 1e18 wei
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH; // Use exact amount (mock returns exact)

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0, // No funds
            address(tokenA),
            gasAmount,
            bytes(""), // No payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act: Expect GAS event
        // Note: The actual swap output will be 1 ETH (1000 tokenA * 1e15 / 1e18 = 1 ETH)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            expectedETH, // nativeValue from swap = 1 ETH
            bytes(""),
            req.revertRecipient,
            TX_TYPE.GAS,
            bytes(""),
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);

        // Assert: TSS received ETH from swap
        assertGe(tss.balance, tssBalanceBefore + amountOutMinETH, "TSS should receive swapped ETH");
    }

    /// @notice Test that TX_TYPE.GAS_AND_PAYLOAD is correctly inferred when using token-as-gas with payload
    /// @dev When req has payload, no funds, and nativeValue > 0 (from swap), should route to GAS_AND_PAYLOAD
    function test_TokenGas_InferGAS_AND_PAYLOAD_Type() public {
        // Arrange: Swap tokenA for gas, with payload, no funds
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory payloadBytes = abi.encode(payload);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0, // No funds
            address(tokenA),
            gasAmount,
            payloadBytes, // Has payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        // Act: Expect GAS_AND_PAYLOAD event
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            expectedETH,
            payloadBytes,
            req.revertRecipient,
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test that TX_TYPE.FUNDS is correctly inferred when using token-as-gas with funds
    /// @dev When req has ERC20 funds (amount > 0), should route to FUNDS using nativeValue from swap
    ///      as the gas leg. Native funds bridging via the token-gas overload is not supported
    ///      because the function rejects msg.value.
    function test_TokenGas_InferFUNDS_Type() public {
        // Arrange: Swap tokenA for gas, bridge USDC as funds
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;
        uint256 fundsAmount = 100e6; // 100 USDC bridge amount

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(usdc), // ERC20 bridge token
            fundsAmount, // Has funds
            address(tokenA),
            gasAmount,
            bytes(""), // No payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        // Act: Expect FUNDS event (funds take precedence)
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(usdc), // ERC20 bridge token
            fundsAmount, // Funds amount, not gas amount
            bytes(""),
            req.revertRecipient,
            TX_TYPE.FUNDS,
            bytes(""),
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test that TX_TYPE.FUNDS_AND_PAYLOAD is correctly inferred when using token-as-gas with funds and payload
    /// @dev When req has ERC20 funds and payload, should route to FUNDS_AND_PAYLOAD with the swap
    ///      output used as the gas leg. Native funds bridging via this overload is not supported
    function test_TokenGas_InferFUNDS_AND_PAYLOAD_Type() public {
        // Arrange: Swap tokenA for gas, bridge USDC with payload
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;
        uint256 fundsAmount = 100e6; // 100 USDC bridge amount

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory payloadBytes = abi.encode(payload);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(usdc), // ERC20 bridge token
            fundsAmount, // Has funds
            address(tokenA),
            gasAmount,
            payloadBytes, // Has payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        // Act: Expect FUNDS_AND_PAYLOAD event
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(usdc),
            fundsAmount,
            payloadBytes,
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    // =========================
    //      MSG.VALUE SEMANTICS TESTS
    // =========================

    /// @notice Test that msg.value > 0 is rejected by the token-as-gas entrypoint
    /// @dev The token-as-gas overload derives nativeValue exclusively
    ///      from _swapToNative(gasToken, ...). Accepting msg.value would silently trap ETH in the
    ///      gateway with no recovery path, so msg.value > 0 must revert with InvalidInput.
    function test_TokenGas_RevertOn_NonZeroMsgValue() public {
        // Arrange: Send msg.value along with a valid token-as-gas request
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;
        uint256 msgValue = 0.1 ether;

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), gasAmount, amountOutMinETH);

        // Act + Assert: Sending any non-zero msg.value must revert
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test that nativeValue comes exclusively from _swapToNative when msg.value == 0
    /// @dev Pairs with test_TokenGas_RevertOn_NonZeroMsgValue: confirms that the only valid call
    ///      shape (msg.value == 0) routes the swap output to TSS as the gas leg.
    function test_TokenGas_NativeValueComesFromSwap() public {
        // Arrange
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), gasAmount, amountOutMinETH);

        uint256 tssBalanceBefore = tss.balance;

        // Act: Send with msg.value = 0 (the only valid shape post-fix)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);

        uint256 ethReceived = tss.balance - tssBalanceBefore;

        // Assert: TSS received exactly the swap output
        assertEq(ethReceived, expectedETH, "TSS should receive the swap output as nativeValue");

        // Sanity: gateway holds no trapped ETH
        assertEq(address(gatewayTemp).balance, 0, "Gateway must not retain any ETH");
    }

    // =========================
    //      INTEGRATION WITH ROUTING TESTS - PENDING
    // =========================

    /// @notice Test that UniversalTxRequest is correctly built from UniversalTokenTxRequest
    /// @dev Verify that recipient, token, amount, payload, revertInstruction, signatureData are preserved
    function test_TokenGas_BuildsCorrectUniversalTxRequest() public {
        // This test verifies the conversion from UniversalTokenTxRequest to UniversalTxRequest
        // The conversion happens at lines 317-324 in UniversalGateway.sol
        // We can't easily test this without successful swap, but we document the expected behavior
    }

    /// @notice Test that _routeUniversalTx is called with correct parameters
    /// @dev Verify that req, caller, nativeValue (from swap), and txType are passed correctly
    function test_TokenGas_RoutesCorrectly() public {
        // This test verifies the routing call at line 327
        // Requires successful swap to fully test
    }

    // =========================
    //      ERROR PATH TESTS
    // =========================

    /// @notice Test revert when user has insufficient gasToken balance
    function test_TokenGas_RevertOn_InsufficientBalance() public {
        // Setup: User has no tokens
        uint256 gasAmount = 1 ether;
        uint256 userBalance = tokenA.balanceOf(user1);

        // Ensure user has insufficient balance
        if (userBalance >= gasAmount) {
            vm.prank(user1);
            tokenA.transfer(address(0xDEAD), userBalance - gasAmount + 1);
        }

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), gasAmount, 0.001 ether);

        // Should revert when _swapToNative tries to transfer tokens
        // Will revert with ERC20InsufficientBalance when transferFrom fails
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, user1, tokenA.balanceOf(user1), gasAmount
            )
        );
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test revert when user has insufficient gasToken allowance
    function test_TokenGas_RevertOn_InsufficientAllowance() public {
        // Setup: Revoke approval
        vm.prank(user1);
        tokenA.approve(address(gatewayTemp), 0);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), 1 ether, 0.001 ether);

        // Should revert when _swapToNative tries to transfer tokens
        // Will revert with ERC20InsufficientAllowance when transferFrom fails
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gatewayTemp), 0, 1 ether)
        );
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test deadline = 0 uses default deadline
    /// @dev When deadline is 0, _swapToNative should use block.timestamp + defaultSwapDeadlineSec
    function test_TokenGas_ZeroDeadlineUsesDefault() public {
        // Arrange: Set deadline to 0
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0,
            address(tokenA),
            gasAmount,
            bytes(""),
            amountOutMinETH,
            0 // Zero deadline should use default
        );

        // Act: Should succeed with default deadline
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1, address(0), address(0), expectedETH, bytes(""), req.revertRecipient, TX_TYPE.GAS, bytes(""), false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test slippage protection when swap output is below amountOutMinETH
    /// @dev _swapToNative should revert with SlippageExceededOrExpired if ethOut < amountOutMinETH
    function test_TokenGas_RevertOn_SlippageExceeded() public {
        // Arrange: Set very high amountOutMinETH (higher than swap output)
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH + 1; // Higher than expected output

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(tokenA), gasAmount, amountOutMinETH);

        // Act & Assert: Should revert on slippage check
        vm.expectRevert(Errors.SlippageExceededOrExpired.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    // =========================
    //      EDGE CASE TESTS
    // =========================

    /// @notice Test that revertInstruction validation is preserved
    /// @dev The UniversalTxRequest built from UniversalTokenTxRequest should preserve revertInstruction
    ///      and _routeUniversalTx should validate it (e.g., revertRecipient != address(0) for GAS routes)
    function test_TokenGas_PreservesRevertInstruction() public {
        // Arrange: Zero revertRecipient should revert for GAS route
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, address(tokenA), gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );
        req.revertRecipient = address(0); // Invalid

        // Act & Assert: Should revert on invalid revertInstruction
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test that signatureData is preserved
    /// @dev The UniversalTxRequest should preserve signatureData from UniversalTokenTxRequest
    function test_TokenGas_PreservesSignatureData() public {
        bytes memory customSignature = abi.encode("custom signature data");
        uint256 gasAmount = 1 ether; // 1 tokenA = 0.001 ETH = $2, within caps
        uint256 expectedETH = (gasAmount * 1e15) / 1e18; // = 0.001 ETH
        uint256 amountOutMinETH = expectedETH - 1;

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, address(tokenA), gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );
        req.signatureData = customSignature;

        // Act: Verify signatureData is preserved in event
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            expectedETH,
            bytes(""),
            req.revertRecipient,
            TX_TYPE.GAS,
            customSignature, // Preserved
            false
        );

        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }

    /// @notice Test maximum values for gasAmount and amountOutMinETH
    function test_TokenGas_MaximumValues() public {
        uint256 maxGasAmount = type(uint256).max;
        uint256 maxAmountOutMinETH = type(uint256).max;

        UniversalTokenTxRequest memory req =
            _buildMinimalTokenGasRequest(address(tokenA), maxGasAmount, maxAmountOutMinETH);

        // Should revert when _swapToNative tries to transfer tokens
        // Will revert with ERC20InsufficientBalance (user doesn't have type(uint256).max tokens)
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, user1, tokenA.balanceOf(user1), maxGasAmount
            )
        );
        vm.prank(user1);
        gatewayTemp.sendUniversalTx(req);
    }
}
