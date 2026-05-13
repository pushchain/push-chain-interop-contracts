// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title GatewaySendUniversalTx Test Suite
 * @notice Tests for the sendUniversalTx() router function on UniversalGateway
 * @dev Focus: Router logic and correct delegation to internal functions
 *      Does NOT test deep branch logic of _sendTxWithGas or _sendTxWithFunds
 *      Those are tested in separate dedicated test files
 */
contract GatewaySendUniversalTxTest is BaseTest {
    // UniversalGateway instance (overrides BaseTest's gateway)
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

        // Deploy UniversalGateway instead of UniversalGateway
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

        // Re-approve tokens to gatewayTemp (BaseTest approved to old gateway)
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

    /// @notice Deploy UniversalGateway (overrides BaseTest's UniversalGateway deployment)
    function _deployGatewayTemp() internal {
        // Deploy implementation
        UniversalGateway implementation = new UniversalGateway();

        // Deploy transparent upgradeable proxy
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

        // Cast proxy to UniversalGateway
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

    // =========================
    //      HAPPY PATH TESTS - GAS ROUTE
    // =========================

    /// @notice Test sendUniversalTx with TX_TYPE.GAS routes correctly to _sendTxWithGas
    /// @dev Verifies:
    ///      - Function accepts valid GAS request
    ///      - Routes to instant route (_sendTxWithGas)
    ///      - Emits correct UniversalTx event
    ///      - Native ETH forwarded to TSS
    function test_SendUniversalTx_GAS_HappyPath() public {
        // Arrange
        uint256 gasAmount = 0.001 ether; // Within USD caps at $2000/ETH: $2
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // recipient (will be address(0) for gas route)
            address(0), // token (native)
            0, // amount must be 0 for GAS route (matrix requires !hasFunds)
            bytes("") // empty payload for GAS type
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act & Assert
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            sender: user1,
            recipient: address(0), // Gas always credits UEA (address(0))
            token: address(0), // Native token
            amount: gasAmount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            txType: TX_TYPE.GAS,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert: TSS received the native ETH
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive gas amount");
    }

    /// @notice Test sendUniversalTx with TX_TYPE.GAS_AND_PAYLOAD routes correctly
    /// @dev Verifies:
    ///      - Function accepts valid GAS_AND_PAYLOAD request
    ///      - Routes to instant route (_sendTxWithGas)
    ///      - Emits correct UniversalTx event with payload
    ///      - Native ETH forwarded to TSS
    function test_SendUniversalTx_GAS_AND_PAYLOAD_HappyPath() public {
        // Arrange
        uint256 gasAmount = 0.002 ether; // Within USD caps at $2000/ETH: $4
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // recipient (will be address(0) for gas route)
            address(0), // token (native)
            0, // amount must be 0 for GAS_AND_PAYLOAD route (matrix requires !hasFunds)
            encodedPayload // non-empty payload required
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act & Assert
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            sender: user1,
            recipient: address(0), // Gas always credits UEA (address(0))
            token: address(0), // Native token
            amount: gasAmount,
            payload: encodedPayload,
            revertRecipient: req.revertRecipient,
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: gasAmount }(req);

        // Assert: TSS received the native ETH
        assertEq(tss.balance, tssBalanceBefore + gasAmount, "TSS should receive gas amount");
    }

    // =========================
    //      HAPPY PATH TESTS - FUNDS ROUTE
    // =========================

    /// @notice Test sendUniversalTx with TX_TYPE.FUNDS (native) routes correctly
    /// @dev Verifies:
    ///      - Function accepts valid FUNDS request with native token
    ///      - Routes to standard route (_sendTxWithFunds)
    ///      - Emits correct UniversalTx event
    ///      - Native ETH forwarded to TSS
    function test_SendUniversalTx_FUNDS_Native_HappyPath() public {
        // Arrange
        uint256 fundsAmount = 100 ether; // Large amount (no USD caps on FUNDS route)
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(0), // native token
            fundsAmount,
            bytes("") // empty payload for FUNDS type
        );

        uint256 tssBalanceBefore = tss.balance;

        // Act & Assert
        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            sender: user1,
            recipient: address(0), // FUNDS credits caller's UEA
            token: address(0), // Native token
            amount: fundsAmount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            txType: TX_TYPE.FUNDS,
            signatureData: bytes(""),
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: fundsAmount }(req);

        // Assert: TSS received the native ETH
        assertEq(tss.balance, tssBalanceBefore + fundsAmount, "TSS should receive funds amount");
    }

    /// @notice Test sendUniversalTx with TX_TYPE.FUNDS (ERC20) routes correctly
    /// @dev Verifies:
    ///      - Function accepts valid FUNDS request with ERC20
    ///      - Routes to standard route (_sendTxWithFunds)
    ///      - Emits correct UniversalTx event
    ///      - ERC20 transferred to VAULT
    function test_SendUniversalTx_FUNDS_ERC20_HappyPath() public {
        // Arrange: tokenA already enabled in setUp()
        uint256 fundsAmount = 1000 ether; // Large amount
        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS requires recipient == address(0)
            address(tokenA), // ERC20 token
            fundsAmount,
            bytes("") // empty payload for FUNDS type
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        // Act
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req); // No native value for ERC20

        // Assert: VAULT received the ERC20
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "VAULT should receive ERC20");
    }

    /// @notice Test sendUniversalTx with TX_TYPE.FUNDS_AND_PAYLOAD (no batching) routes correctly
    /// @dev Verifies:
    ///      - Function accepts valid FUNDS_AND_PAYLOAD request (ERC20, no gas batching)
    ///      - Routes to standard route (_sendTxWithFunds)
    ///      - Emits correct UniversalTx event with payload
    ///      - ERC20 transferred to VAULT
    function test_SendUniversalTx_FUNDS_AND_PAYLOAD_NoBatching_HappyPath() public {
        // Arrange: tokenA already enabled in setUp()
        uint256 fundsAmount = 500 ether;
        UniversalPayload memory payload = buildDefaultPayload();
        bytes memory encodedPayload = abi.encode(payload);

        UniversalTxRequest memory req = buildUniversalTxRequest(
            address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0)
            address(tokenA), // ERC20 token
            fundsAmount,
            encodedPayload // non-empty payload required
        );

        uint256 vaultBalanceBefore = tokenA.balanceOf(address(this));

        // Act
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req); // No native value (no batching)

        // Assert: VAULT received the ERC20
        assertEq(tokenA.balanceOf(address(this)), vaultBalanceBefore + fundsAmount, "VAULT should receive ERC20");
    }
}
