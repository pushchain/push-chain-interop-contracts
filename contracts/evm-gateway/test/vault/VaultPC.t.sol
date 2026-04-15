// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { VaultPC } from "../../src/VaultPC.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";
import { MockReentrantContract } from "../mocks/MockReentrantContract.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultPCTest is Test {
    VaultPC public vault;
    VaultPC public vaultImpl;
    MockUniversalCoreReal public universalCore;
    MockPRC20 public prc20Token;
    MockPRC20 public prc20Token2;
    MockReentrantContract public reentrantAttacker;

    address public admin;
    address public pauser;
    address public fundManager;
    address public uem;
    address public user1;
    address public user2;

    // Events
    event GatewayPCUpdated(address indexed oldGatewayPC, address indexed newGatewayPC);
    event FeesWithdrawn(address indexed caller, address indexed to, address indexed token, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        fundManager = makeAddr("fundManager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        uem = makeAddr("uem");

        // Deploy UniversalCore mock
        universalCore = new MockUniversalCoreReal(uem);

        // Deploy VaultPC implementation and proxy
        vaultImpl = new VaultPC();
        bytes memory vaultInitData = abi.encodeWithSelector(VaultPC.initialize.selector, admin, pauser, fundManager);
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = VaultPC(payable(address(vaultProxy)));

        // Deploy PRC20 tokens
        prc20Token = new MockPRC20(
            "Push Ethereum",
            "pETH",
            18,
            "1",
            MockPRC20.TokenType.NATIVE,
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );

        prc20Token2 = new MockPRC20(
            "Push BNB",
            "pBNB",
            18,
            "56",
            MockPRC20.TokenType.NATIVE,
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );

        // Deploy reentrant attacker
        reentrantAttacker = new MockReentrantContract(address(0), address(0), address(0));
        reentrantAttacker.setVaultPC(address(vault));

        // Fund vault with tokens
        prc20Token.mint(address(vault), 100_000e18);
        prc20Token2.mint(address(vault), 100_000e18);
    }

    // ============================================================================
    // INITIALIZATION TESTS
    // ============================================================================

    function test_Initialization_RolesAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.MANAGER_ROLE(), fundManager));
    }

    function test_Initialization_StartsUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_Initialization_RevertsOnZeroAdmin() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(VaultPC.initialize.selector, address(0), pauser, fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroPauser() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(VaultPC.initialize.selector, admin, address(0), fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroFundManager() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(VaultPC.initialize.selector, admin, pauser, address(0));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================================================
    // ACCESS CONTROL TESTS
    // ============================================================================

    function test_Pause_OnlyPauserCanPause() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_NonPauserReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_OnlyPauserCanUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_NonPauserReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.unpause();
    }

    function test_WithdrawToken_OnlyFundManagerCanCall() public {
        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    function test_WithdrawToken_NonFundManagerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdrawToken(address(prc20Token), user1, 100e18);
    }

    // ============================================================================
    // PAUSE GATING TESTS
    // ============================================================================

    function test_Pause_BlocksWithdrawToken() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(fundManager);
        vm.expectRevert();
        vault.withdrawToken(address(prc20Token), user1, 100e18);
    }

    function test_Pause_DoublePauseReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_DoubleUnpauseReverts() public {
        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Unpause_RestoresWithdrawTokenFunctionality() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vault.unpause();

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // WITHDRAW TOKEN TESTS
    // ============================================================================

    function test_WithdrawToken_StandardToken_Success() public {
        uint256 amount = 1000e18;

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, amount);

        assertEq(prc20Token.balanceOf(user1), amount);
    }

    function test_WithdrawToken_EmitsFeesWithdrawnEvent() public {
        uint256 amount = 1000e18;

        vm.prank(fundManager);
        vm.expectEmit(true, true, true, true);
        emit FeesWithdrawn(fundManager, user1, address(prc20Token), amount);
        vault.withdrawToken(address(prc20Token), user1, amount);
    }

    function test_WithdrawToken_ZeroAmountReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdrawToken(address(prc20Token), user1, 0);
    }

    function test_WithdrawToken_ZeroRecipientReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdrawToken(address(prc20Token), address(0), 100e18);
    }

    function test_WithdrawToken_ZeroTokenAddressReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdrawToken(address(0), user1, 100e18);
    }

    function test_WithdrawToken_InsufficientBalanceReverts() public {
        uint256 vaultBalance = prc20Token.balanceOf(address(vault));

        vm.prank(fundManager);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdrawToken(address(prc20Token), user1, vaultBalance + 1);
    }

    function test_WithdrawToken_MultipleRecipients() public {
        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user2, 200e18);

        assertEq(prc20Token.balanceOf(user1), 100e18);
        assertEq(prc20Token.balanceOf(user2), 200e18);
    }

    function test_WithdrawToken_DifferentTokens() public {
        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token2), user1, 50e18);

        assertEq(prc20Token.balanceOf(user1), 100e18);
        assertEq(prc20Token2.balanceOf(user1), 50e18);
    }

    function test_WithdrawToken_SequentialCalls_Success() public {
        // Multiple sequential withdrawals should work fine
        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 200e18);

        assertEq(prc20Token.balanceOf(user1), 300e18);
    }

    // ============================================================================
    // WITHDRAW NATIVE PC TESTS
    // ============================================================================

    function test_Withdraw_Native_Success() public {
        uint256 amount = 10 ether;
        vm.deal(address(vault), amount);

        uint256 userBalanceBefore = user1.balance;

        vm.prank(fundManager);
        vault.withdraw(user1, amount);

        assertEq(user1.balance, userBalanceBefore + amount);
        assertEq(address(vault).balance, 0);
    }

    function test_Withdraw_Native_EmitsFeesWithdrawnEvent() public {
        uint256 amount = 5 ether;
        vm.deal(address(vault), amount);

        vm.prank(fundManager);
        vm.expectEmit(true, true, true, true);
        emit FeesWithdrawn(fundManager, user1, address(0), amount);
        vault.withdraw(user1, amount);
    }

    function test_Withdraw_Native_ZeroAmountReverts() public {
        vm.deal(address(vault), 10 ether);

        vm.prank(fundManager);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(user1, 0);
    }

    function test_Withdraw_Native_ZeroRecipientReverts() public {
        vm.deal(address(vault), 10 ether);

        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(address(0), 1 ether);
    }

    function test_Withdraw_Native_InsufficientBalanceReverts() public {
        vm.deal(address(vault), 5 ether);

        vm.prank(fundManager);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.withdraw(user1, 10 ether);
    }

    function test_Withdraw_Native_OnlyFundManagerCanCall() public {
        vm.deal(address(vault), 10 ether);

        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(user1, 1 ether);
    }

    function test_Withdraw_Native_BlockedWhenPaused() public {
        vm.deal(address(vault), 10 ether);

        vm.prank(pauser);
        vault.pause();

        vm.prank(fundManager);
        vm.expectRevert();
        vault.withdraw(user1, 1 ether);
    }

    function test_Withdraw_Native_SequentialCalls() public {
        vm.deal(address(vault), 30 ether);

        vm.prank(fundManager);
        vault.withdraw(user1, 10 ether);

        vm.prank(fundManager);
        vault.withdraw(user2, 15 ether);

        assertEq(user1.balance, 10 ether);
        assertEq(user2.balance, 15 ether);
        assertEq(address(vault).balance, 5 ether);
    }

    function test_Withdraw_Native_ExactBalance() public {
        uint256 vaultBalance = 25 ether;
        vm.deal(address(vault), vaultBalance);

        vm.prank(fundManager);
        vault.withdraw(user1, vaultBalance);

        assertEq(user1.balance, vaultBalance);
        assertEq(address(vault).balance, 0);
    }

    function test_ReceiveNative_ContractCanReceiveETH() public {
        uint256 amount = 10 ether;
        vm.deal(user1, amount);

        vm.prank(user1);
        (bool success,) = address(vault).call{ value: amount }("");

        assertTrue(success);
        assertEq(address(vault).balance, amount);
    }

    // ============================================================================
    // EDGE CASES AND INTEGRATION TESTS
    // ============================================================================

    function test_MultipleWithdrawalsToken_ReducesBalance() public {
        uint256 initialBalance = prc20Token.balanceOf(address(vault));

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user2, 200e18);

        uint256 finalBalance = prc20Token.balanceOf(address(vault));
        assertEq(finalBalance, initialBalance - 300e18);
    }

    function test_WithdrawToken_ExactBalance_Success() public {
        uint256 vaultBalance = prc20Token.balanceOf(address(vault));

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, vaultBalance);

        assertEq(prc20Token.balanceOf(user1), vaultBalance);
        assertEq(prc20Token.balanceOf(address(vault)), 0);
    }

    // ============================================================================
    // WITHDRAW NATIVE — TRANSFER FAILURE TEST
    // ============================================================================

    function test_Withdraw_Native_FailedTransfer_Reverts() public {
        VaultPCEthRejecter rejecter = new VaultPCEthRejecter();
        uint256 amount = 5 ether;
        vm.deal(address(vault), amount);

        vm.prank(fundManager);
        vm.expectRevert(Errors.WithdrawFailed.selector);
        vault.withdraw(address(rejecter), amount);
    }

    function test_Withdraw_Native_ReceiveThenWithdraw() public {
        uint256 amount = 10 ether;
        vm.deal(user1, amount);

        // Receive native via receive()
        vm.prank(user1);
        (bool ok,) = address(vault).call{ value: amount }("");
        assertTrue(ok);
        assertEq(address(vault).balance, amount);

        // Withdraw it
        vm.prank(fundManager);
        vault.withdraw(user2, amount);

        assertEq(user2.balance, amount);
        assertEq(address(vault).balance, 0);
    }

    // ============================================================================
    // EDGE CASE & ADDITIONAL COVERAGE TESTS
    // ============================================================================

    function test_WithdrawToken_AfterPauseUnpause_WorksNormally() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vault.unpause();

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    function test_WithdrawToken_MultipleSmallAmounts() public {
        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 1e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 2e18);

        vm.prank(fundManager);
        vault.withdrawToken(address(prc20Token), user1, 3e18);

        assertEq(prc20Token.balanceOf(user1), 6e18);
    }
}

/// @dev Contract that rejects all ETH transfers (for VaultPC withdraw failure test)
contract VaultPCEthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}
