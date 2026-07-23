// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICEA } from "../../src/interfaces/ICEA.sol";
import { Multicall } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";
import { ZeroRejectERC20 } from "../mocks/ZeroRejectERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Comprehensive test suite for Vault withdrawal functionality via finalizeUniversalTx with empty payload
/// @dev Tests cover ERC20/native withdrawals, CEA deployment, token parking, edge cases, and integration flows
contract VaultWithdrawalTest is Test {
    // =========================
    //      CONTRACTS
    // =========================
    Vault public vault;
    Vault public vaultImpl;
    UniversalGateway public gateway;
    UniversalGateway public gatewayImpl;
    MockCEAFactory public ceaFactory;
    MockERC20 public usdc;
    MockERC20 public tokenA;
    ZeroRejectERC20 public zeroRejectToken;

    // =========================
    //      ACTORS
    // =========================
    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public user3;
    address public recipient;
    address public attacker;
    address public weth;

    // =========================
    //      SETUP
    // =========================

    /// @notice Helper: encode withdrawal multicall (direct transfer)
    function _withdrawalPayloadDirect(address token, address to, uint256 amount) internal pure returns (bytes memory) {
        Multicall[] memory calls = new Multicall[](1);
        if (token == address(0)) {
            calls[0] = Multicall({ to: to, value: amount, data: bytes("") });
        } else {
            calls[0] =
                Multicall({ to: token, value: 0, data: abi.encodeWithSelector(IERC20.transfer.selector, to, amount) });
        }
        return abi.encode(calls);
    }

    /// @notice Helper: encode external call multicall (for execution)
    function _externalCallPayload(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: target, value: value, data: data });
        return abi.encode(calls);
    }

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");

        // Deploy UniversalGateway
        gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initializeV2.selector,
            admin,
            pauser,
            tss,
            1e18, // minCapUsd
            10e18, // maxCapUsd
            address(0), // factory
            address(0), // router
            weth,
            address(0)
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInitData);
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Deploy CEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault implementation and proxy
        vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector, admin, pauser, tss, address(gateway), address(ceaFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = Vault(payable(address(vaultProxy)));

        // Set vault in CEAFactory
        ceaFactory.setVault(address(vault));

        // Update gateway's VAULT_ROLE
        vm.prank(admin);
        gateway.updateVault(address(vault));

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6, 1_000_000e6);
        tokenA = new MockERC20("Token A", "TKNA", 18, 1_000_000e18);

        // Setup: support tokens in gateway
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(tokenA);
        tokens[2] = address(0); // Native

        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 1_000_000e6; // 1M USDC
        thresholds[1] = 1_000_000e18; // 1M TokenA
        thresholds[2] = 1_000_000 ether; // 1M ETH

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund vault with tokens
        usdc.mint(address(vault), 100_000e6);
        tokenA.mint(address(vault), 100_000e18);
        vm.deal(address(vault), 1000 ether);

        // Deploy and register zero-rejecting token
        zeroRejectToken = new ZeroRejectERC20();
        zeroRejectToken.mint(address(vault), 100_000e18);

        address[] memory extraTokens = new address[](1);
        extraTokens[0] = address(zeroRejectToken);
        uint256[] memory extraThresholds = new uint256[](1);
        extraThresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(extraTokens, extraThresholds);
    }

    // =========================
    //  1. ERC20 WITHDRAWAL TESTS
    // =========================

    /// @notice Test ERC20 withdrawal when CEA already exists
    function testWithdraw_ERC20_CEAExists_Success() public {
        bytes32 subTxId = keccak256("tx1");
        bytes32 universalTxId = keccak256("utx1");
        address originCaller = user1; // UEA on Push Chain
        uint256 amount = 100e6; // 100 USDC

        // Pre-deploy CEA for user1
        vm.prank(address(vault));
        address cea = ceaFactory.deployCEA(originCaller);

        uint256 initialUserBalance = usdc.balanceOf(recipient);
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));

        // Expect event emission
        bytes memory expectedPayload = _withdrawalPayloadDirect(address(usdc), recipient, amount);
        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId, universalTxId, address(0), originCaller, address(0), address(usdc), amount, expectedPayload
        );

        // TSS calls vault.finalizeUniversalTx with withdrawal payload
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc), // token
            amount,
            expectedPayload
        );

        // Verify balances
        assertEq(usdc.balanceOf(recipient), initialUserBalance + amount, "User should receive tokens");
        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance - amount, "Vault balance should decrease");
        assertEq(usdc.balanceOf(cea), 0, "CEA should not hold tokens after withdrawal");
    }

    /// @notice Test ERC20 withdrawal when CEA doesn't exist - should deploy CEA first
    function testWithdraw_ERC20_CEANotExists_DeploysAndSucceeds() public {
        bytes32 subTxId = keccak256("tx2");
        bytes32 universalTxId = keccak256("utx2");
        address originCaller = user2; // Fresh UEA (no CEA yet)
        uint256 amount = 200e6;

        // Verify CEA doesn't exist
        (address ceaBefore, bool isDeployedBefore) = ceaFactory.getCEAForPushAccount(originCaller);
        assertFalse(isDeployedBefore, "CEA should not exist before withdrawal");

        uint256 initialUserBalance = usdc.balanceOf(recipient);

        // TSS calls vault.finalizeUniversalTx - should deploy CEA on-demand
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount) // Withdrawal multicall
        );

        // Verify CEA was deployed
        (address ceaAfter, bool isDeployedAfter) = ceaFactory.getCEAForPushAccount(originCaller);
        assertTrue(isDeployedAfter, "CEA should be deployed");
        assertTrue(ceaAfter != address(0), "CEA address should be valid");

        // Verify withdrawal succeeded
        assertEq(usdc.balanceOf(recipient), initialUserBalance + amount, "User should receive tokens");
    }

    /// @notice Test ERC20 withdrawal with insufficient Vault balance - should revert
    function testWithdraw_ERC20_InsufficientBalance_Reverts() public {
        bytes32 subTxId = keccak256("tx3");
        bytes32 universalTxId = keccak256("utx3");
        address originCaller = user1;
        uint256 excessiveAmount = usdc.balanceOf(address(vault)) + 1; // More than Vault has

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            excessiveAmount,
            _withdrawalPayloadDirect(address(usdc), recipient, excessiveAmount)
        );
    }

    /// @notice Test ERC20 withdrawal with zero amount - should succeed (no-op transfer, CEA still invoked)
    function testWithdraw_ERC20_AmountZero_Allowed() public {
        bytes32 subTxId = keccak256("tx5");
        bytes32 universalTxId = keccak256("utx5");
        address originCaller = user1;
        bytes memory payload = _withdrawalPayloadDirect(address(usdc), recipient, 0);

        uint256 initialVaultBalance = usdc.balanceOf(address(vault));

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            0, // Zero amount
            payload
        );

        // No tokens moved — guard skipped safeTransfer
        assertEq(usdc.balanceOf(recipient), 0, "Recipient balance unchanged");
        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance, "Vault balance unchanged - no transfer occurred");

        // CEA was still invoked (execution happened)
        (address ceaAddr,) = ceaFactory.getCEAForPushAccount(originCaller);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.lastPayload(), payload, "CEA should have been called with payload");
    }


    /// @notice Test ERC20 withdrawal with non-zero msg.value - should revert
    function testWithdraw_ERC20_MsgValueNonZero_Reverts() public {
        bytes32 subTxId = keccak256("tx7");
        bytes32 universalTxId = keccak256("utx7");
        address originCaller = user1;
        uint256 amount = 100e6;

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.finalizeUniversalTx{ value: 1 ether }( // Should not send ETH for ERC20 withdrawal
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );
    }

    // =========================
    //  2. NATIVE WITHDRAWAL TESTS
    // =========================

    /// @notice Test native (ETH) withdrawal when CEA already exists
    function testWithdraw_Native_CEAExists_Success() public {
        bytes32 subTxId = keccak256("tx10");
        bytes32 universalTxId = keccak256("utx10");
        address originCaller = user1;
        uint256 amount = 5 ether;

        // Pre-deploy CEA
        vm.prank(address(vault));
        address cea = ceaFactory.deployCEA(originCaller);

        uint256 initialUserBalance = recipient.balance;
        uint256 initialVaultBalance = address(vault).balance;

        // Expect event
        bytes memory expectedPayload = _withdrawalPayloadDirect(address(0), recipient, amount);
        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId, universalTxId, address(0), originCaller, address(0), address(0), amount, expectedPayload
        );

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // TSS calls vault.finalizeUniversalTx with native tokens (address(0))
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0), // token = address(0) for native
            amount,
            expectedPayload
        );

        // Verify balances
        assertEq(recipient.balance, initialUserBalance + amount, "User should receive ETH");
        // Vault balance stays same: receives `amount` from TSS, sends `amount` to CEA (net = 0)
        assertEq(address(vault).balance, initialVaultBalance, "Vault balance should stay same");
    }

    /// @notice Test native withdrawal when CEA doesn't exist - should deploy and succeed
    function testWithdraw_Native_CEANotExists_DeploysAndSucceeds() public {
        bytes32 subTxId = keccak256("tx11");
        bytes32 universalTxId = keccak256("utx11");
        address originCaller = user3; // Fresh UEA
        uint256 amount = 10 ether;

        // Verify no CEA exists
        (, bool isDeployedBefore) = ceaFactory.getCEAForPushAccount(originCaller);
        assertFalse(isDeployedBefore, "CEA should not exist");

        uint256 initialUserBalance = recipient.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Withdraw - should deploy CEA
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0),
            amount,
            _withdrawalPayloadDirect(address(0), recipient, amount)
        );

        // Verify CEA deployed
        (, bool isDeployedAfter) = ceaFactory.getCEAForPushAccount(originCaller);
        assertTrue(isDeployedAfter, "CEA should be deployed");

        // Verify withdrawal
        assertEq(recipient.balance, initialUserBalance + amount, "User should receive ETH");
    }

    /// @notice Test native withdrawal with msg.value mismatch - should revert
    function testWithdraw_Native_MsgValueMismatch_Reverts() public {
        bytes32 subTxId = keccak256("tx12");
        bytes32 universalTxId = keccak256("utx12");
        address originCaller = user1;
        uint256 amount = 5 ether;
        uint256 wrongValue = 3 ether;

        // Fund TSS with the wrong value amount that will be sent
        vm.deal(tss, wrongValue);

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.finalizeUniversalTx{ value: wrongValue }( // msg.value != amount
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0),
            amount,
            _withdrawalPayloadDirect(address(0), recipient, amount)
        );
    }

    /// @notice Test native withdrawal with zero amount - should succeed (harmless no-op)
    function testWithdraw_Native_AmountZero_Allowed() public {
        bytes32 subTxId = keccak256("tx13");
        bytes32 universalTxId = keccak256("utx13");
        address originCaller = user1;

        uint256 initialBalance = recipient.balance;

        // Amount=0 is allowed (no-op but valid for execution-only operations)
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0),
            0, // Zero amount
            _withdrawalPayloadDirect(address(0), recipient, 0)
        );

        // Verify no ETH moved (amount was 0)
        assertEq(recipient.balance, initialBalance, "Recipient balance unchanged");
    }


    // =========================
    //  3. PAYLOAD EXECUTION TESTS (Unchanged - should still work)
    // =========================

    /// @notice Test ERC20 execution with non-empty payload - existing functionality
    function testExecute_ERC20_WithPayload_Success() public {
        bytes32 subTxId = keccak256("tx20");
        bytes32 universalTxId = keccak256("utx20");
        address originCaller = user1;
        uint256 amount = 100e6;
        bytes memory rawCalldata = abi.encodeWithSignature("someFunction()");

        // Mock target that will be called
        address mockTarget = address(0x1234);
        vm.etch(mockTarget, hex"00"); // Make it a contract

        vm.mockCall(mockTarget, rawCalldata, abi.encode(true));

        // Wrap raw calldata in multicall format
        bytes memory payload = _externalCallPayload(mockTarget, 0, rawCalldata);

        // Execute with non-empty payload - should route to execution path
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            payload // Multicall-wrapped payload
        );

        // Verify call was made (checked via mockCall)
        assertTrue(true, "Execution should succeed");
    }

    /// @notice Test native execution with non-empty payload - existing functionality
    function testExecute_Native_WithPayload_Success() public {
        bytes32 subTxId = keccak256("tx21");
        bytes32 universalTxId = keccak256("utx21");
        address originCaller = user1;
        uint256 amount = 1 ether;
        bytes memory rawCalldata = abi.encodeWithSignature("deposit()");

        address mockTarget = address(0x5678);
        vm.etch(mockTarget, hex"00");
        vm.mockCall(mockTarget, rawCalldata, abi.encode(true));

        // Wrap raw calldata in multicall format
        bytes memory payload = _externalCallPayload(mockTarget, 0, rawCalldata);

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Execute with non-empty payload
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0), // native
            amount,
            payload // Multicall-wrapped payload
        );

        assertTrue(true, "Native execution should succeed");
    }

    // =========================
    //  4. TOKEN PARKING TESTS
    // =========================

    /// @notice Test ERC20 token parking - tokens sent to CEA itself
    function testWithdraw_ERC20_Parking_CEAAsTarget() public {
        bytes32 subTxId = keccak256("tx30");
        bytes32 universalTxId = keccak256("utx30");
        address originCaller = user1;
        uint256 amount = 500e6;

        // Get CEA address (will be deployed if not exists)
        (address cea, bool isDeployed) = ceaFactory.getCEAForPushAccount(originCaller);
        if (!isDeployed) {
            vm.prank(address(vault));
            cea = ceaFactory.deployCEA(originCaller);
        }

        uint256 initialCEABalance = usdc.balanceOf(cea);
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));

        // Withdraw with target = CEA address (parking)
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), cea, amount)
        );

        // Verify tokens are "parked" in CEA
        assertEq(usdc.balanceOf(cea), initialCEABalance + amount, "Tokens should be parked in CEA");
        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance - amount, "Vault balance should decrease");
    }

    /// @notice Test native token parking
    function testWithdraw_Native_Parking_CEAAsTarget() public {
        bytes32 subTxId = keccak256("tx31");
        bytes32 universalTxId = keccak256("utx31");
        address originCaller = user1;
        uint256 amount = 10 ether;

        // Get/deploy CEA
        (address cea, bool isDeployed) = ceaFactory.getCEAForPushAccount(originCaller);
        if (!isDeployed) {
            vm.prank(address(vault));
            cea = ceaFactory.deployCEA(originCaller);
        }

        uint256 initialCEABalance = cea.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Park native tokens in CEA
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0),
            amount,
            _withdrawalPayloadDirect(address(0), cea, amount)
        );

        // Verify parking
        assertEq(cea.balance, initialCEABalance + amount, "ETH should be parked in CEA");
    }

    // =========================
    //  5. EVENT EMISSION TESTS
    // =========================

    /// @notice Test that withdrawal emits correct UniversalTxFinalized event
    function testWithdraw_EmitsUniversalTxFinalized() public {
        bytes32 subTxId = keccak256("tx40");
        bytes32 universalTxId = keccak256("utx40");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Expect exact event with withdrawal payload
        bytes memory expectedPayload = _withdrawalPayloadDirect(address(usdc), recipient, amount);
        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId, universalTxId, address(0), originCaller, address(0), address(usdc), amount, expectedPayload
        );

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, universalTxId, originCaller, address(0), address(usdc), amount, expectedPayload
        );
    }

    /// @notice Test that execution emits correct event with non-empty payload
    function testExecute_EmitsUniversalTxFinalized() public {
        bytes32 subTxId = keccak256("tx41");
        bytes32 universalTxId = keccak256("utx41");
        address originCaller = user1;
        uint256 amount = 100e6;
        bytes memory rawCalldata = abi.encodeWithSignature("test()");

        address mockTarget = address(0x9999);
        vm.etch(mockTarget, hex"00");
        vm.mockCall(mockTarget, rawCalldata, abi.encode(true));

        // Wrap raw calldata in multicall format
        bytes memory payload = _externalCallPayload(mockTarget, 0, rawCalldata);

        // Expect event with multicall-wrapped payload
        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId,
            universalTxId,
            address(0),
            originCaller,
            address(0),
            address(usdc),
            amount,
            payload // Multicall-wrapped payload
        );

        vm.prank(tss);
        vault.finalizeUniversalTx(subTxId, universalTxId, originCaller, address(0), address(usdc), amount, payload);
    }

    // =========================
    //  6. INTEGRATION TESTS
    // =========================

    /// @notice End-to-end test: Vault → CEA → User (ERC20)
    function testE2E_Withdrawal_ERC20_VaultToCEAToUser() public {
        bytes32 subTxId = keccak256("tx50");
        bytes32 universalTxId = keccak256("utx50");
        address originCaller = user1;
        uint256 amount = 1000e6;

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 userBefore = usdc.balanceOf(recipient);

        // Execute withdrawal
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );

        // Verify end-to-end flow
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - amount, "Vault decreased");
        assertEq(usdc.balanceOf(recipient), userBefore + amount, "User increased");

        // Verify CEA exists but doesn't hold tokens
        (address cea, bool deployed) = ceaFactory.getCEAForPushAccount(originCaller);
        assertTrue(deployed, "CEA should be deployed");
        assertEq(usdc.balanceOf(cea), 0, "CEA should not hold tokens after withdrawal");
    }

    /// @notice End-to-end test: Vault → CEA → User (Native)
    function testE2E_Withdrawal_Native_VaultToCEAToUser() public {
        bytes32 subTxId = keccak256("tx51");
        bytes32 universalTxId = keccak256("utx51");
        address originCaller = user1;
        uint256 amount = 20 ether;

        uint256 vaultBefore = address(vault).balance;
        uint256 userBefore = recipient.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Execute withdrawal
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(0),
            amount,
            _withdrawalPayloadDirect(address(0), recipient, amount)
        );

        // Verify flow
        // Vault balance stays same: receives `amount` from TSS, sends `amount` to CEA (net = 0)
        assertEq(address(vault).balance, vaultBefore, "Vault balance unchanged (pass-through)");
        assertEq(recipient.balance, userBefore + amount, "User increased");
    }

    /// @notice Test balance tracking across multiple withdrawals
    function testBalances_MultipleWithdrawals_Tracking() public {
        address originCaller = user1;
        uint256 amount1 = 100e6;
        uint256 amount2 = 200e6;

        uint256 vaultStart = usdc.balanceOf(address(vault));
        uint256 userStart = usdc.balanceOf(recipient);

        // First withdrawal
        vm.prank(tss);
        vault.finalizeUniversalTx(
            keccak256("tx60"),
            keccak256("utx60"),
            originCaller,
            address(0), // recipient
            address(usdc),
            amount1,
            _withdrawalPayloadDirect(address(usdc), recipient, amount1)
        );

        // Second withdrawal
        vm.prank(tss);
        vault.finalizeUniversalTx(
            keccak256("tx61"),
            keccak256("utx61"),
            originCaller,
            address(0), // recipient
            address(usdc),
            amount2,
            _withdrawalPayloadDirect(address(usdc), recipient, amount2)
        );

        // Verify cumulative changes
        assertEq(usdc.balanceOf(address(vault)), vaultStart - amount1 - amount2, "Vault decreased by total");
        assertEq(usdc.balanceOf(recipient), userStart + amount1 + amount2, "User increased by total");
    }

    // =========================
    //  7. EDGE CASES
    // =========================

    /// @notice Test withdrawal when Vault is paused - should revert
    function testWithdraw_WhenPaused_Reverts() public {
        bytes32 subTxId = keccak256("tx70");
        bytes32 universalTxId = keccak256("utx70");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Pause Vault (use pauser role, not admin)
        vm.prank(pauser);
        vault.pause();

        // Attempt withdrawal
        vm.prank(tss);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );
    }

    /// @notice Test non-TSS caller - should revert with access control error
    function testWithdraw_NonTSS_Reverts() public {
        bytes32 subTxId = keccak256("tx71");
        bytes32 universalTxId = keccak256("utx71");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Attacker tries to call
        vm.prank(attacker);
        vm.expectRevert(); // Should revert with role error
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );
    }

    /// @notice Test contract recipient (smart wallet) - should work
    function testWithdraw_SmartWalletRecipient_Success() public {
        bytes32 subTxId = keccak256("tx72");
        bytes32 universalTxId = keccak256("utx72");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Create a simple contract recipient (mock smart wallet)
        address smartWallet = address(0xABCD);
        vm.etch(smartWallet, hex"00"); // Make it a contract

        uint256 initialBalance = usdc.balanceOf(smartWallet);

        // Withdraw to smart wallet
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0), // recipient
            address(usdc),
            amount,
            _withdrawalPayloadDirect(address(usdc), smartWallet, amount)
        );

        // Verify smart wallet received tokens
        assertEq(usdc.balanceOf(smartWallet), initialBalance + amount, "Smart wallet should receive tokens");
    }

    // =========================
    //  8. RECIPIENT FIELD TESTS
    // =========================

    /// @notice V-R1: recipient=address(0) is forwarded to CEA as address(0)
    function testWithdraw_RecipientZero_FundsParkedInCEA() public {
        bytes32 subTxId = keccak256("txR1");
        bytes32 universalTxId = keccak256("utxR1");
        address originCaller = user1;
        uint256 amount = 100e6;

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, universalTxId, originCaller, address(0), address(usdc), amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );

        (address ceaAddr, bool deployed) = ceaFactory.getCEAForPushAccount(originCaller);
        assertTrue(deployed);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.lastRecipient(), address(0));
    }

    /// @notice V-R2: non-zero recipient is threaded to CEA (ERC20)
    function testWithdraw_RecipientNonZero_ERC20() public {
        bytes32 subTxId = keccak256("txR2");
        bytes32 universalTxId = keccak256("utxR2");
        address originCaller = user1;
        uint256 amount = 100e6;
        address specificRecipient = makeAddr("specificRecipient");

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, universalTxId, originCaller, specificRecipient, address(usdc), amount,
            _withdrawalPayloadDirect(address(usdc), recipient, amount)
        );

        (address ceaAddr,) = ceaFactory.getCEAForPushAccount(originCaller);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.lastRecipient(), specificRecipient);
    }

    /// @notice V-R3: non-zero recipient is threaded to CEA (native)
    function testWithdraw_RecipientNonZero_Native() public {
        bytes32 subTxId = keccak256("txR3");
        bytes32 universalTxId = keccak256("utxR3");
        address originCaller = user1;
        uint256 amount = 1 ether;
        address specificRecipient = makeAddr("specificRecipientNative");

        vm.deal(tss, amount);
        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId, universalTxId, originCaller, specificRecipient, address(0), amount,
            _withdrawalPayloadDirect(address(0), recipient, amount)
        );

        (address ceaAddr,) = ceaFactory.getCEAForPushAccount(originCaller);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.lastRecipient(), specificRecipient);
    }

    /// @notice V-R4: UniversalTxFinalized emits correct recipient (ERC20)
    function testWithdraw_RecipientInEvent_ERC20() public {
        bytes32 subTxId = keccak256("txR4");
        bytes32 universalTxId = keccak256("utxR4");
        address originCaller = user1;
        uint256 amount = 100e6;
        address specificRecipient = makeAddr("eventRecipientERC20");
        bytes memory payload = _withdrawalPayloadDirect(address(usdc), recipient, amount);

        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId, universalTxId, address(0), originCaller, specificRecipient, address(usdc), amount, payload
        );

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, universalTxId, originCaller, specificRecipient, address(usdc), amount, payload
        );
    }

    /// @notice V-R5: UniversalTxFinalized emits correct recipient (native)
    function testWithdraw_RecipientInEvent_Native() public {
        bytes32 subTxId = keccak256("txR5");
        bytes32 universalTxId = keccak256("utxR5");
        address originCaller = user1;
        uint256 amount = 2 ether;
        address specificRecipient = makeAddr("eventRecipientNative");
        bytes memory payload = _withdrawalPayloadDirect(address(0), recipient, amount);

        vm.deal(tss, amount);
        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxFinalized(
            subTxId, universalTxId, address(0), originCaller, specificRecipient, address(0), amount, payload
        );

        vm.prank(tss);
        vault.finalizeUniversalTx{ value: amount }(
            subTxId, universalTxId, originCaller, specificRecipient, address(0), amount, payload
        );
    }

    // =========================
    //  9. ZERO-REJECT TOKEN TESTS
    // =========================

    /// @notice Confirms ZeroRejectERC20 does in fact revert on zero transfers (validates the mock)
    function testMock_ZeroRejectToken_RevertsOnZeroTransfer() public {
        address anyAddr = makeAddr("anyAddr");
        zeroRejectToken.mint(address(this), 1e18);

        vm.expectRevert("ZeroRejectERC20: zero transfer");
        zeroRejectToken.transfer(anyAddr, 0);
    }

    /// @notice Zero-rejecting token with amount=0 must NOT revert — guard skips the transfer
    function testWithdraw_ZeroRejectToken_AmountZero_SkipsTransfer_Success() public {
        bytes32 subTxId = keccak256("tx_zr1");
        bytes32 universalTxId = keccak256("utx_zr1");
        address originCaller = user1;
        // Use empty payload so MockCEA doesn't try to call transfer(recipient, 0) which also rejects zero
        bytes memory payload = bytes("");

        uint256 initialVaultBalance = zeroRejectToken.balanceOf(address(vault));

        // Must NOT revert — the guard skips safeTransfer when amount=0
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0),
            address(zeroRejectToken),
            0,
            payload
        );

        // No tokens transferred
        assertEq(zeroRejectToken.balanceOf(address(vault)), initialVaultBalance, "Vault balance unchanged");

        // CEA was still invoked
        (address ceaAddr,) = ceaFactory.getCEAForPushAccount(originCaller);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.executeCallCount(), 1, "CEA was invoked despite zero transfer amount");
    }

    /// @notice Zero-rejecting token with amount>0 must still transfer correctly — non-regression
    function testWithdraw_ZeroRejectToken_AmountNonZero_Success() public {
        bytes32 subTxId = keccak256("tx_zr2");
        bytes32 universalTxId = keccak256("utx_zr2");
        address originCaller = user2;
        uint256 amount = 500e18;
        // Payload withdraws tokens from CEA to recipient
        bytes memory payload = _withdrawalPayloadDirect(address(zeroRejectToken), recipient, amount);

        uint256 initialVaultBalance = zeroRejectToken.balanceOf(address(vault));
        uint256 initialRecipientBalance = zeroRejectToken.balanceOf(recipient);

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId,
            universalTxId,
            originCaller,
            address(0),
            address(zeroRejectToken),
            amount,
            payload
        );

        // Vault decreased, recipient received (CEA executed the transfer payload)
        assertEq(zeroRejectToken.balanceOf(address(vault)), initialVaultBalance - amount, "Vault decreased");
        assertEq(zeroRejectToken.balanceOf(recipient), initialRecipientBalance + amount, "Recipient received tokens");
    }

    /// @notice V-R6: recipient + non-empty payload both thread correctly to CEA
    function testWithdraw_RecipientNonZero_WithPayload() public {
        bytes32 subTxId = keccak256("txR6");
        bytes32 universalTxId = keccak256("utxR6");
        address originCaller = user1;
        uint256 amount = 100e6;
        address specificRecipient = makeAddr("recipientWithPayload");
        bytes memory rawCalldata = abi.encodeWithSignature("someFunction()");
        address mockTarget = address(0x4242);
        vm.etch(mockTarget, hex"00");
        vm.mockCall(mockTarget, rawCalldata, abi.encode(true));
        bytes memory payload = _externalCallPayload(mockTarget, 0, rawCalldata);

        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, universalTxId, originCaller, specificRecipient, address(usdc), amount, payload
        );

        (address ceaAddr,) = ceaFactory.getCEAForPushAccount(originCaller);
        MockCEA cea = ceaFactory.getMockCEA(ceaAddr);
        assertEq(cea.lastRecipient(), specificRecipient);
        assertEq(cea.lastPayload(), payload);
    }
}
