// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTokenTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// USDT interface for non-standard transfer and approve functions
interface TetherToken {
    function transfer(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title GatewaySendUniversalTxTokenGasFork Test Suite
 * @notice Fork-based tests for sendUniversalTx(UniversalTokenTxRequest) - token-as-gas entrypoint
 * @dev Tests using mainnet fork with real Uniswap contracts and real tokens:
 *      - Parameter validation (gasToken, gasAmount, amountOutMinETH, deadline)
 *      - _swapToNative integration with real Uniswap swaps (WETH fast-path and ERC20 swaps)
 *      - TX_TYPE inference when nativeValue comes from swap
 *      - msg.value semantics
 *      - Error paths (no pool, slippage, deadline, paused state)
 *
 * @dev Note: This test suite uses mainnet fork to test real-world integration.
 *      Uses real mainnet tokens (USDC, USDT, DAI, WETH) and real Uniswap V3 pools.
 */
contract GatewaySendUniversalTxTokenGasForkTest is BaseTest {
    // =========================
    //      MAINNET CONTRACTS
    // =========================
    // Mainnet WETH address
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet USDC address
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Mainnet USDT address
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Mainnet DAI address
    address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Mainnet Uniswap V3 Router
    address constant MAINNET_UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Mainnet Uniswap V3 Factory
    address constant MAINNET_UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // Mainnet Chainlink ETH/USD Feed
    address constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Real mainnet token contracts
    IERC20 mainnetWETH;
    IERC20 mainnetUSDC;
    TetherToken mainnetUSDT;
    IERC20 mainnetDAI;

    // UniversalGateway instance for fork tests
    UniversalGateway public gatewayFork;

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
        // Use mainnet fork for Uniswap integration
        // Read RPC URL from ETH_RPC_URL environment variable (must be set in .env file)
        string memory rpcUrl = vm.envString("ETH_MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);
        super.setUp();

        // Redeploy gateway with mainnet WETH address
        _redeployGatewayWithMainnetWETH();

        // Override gateway configuration to use mainnet contracts
        vm.prank(admin);
        gatewayFork.setRouters(MAINNET_UNISWAP_V3_FACTORY, MAINNET_UNISWAP_V3_ROUTER);

        // Initialize real mainnet token contracts
        mainnetWETH = IERC20(MAINNET_WETH);
        mainnetUSDC = IERC20(MAINNET_USDC);
        mainnetUSDT = TetherToken(MAINNET_USDT);
        mainnetDAI = IERC20(MAINNET_DAI);

        // Enable mainnet ERC20 token support for testing
        address[] memory tokens = new address[](5);
        uint256[] memory thresholds = new uint256[](5);
        tokens[0] = address(0); // Native token
        tokens[1] = MAINNET_WETH;
        tokens[2] = MAINNET_USDC;
        tokens[3] = MAINNET_USDT;
        tokens[4] = MAINNET_DAI;
        thresholds[0] = 1000000 ether; // Large threshold for native
        thresholds[1] = 1000000 ether; // Large threshold for WETH
        thresholds[2] = 1000000e6; // Large threshold for USDC (6 decimals)
        thresholds[3] = 1000000e6; // Large threshold for USDT (6 decimals)
        thresholds[4] = 1000000 ether; // Large threshold for DAI (18 decimals)

        vm.prank(admin);
        gatewayFork.setTokenLimitThresholds(tokens, thresholds);

        // Set up Chainlink oracle
        vm.prank(admin);
        gatewayFork.setEthUsdFeed(MAINNET_ETH_USD_FEED);

        // Set the correct fee order for Uniswap V3
        vm.prank(admin);
        gatewayFork.setV3FeeOrder(500, 3000, 10000);
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Redeploy gateway with mainnet WETH address
    function _redeployGatewayWithMainnetWETH() internal {
        // Deploy new implementation
        UniversalGateway newImplementation = new UniversalGateway();

        // Create initialization data with mainnet WETH
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, // admin
            pauser, // pauser
            tss, // tss
            address(this), // vault address
            MIN_CAP_USD,
            MAX_CAP_USD,
            MAINNET_UNISWAP_V3_FACTORY, // Use mainnet factory
            MAINNET_UNISWAP_V3_ROUTER, // Use mainnet router
            MAINNET_WETH // Use mainnet WETH instead of mock
        );

        // Deploy new proxy
        gatewayProxy = new TransparentUpgradeableProxy(address(newImplementation), address(proxyAdmin), initData);

        // Update gateway reference
        gatewayFork = UniversalGateway(payable(address(gatewayProxy)));

        // Label for debugging
        vm.label(address(gatewayFork), "UniversalGateway-Fork");
        vm.label(address(gatewayProxy), "GatewayProxy-Fork");
    }

    /// @notice Fund user with real mainnet tokens by impersonating a whale
    function fundUserWithMainnetTokens(address user, address token, uint256 amount) internal override {
        // Find a whale address that has the token
        address whale;
        if (token == MAINNET_WETH) {
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else if (token == MAINNET_USDC) {
            whale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; // SKY
        } else if (token == MAINNET_USDT) {
            whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC; // Binance 20
        } else if (token == MAINNET_DAI) {
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else {
            revert("Unknown token");
        }

        // Check if whale has enough tokens
        uint256 whaleBalance = IERC20(token).balanceOf(whale);
        require(whaleBalance >= amount, "Whale doesn't have enough tokens");

        // Impersonate whale and transfer tokens
        vm.startPrank(whale);

        // Handle USDT specially since it has non-standard transfer function
        if (token == MAINNET_USDT) {
            // USDT transfer returns void, not bool
            TetherToken(token).transfer(user, amount);
        } else {
            IERC20(token).transfer(user, amount);
        }

        vm.stopPrank();

        // Verify transfer was successful
        assertGe(IERC20(token).balanceOf(user), amount, "User should receive tokens");
    }

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

    /// @notice Calculate expected ETH output from token amount using real market price
    /// @dev Uses gateway's getEthUsdPrice() to calculate expected ETH amount
    ///      This is approximate due to real market slippage
    function _calculateExpectedETH(address token, uint256 tokenAmount) internal view returns (uint256) {
        // Get current ETH/USD price
        (uint256 ethUsdPrice,) = gatewayFork.getEthUsdPrice();

        // For stablecoins (USDC, USDT, DAI), assume 1:1 with USD
        // Calculate USD value, then convert to ETH
        uint256 usdValue;
        if (token == MAINNET_USDC || token == MAINNET_USDT) {
            // 6 decimals: convert to 18 decimals for USD calculation
            usdValue = tokenAmount * 1e12; // Scale from 6 to 18 decimals
        } else if (token == MAINNET_DAI) {
            // 18 decimals: already in correct format
            usdValue = tokenAmount;
        } else {
            // For other tokens, assume 1:1 USD for simplicity
            usdValue = tokenAmount;
        }

        // Convert USD to ETH: ethAmount = (usdValue * 1e18) / ethUsdPrice
        // Apply 5% slippage tolerance for real swaps
        return (usdValue * 95) / 100 / (ethUsdPrice / 1e18);
    }

    // =========================
    //      PARAMETER VALIDATION TESTS
    // =========================

    /// @notice Test revert when gasToken is zero address
    function test_TokenGas_RevertOn_ZeroGasToken() public {
        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(address(0), 1 ether, 0.001 ether);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test revert when gasAmount is zero
    function test_TokenGas_RevertOn_ZeroGasAmount() public {
        fundUserWithMainnetTokens(user1, MAINNET_USDC, 1000e6);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), type(uint256).max);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, 0, 0.001 ether);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test revert when amountOutMinETH is zero
    function test_TokenGas_RevertOn_ZeroAmountOutMinETH() public {
        fundUserWithMainnetTokens(user1, MAINNET_USDC, 1000e6);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), type(uint256).max);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, 10e6, 0);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test revert when deadline is in the past
    function test_TokenGas_RevertOn_ExpiredDeadline() public {
        fundUserWithMainnetTokens(user1, MAINNET_USDC, 1000e6);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), type(uint256).max);

