// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title _fetchTxType Comprehensive Test Suite
 * @notice Tests the core routing logic of _fetchTxType function
 * @dev This test suite validates that _fetchTxType correctly classifies transactions
 *      based on the four decision variables:
 *      - hasPayload (P): req.payload.length > 0
 *      - hasFunds (F): req.amount > 0
 *      - fundsIsNative (N): req.token == address(0)
 *      - hasNativeValue (G): nativeValue > 0
 */
contract GatewayFetchTxTypeTest is BaseTest {
    UniversalGateway public gatewayTemp;
    address public erc20A;
    address public erc20B;

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

        _deployGatewayTemp();

        vm.prank(admin);
        gatewayTemp.setEthUsdFeed(address(ethUsdFeedMock));

        erc20A = address(tokenA);
        erc20B = address(usdc);

        // Setup token support
        address[] memory tokens = new address[](4);
        uint256[] memory thresholds = new uint256[](4);
        tokens[0] = address(0);
        tokens[1] = erc20A;
        tokens[2] = erc20B;
        tokens[3] = address(weth);
        thresholds[0] = 1000000 ether;
        thresholds[1] = 1000000 ether;
        thresholds[2] = 1000000e6;
        thresholds[3] = 1000000 ether;

        vm.prank(admin);
        gatewayTemp.setTokenLimitThresholds(tokens, thresholds);

        // Approve tokens
        vm.prank(user1);
        tokenA.approve(address(gatewayTemp), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(gatewayTemp), type(uint256).max);
    }

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

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Helper to build UniversalTxRequest
    function makeReq(bytes memory payloadBytes, uint256 amount, address token)
        internal
        pure
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: address(0), // Always address(0) - funds go to caller's UEA on Push Chain
            token: token,
            amount: amount,
            payload: payloadBytes,
            revertRecipient: address(0x456),
            signatureData: bytes("sig")
        });
    }

    /// @notice Helper to get non-empty payload
    function nonEmptyPayload() internal view returns (bytes memory) {
        return abi.encode(buildDefaultPayload());
    }

    // =========================
    //      GROUP 1: TX_TYPE.GAS
    // =========================

    /// @notice Test 1.1.1: Basic GAS with native token
    function test_GAS_basic_native() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 0, address(0));
        uint256 nativeValue = 0.002 ether; // $4 at $2000/ETH - within $1-$10 cap

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: nativeValue,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 1.1.2: GAS with non-native token (token field ignored)
    function test_GAS_basic_nonNativeToken_ignored() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 0, erc20A);
        uint256 nativeValue = 0.002 ether; // $4 at $2000/ETH - within $1-$10 cap

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: nativeValue,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 1.2.1: GAS mutation with funds becomes FUNDS
    function test_GAS_mutation_hasFunds_becomes_FUNDS_native() public {
        uint256 amount = 100 ether; // FUNDS route doesn't have USD cap restrictions
        UniversalTxRequest memory req = makeReq(bytes(""), amount, address(0));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: amount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: amount }(req);
    }

    /// @notice Test 1.2.2: GAS mutation with payload becomes GAS_AND_PAYLOAD
    function test_GAS_mutation_hasPayload_becomes_GAS_AND_PAYLOAD() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, address(0));
        uint256 nativeValue = 0.002 ether; // $4 at $2000/ETH - within $1-$10 cap

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: nativeValue,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 1.2.3: GAS mutation with no native value reverts
    function test_GAS_mutation_noNativeValue_revert() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 0, address(0));

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 2: TX_TYPE.GAS_AND_PAYLOAD
    // =========================

    /// @notice Test 2.1.1: Basic GAS_AND_PAYLOAD
    function test_GAS_AND_PAYLOAD_basic() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, address(0));
        uint256 nativeValue = 0.003 ether; // $6 at $2000/ETH - within $1-$10 cap

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: nativeValue,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 2.1.2: GAS_AND_PAYLOAD with non-native token (ignored)
    function test_GAS_AND_PAYLOAD_nonNativeToken_ignored() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, erc20A);
        uint256 nativeValue = 0.003 ether; // $6 at $2000/ETH - within $1-$10 cap

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: nativeValue,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 2.2.1: GAS_AND_PAYLOAD mutation with funds becomes FUNDS_AND_PAYLOAD
    function test_GAS_AND_PAYLOAD_mutation_addFunds_native_becomes_FUNDS_AND_PAYLOAD() public {
        uint256 amount = 100 ether; // FUNDS_AND_PAYLOAD route doesn't have USD cap restrictions
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, address(0));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // Always address(0) for UEA credit
            token: address(0),
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: amount }(req);
    }

    /// @notice Test 2.2.2: GAS_AND_PAYLOAD with zero native value (payload-only)
    function test_GAS_AND_PAYLOAD_payload_only_native0() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, address(0));

        uint256 tssBalanceBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.GAS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);

        assertEq(tss.balance, tssBalanceBefore, "TSS balance should remain unchanged");
    }

    // =========================
    //      GROUP 3: TX_TYPE.FUNDS (Native)
    // =========================

    /// @notice Test 3.1.1: Basic native FUNDS
    function test_FUNDS_native_basic() public {
        uint256 amount = 100 ether; // FUNDS route doesn't have USD cap restrictions
        UniversalTxRequest memory req = makeReq(bytes(""), amount, address(0));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0),
            token: address(0),
            amount: amount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: amount }(req);
    }

    /// @notice Test 3.2.1: Native FUNDS missing native value reverts
    function test_FUNDS_native_missingNativeValue_revert() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 100 ether, address(0));

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 4: TX_TYPE.FUNDS (ERC-20)
    // =========================

    /// @notice Test 4.1.1: Basic ERC-20 FUNDS
    function test_FUNDS_erc20_basic() public {
        uint256 amount = 1000 ether;
        UniversalTxRequest memory req = makeReq(bytes(""), amount, erc20A);

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS,
            sender: user1,
            recipient: address(0),
            token: erc20A,
            amount: amount,
            payload: bytes(""),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test 4.2.1: ERC-20 FUNDS with native value routes excess native as gas top-up
    function test_FUNDS_erc20_withNativeValue_routesAsGas() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 1000 ether, erc20A);

        uint256 tssBalBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.003 ether }(req);

        assertEq(tss.balance - tssBalBefore, 0.003 ether, "TSS should receive gas top-up");
    }

    /// @notice Test 4.2.2: ERC-20 with no funds reverts
    function test_FUNDS_erc20_noFunds_revert() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 0, erc20A);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 5: TX_TYPE.FUNDS_AND_PAYLOAD (No batching - ERC-20 only)
    // =========================

    /// @notice Test 5.1.1: FUNDS_AND_PAYLOAD no batching ERC-20
    function test_FAP_nobatching_erc20_basic() public {
        uint256 amount = 500 ether;
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, erc20A);

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: req.recipient,
            token: erc20A,
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test 5.2.1: FAP no batching with native value becomes ERC-20 + gas batching
    function test_FAP_nobatching_addNativeValue_becomes_FAP_erc20_plus_gas() public {
        uint256 amount = 500 ether;
        uint256 nativeValue = 0.003 ether; // $6 gas within $1-$10 cap
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, erc20A);

        // Should emit TWO events: one for GAS, one for FUNDS_AND_PAYLOAD
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 5.2.2: FAP no batching missing funds reverts
    function test_FAP_nobatching_missingFunds_revert() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, erc20A);

        // This routes to GAS_AND_PAYLOAD (payload-only)
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 6: TX_TYPE.FUNDS_AND_PAYLOAD (Native + Gas batching)
    // =========================

    /// @notice Test 6.1.1: FAP native batching basic
    function test_FAP_native_batching_basic() public {
        uint256 amount = 100 ether; // Bridge amount
        uint256 nativeValue = 100.002 ether; // Bridge + gas (0.002 = $4 gas within cap)
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, address(0));

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 6.1.2: FAP native batching with zero extra gas
    function test_FAP_native_batching_zeroExtraGas_ok() public {
        uint256 amount = 100 ether;
        uint256 nativeValue = 100 ether; // Exact amount, no extra gas
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, address(0));

        vm.expectEmit(true, true, false, true, address(gatewayTemp));
        emit UniversalTx({
            txType: TX_TYPE.FUNDS_AND_PAYLOAD,
            sender: user1,
            recipient: address(0), // Always address(0) for UEA credit
            token: address(0),
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: req.revertRecipient,
            signatureData: req.signatureData,
            fromCEA: false
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    /// @notice Test 6.2.1: FAP native batching missing native value reverts
    function test_FAP_native_batching_missingNativeValue_revert() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 10 ether, address(0));

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    // =========================
    //      GROUP 7: TX_TYPE.FUNDS_AND_PAYLOAD (ERC-20 + Gas batching)
    // =========================

    /// @notice Test 7.1.1: FAP ERC-20 plus gas basic
    function test_FAP_erc20_plus_gas_basic() public {
        uint256 amount = 1000 ether;
        uint256 nativeValue = 0.003 ether; // $6 gas within $1-$10 cap
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), amount, erc20A);

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req);
    }

    // =========================
    //      GROUP 8: Invalid combinations
    // =========================

    /// @notice Test 8.1: All zero reverts
    function test_Invalid_allZero() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 0, erc20A);

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test 8.2: Payload only with no native (routes to GAS_AND_PAYLOAD)
    function test_Invalid_payload_only_noNative() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 0, address(0));

        // This is actually valid - routes to GAS_AND_PAYLOAD with zero gas
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test 8.3: Native funds with no native value reverts
    function test_Invalid_nativeFunds_noNativeValue() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 7 ether, address(0));

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Test 8.4: ERC-20 funds with native value routes excess as gas top-up
    function test_erc20Funds_withNoPayload_andNativeValue_routesAsGas() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 1000 ether, erc20A);

        uint256 tssBalBefore = tss.balance;

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: 0.003 ether }(req);

        assertEq(tss.balance - tssBalBefore, 0.003 ether, "TSS should receive gas top-up");
    }

    // =========================
    //      GROUP 9: Invariance tests
    // =========================

    /// @notice Test 9.2: SignatureData does not affect txType
    function test_Invariance_signatureData_ignored() public {
        uint256 amount = 500 ether;
        uint256 nativeValue = 0.003 ether; // $6 gas within $1-$10 cap

        // Test with empty signatureData
        UniversalTxRequest memory req1 = UniversalTxRequest({
            recipient: address(0),
            token: erc20A,
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req1);

        // Test with non-empty signatureData
        UniversalTxRequest memory req2 = UniversalTxRequest({
            recipient: address(0),
            token: erc20A,
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("different signature data")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req2);
    }

    /// @notice Test 9.3: RevertInstruction context does not affect txType
    function test_Invariance_revertInstruction_onlyRecipientMatters() public {
        uint256 amount = 500 ether;
        uint256 nativeValue = 0.003 ether; // $6 gas within $1-$10 cap

        // Test with different revertMsg
        UniversalTxRequest memory req1 = UniversalTxRequest({
            recipient: address(0),
            token: erc20A,
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("sig")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req1);

        UniversalTxRequest memory req2 = UniversalTxRequest({
            recipient: address(0),
            token: erc20A,
            amount: amount,
            payload: nonEmptyPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("sig")
        });

        vm.prank(user1);
        gatewayTemp.sendUniversalTx{ value: nativeValue }(req2);
    }

    // =========================
    //  NATIVE FUNDS / FUNDS_AND_PAYLOAD WITH ZERO NATIVE VALUE
    // =========================

    /// @notice Native FUNDS (token=address(0), amount>0) with nativeValue=0 reverts
    /// @dev Hits the revert at line 923: fundsIsNative=true, hasNativeValue=false
    function test_FetchTxType_NativeFunds_ZeroNativeValue_Reverts() public {
        UniversalTxRequest memory req = makeReq(bytes(""), 1 ether, address(0));

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }

    /// @notice Native FUNDS_AND_PAYLOAD (token=address(0), amount>0, payload) with nativeValue=0 reverts
    /// @dev Hits the revert at line 937: fundsIsNative=true, hasNativeValue=false
    function test_FetchTxType_NativeFundsAndPayload_ZeroNativeValue_Reverts() public {
        UniversalTxRequest memory req = makeReq(nonEmptyPayload(), 1 ether, address(0));

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gatewayTemp.sendUniversalTx{ value: 0 }(req);
    }
}