        // Set deadline to past timestamp
        vm.warp(block.timestamp + 1000);
        uint256 pastDeadline = block.timestamp - 100;

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0,
            MAINNET_USDC,
            10e6, // 10 USDC
            bytes(""),
            1e15, // Small min ETH output
            pastDeadline
        );
        req.revertRecipient = address(0x456);

        vm.expectRevert(Errors.SlippageExceededOrExpired.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test revert when contract is paused
    function test_TokenGas_RevertOn_Paused() public {
        vm.prank(pauser);
        gatewayFork.pause();

        fundUserWithMainnetTokens(user1, MAINNET_USDC, 1000e6);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), type(uint256).max);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, 10e6, 0.001 ether);

        vm.expectRevert();
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    // =========================
    //      SWAP INTEGRATION TESTS
    // =========================

    /// @notice Test revert when Uniswap router/factory are not configured
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
            MAINNET_WETH
        );
        TransparentUpgradeableProxy proxy2 =
            new TransparentUpgradeableProxy(address(implementation2), address(proxyAdmin), initData2);
        UniversalGateway gatewayNoUniswap = UniversalGateway(payable(address(proxy2)));

        fundUserWithMainnetTokens(user1, MAINNET_USDC, 1000e6);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayNoUniswap), type(uint256).max);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, 10e6, 0.001 ether);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayNoUniswap.sendUniversalTx(req);
    }

    /// @notice Test WETH fast-path when Uniswap is configured
    /// @dev When gasToken == WETH, _swapToNative uses fast-path: pull WETH, unwrap to native
    function test_TokenGas_WETHFastPath_Success() public {
        // Arrange: User has WETH
        uint256 gasAmount = 0.001 ether; // 0.001 ETH = $2, within caps
        uint256 amountOutMinETH = (gasAmount * 99) / 100; // Allow 1% slippage

        // Fund user with ETH and convert to WETH
        vm.deal(user1, gasAmount);
        vm.prank(user1);
        IWETH(MAINNET_WETH).deposit{ value: gasAmount }();

        vm.prank(user1);
        mainnetWETH.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, MAINNET_WETH, gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );

        uint256 tssBalanceBefore = tss.balance;
        uint256 userWethBalanceBefore = mainnetWETH.balanceOf(user1);

        // Act: Expect UniversalTx event with TX_TYPE.GAS
        vm.expectEmit(true, true, false, true, address(gatewayFork));
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
        gatewayFork.sendUniversalTx(req);

        // Assert: WETH was unwrapped and sent to TSS
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive unwrapped ETH");
        assertEq(mainnetWETH.balanceOf(user1), userWethBalanceBefore - gasAmount, "User WETH should be consumed");
    }

    /// @notice Test revert when pool is not found for non-WETH token
    /// @dev _findV3PoolWithNative reverts with InvalidInput when no pool exists
    function test_TokenGas_RevertOn_NoPoolFound() public {
        // Use a token that doesn't have a WETH pair on Uniswap
        // Create a mock token with no liquidity
        MockERC20 fakeToken = new MockERC20("Fake", "FAKE", 18, 0);
        fakeToken.mint(user1, 1e18);

        vm.prank(user1);
        fakeToken.approve(address(gatewayFork), 1e18);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, address(fakeToken), 1e18, bytes(""), 0.001 ether, block.timestamp + 1 hours
        );

        // Act & Assert: Should revert when pool is not found
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    // =========================
    //      TX_TYPE INFERENCE TESTS
    // =========================

    /// @notice Test that TX_TYPE.GAS is correctly inferred when using token-as-gas
    /// @dev When req has no payload, no funds, and nativeValue > 0 (from swap), should route to GAS
    function test_TokenGas_InferGAS_Type() public {
        // Arrange: Swap USDC for gas, no payload, no funds
        // Use amount that swaps to between $1-$10 worth of ETH (MIN_CAP to MAX_CAP)
        // At ~$3000/ETH: $1 = ~0.00033 ETH, $10 = ~0.0033 ETH
        // Use ~5 USDC to get ~$5 worth of ETH (within caps, accounting for slippage)
        uint256 gasAmount = 5e6; // 5 USDC (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether; // Min output (conservative to allow slippage)

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0, // No funds
            MAINNET_USDC,
            gasAmount,
            bytes(""), // No payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act: Call sendUniversalTx (don't check event as amount is unpredictable from real swap)
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);

        // Assert: TSS received ETH from swap (approximate check)
        assertGt(tss.balance, tssBalanceBefore, "TSS should receive swapped ETH");
        assertGe(tss.balance, tssBalanceBefore + amountOutMinETH, "TSS should receive at least min ETH");
    }

    /// @notice Test that TX_TYPE.GAS_AND_PAYLOAD is correctly inferred when using token-as-gas with payload
    function test_TokenGas_InferGAS_AND_PAYLOAD_Type() public {
        // Arrange: Swap USDC for gas, with payload, no funds
        // Use amount that swaps to between $1-$10 worth of ETH
        uint256 gasAmount = 5e6; // 5 USDC (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether; // Min output (conservative to allow slippage)

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory payloadBytes = abi.encode(payload);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0, // No funds
            MAINNET_USDC,
            gasAmount,
            payloadBytes, // Has payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        // Act: Call sendUniversalTx (don't check event as amount is unpredictable from real swap)
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test that token-as-gas with native funds is rejected at the entrypoint
    /// @dev Per audit fix F-2026-15683, the token-as-gas overload rejects msg.value > 0. Native
    ///      funds bridging is therefore not supported via this overload; users must use the
    ///      UniversalTxRequest overload for native funds. This test documents the new revert path.
    function test_TokenGas_InferFUNDS_Type_RevertsOnMsgValue() public {
        uint256 gasAmount = 100e6; // 100 USDC
        uint256 amountOutMinETH = 0.0003 ether;
        uint256 fundsAmount = 0.001 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0), // Native token
            fundsAmount, // Has funds
            MAINNET_USDC,
            gasAmount,
            bytes(""), // No payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        // Sending msg.value with the token-as-gas overload reverts at the entrypoint check.
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx{ value: fundsAmount }(req);
    }

    /// @notice Test that token-as-gas with native funds + payload is rejected at the entrypoint
    /// @dev Per audit fix F-2026-15683, msg.value > 0 reverts. Native funds via this overload is
    ///      not supported; users must use the UniversalTxRequest overload for native funds.
    function test_TokenGas_InferFUNDS_AND_PAYLOAD_Type_RevertsOnMsgValue() public {
        uint256 gasAmount = 5e6; // 5 USDC
        uint256 amountOutMinETH = 0.0001 ether;
        uint256 fundsAmount = 0.001 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory payloadBytes = abi.encode(payload);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0), // Native token
            fundsAmount, // Has funds
            MAINNET_USDC,
            gasAmount,
            payloadBytes, // Has payload
            amountOutMinETH,
            block.timestamp + 1 hours
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx{ value: fundsAmount }(req);
    }

    // =========================
    //      MSG.VALUE SEMANTICS TESTS
    // =========================

    /// @notice Test that msg.value > 0 is rejected by the token-as-gas entrypoint (audit F-2026-15683)
    function test_TokenGas_RevertOn_NonZeroMsgValue() public {
        uint256 gasAmount = 5e6; // 5 USDC
        uint256 amountOutMinETH = 0.0001 ether;
        uint256 msgValue = 0.1 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, amountOutMinETH);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx{ value: msgValue }(req);
    }

    /// @notice Test that nativeValue comes from _swapToNative when msg.value == 0
    /// @dev Pairs with test_TokenGas_RevertOn_NonZeroMsgValue: confirms the only valid call shape
    ///      (msg.value == 0) routes the swap output to TSS.
    function test_TokenGas_NativeValueComesFromSwap() public {
        uint256 gasAmount = 5e6; // 5 USDC
        uint256 amountOutMinETH = 0.0001 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, amountOutMinETH);

        uint256 tssBalanceBefore = tss.balance;
        uint256 gatewayBalanceBefore = address(gatewayFork).balance;

        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);

        // TSS received at least the slippage-bounded amount from the real swap
        assertGe(tss.balance, tssBalanceBefore + amountOutMinETH, "TSS should receive swapped ETH");
        // Gateway holds no trapped ETH from this call
        assertEq(address(gatewayFork).balance, gatewayBalanceBefore, "Gateway must not retain any ETH");
    }

    // =========================
    //      ERROR PATH TESTS
    // =========================

    /// @notice Test revert when user has insufficient gasToken balance
    function test_TokenGas_RevertOn_InsufficientBalance() public {
        // Setup: User has no tokens
        uint256 gasAmount = 1000e6; // 1000 USDC

        // Don't fund user
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, 0.0003 ether);

        // Should revert when _swapToNative tries to transfer tokens
        // USDC uses old-style string errors, so we check for any revert
        vm.expectRevert();
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test revert when user has insufficient gasToken allowance
    function test_TokenGas_RevertOn_InsufficientAllowance() public {
        // Setup: Fund user but don't approve
        uint256 gasAmount = 100e6; // Use larger amount (test will revert before USD cap check)
        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);

        // Don't approve
        // vm.prank(user1);
        // mainnetUSDC.approve(address(gatewayFork), 0); // Already 0

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, 0.0003 ether);

        // Should revert when _swapToNative tries to transfer tokens
        // USDC uses old-style string errors, so we check for any revert
        vm.expectRevert();
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test deadline = 0 uses default deadline
    function test_TokenGas_ZeroDeadlineUsesDefault() public {
        // Arrange: Set deadline to 0
        uint256 gasAmount = 5e6; // 5 USDC (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0),
            address(0),
            0,
            MAINNET_USDC,
            gasAmount,
            bytes(""),
            amountOutMinETH,
            0 // Zero deadline should use default
        );

        // Act: Should succeed with default deadline (don't check event as amount is unpredictable)
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test slippage protection when swap output is below amountOutMinETH
    function test_TokenGas_RevertOn_SlippageExceeded() public {
        // Arrange: Set very high amountOutMinETH (higher than swap output)
        uint256 gasAmount = 10e6; // 10 USDC
        uint256 amountOutMinETH = 100 ether; // Extremely high min output (will fail)

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, amountOutMinETH);

        // Act & Assert: Should revert on slippage check
        // Uniswap router reverts with "Too little received" string error when slippage is exceeded
        // This happens at the router level before the gateway's slippage check
        vm.expectRevert("Too little received");
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    // =========================
    //      EDGE CASE TESTS
    // =========================

    /// @notice Test that revertInstruction validation is preserved
    function test_TokenGas_PreservesRevertInstruction() public {
        // Arrange: Zero revertRecipient should revert for GAS route
        uint256 gasAmount = 100e6; // Use larger amount to meet USD caps
        uint256 amountOutMinETH = 0.0003 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, MAINNET_USDC, gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );
        req.revertRecipient = address(0); // Invalid

        // Act & Assert: Should revert on invalid revertInstruction
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test that signatureData is preserved
    function test_TokenGas_PreservesSignatureData() public {
        bytes memory customSignature = abi.encode("custom signature data");
        uint256 gasAmount = 5e6; // 5 USDC (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether;

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildTokenGasRequest(
            address(0), address(0), 0, MAINNET_USDC, gasAmount, bytes(""), amountOutMinETH, block.timestamp + 1 hours
        );
        req.signatureData = customSignature;

        // Act: Call sendUniversalTx (don't check event as amount is unpredictable from real swap)
        // Note: signatureData is preserved in the request and will be in the emitted event
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    /// @notice Test maximum values for gasAmount and amountOutMinETH
    function test_TokenGas_MaximumValues() public {
        uint256 maxGasAmount = type(uint256).max;
        uint256 maxAmountOutMinETH = type(uint256).max;

        UniversalTokenTxRequest memory req =
            _buildMinimalTokenGasRequest(MAINNET_USDC, maxGasAmount, maxAmountOutMinETH);

        // Should revert when _swapToNative tries to transfer tokens
        // USDC uses old-style string errors, so we check for any revert
        vm.expectRevert();
        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);
    }

    // =========================
    //      REAL SWAP TESTS WITH VARIOUS TOKENS
    // =========================

    /// @notice Test _swapToNative with USDC
    function test_TokenGas_SwapUSDC_Success() public {
        uint256 gasAmount = 5e6; // 5 USDC (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether; // Min output (conservative to allow slippage)

        fundUserWithMainnetTokens(user1, MAINNET_USDC, gasAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDC, gasAmount, amountOutMinETH);

        uint256 tssBalanceBefore = tss.balance;
        uint256 userBalanceBefore = mainnetUSDC.balanceOf(user1);

        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);

        // Verify user's token balance decreased
        assertEq(mainnetUSDC.balanceOf(user1), userBalanceBefore - gasAmount, "User token balance should decrease");

        // Verify TSS received ETH (approximate check)
        assertGt(tss.balance, tssBalanceBefore, "TSS should receive ETH from token swap");
        assertGe(tss.balance, tssBalanceBefore + amountOutMinETH, "TSS should receive at least min ETH");
    }

    /// @notice Test _swapToNative with USDT
    function test_TokenGas_SwapUSDT_Success() public {
        uint256 gasAmount = 5e6; // 5 USDT (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether; // Min output (conservative to allow slippage)

        fundUserWithMainnetTokens(user1, MAINNET_USDT, gasAmount);
        vm.prank(user1);
        // USDT approve returns void, not bool
        TetherToken(MAINNET_USDT).approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_USDT, gasAmount, amountOutMinETH);

        uint256 tssBalanceBefore = tss.balance;
        uint256 userBalanceBefore = mainnetUSDT.balanceOf(user1);

        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);

        // Verify user's token balance decreased
        assertEq(mainnetUSDT.balanceOf(user1), userBalanceBefore - gasAmount, "User token balance should decrease");

        // Verify TSS received ETH
        assertGt(tss.balance, tssBalanceBefore, "TSS should receive ETH from token swap");
    }

    /// @notice Test _swapToNative with DAI
    function test_TokenGas_SwapDAI_Success() public {
        uint256 gasAmount = 5e18; // 5 DAI (swaps to ~$5 worth of ETH, within $1-$10 caps)
        uint256 amountOutMinETH = 0.0001 ether; // Min output (conservative to allow slippage)

        fundUserWithMainnetTokens(user1, MAINNET_DAI, gasAmount);
        vm.prank(user1);
        mainnetDAI.approve(address(gatewayFork), gasAmount);

        UniversalTokenTxRequest memory req = _buildMinimalTokenGasRequest(MAINNET_DAI, gasAmount, amountOutMinETH);

        uint256 tssBalanceBefore = tss.balance;
        uint256 userBalanceBefore = mainnetDAI.balanceOf(user1);

        vm.prank(user1);
        gatewayFork.sendUniversalTx(req);

        // Verify user's token balance decreased
        assertEq(mainnetDAI.balanceOf(user1), userBalanceBefore - gasAmount, "User token balance should decrease");

        // Verify TSS received ETH
        assertGt(tss.balance, tssBalanceBefore, "TSS should receive ETH from token swap");
    }
}
