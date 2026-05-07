// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { VaultPC20 } from "../../src/VaultPC20.sol";
import { IVaultPC20 } from "../../src/interfaces/IVaultPC20.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultPC20Test is Test {
    VaultPC20 public vault;
    VaultPC20 public vaultImpl;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public admin;
    address public pauser;
    address public tss;
    address public gatewayPC;
    address public user1;
    address public user2;
    address public attacker;

    event TokensLocked(
        address indexed token,
        uint256 amount,
        uint256 totalLocked
    );

    event TokensUnlocked(
        bytes32 indexed subTxId,
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    event ExportReverted(
        bytes32 indexed subTxId,
        address indexed token,
        uint256 amount,
        address indexed revertRecipient
    );

    event EmergencyWithdrawal(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event UniversalGatewayPCUpdated(
        address indexed oldGatewayPC,
        address indexed newGatewayPC
    );

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        gatewayPC = makeAddr("gatewayPC");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        attacker = makeAddr("attacker");

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        tokenB = new MockERC20("TokenB", "TKB", 18, 0);

        vaultImpl = new VaultPC20();
        bytes memory initData = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            admin,
            pauser,
            tss,
            gatewayPC
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(vaultImpl),
            initData
        );
        vault = VaultPC20(address(proxy));
    }

    // ================================================================
    // INITIALIZE
    // ================================================================

    function test_Initialize_RolesAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.ROLE_MANAGER_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.TSS_ROLE(), tss));
        assertTrue(vault.hasRole(vault.GATEWAY_ROLE(), gatewayPC));
    }

    function test_Initialize_GatewayPCStored() public view {
        assertEq(vault.universalGatewayPC(), gatewayPC);
    }

    function test_Initialize_StartsUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        VaultPC20 impl = new VaultPC20();
        bytes memory data = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            address(0), pauser, tss, gatewayPC
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertsOnZeroPauser() public {
        VaultPC20 impl = new VaultPC20();
        bytes memory data = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            admin, address(0), tss, gatewayPC
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertsOnZeroTss() public {
        VaultPC20 impl = new VaultPC20();
        bytes memory data = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            admin, pauser, address(0), gatewayPC
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertsOnZeroGateway() public {
        VaultPC20 impl = new VaultPC20();
        bytes memory data = abi.encodeWithSelector(
            VaultPC20.initialize.selector,
            admin, pauser, tss, address(0)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_CannotInitializeTwice() public {
        vm.expectRevert();
        vault.initialize(admin, pauser, tss, gatewayPC);
    }

    function test_Initialize_RoleAdminHierarchy() public view {
        bytes32 roleMgr = vault.ROLE_MANAGER_ROLE();
        assertEq(vault.getRoleAdmin(vault.TSS_ROLE()), roleMgr);
        assertEq(vault.getRoleAdmin(vault.OPERATOR_ROLE()), roleMgr);
        assertEq(vault.getRoleAdmin(vault.PAUSER_ROLE()), roleMgr);
        assertEq(vault.getRoleAdmin(vault.GATEWAY_ROLE()), roleMgr);
    }

    function test_Initialize_PauserCannotUnlock() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vm.expectRevert();
        vault.unlock(keccak256("tx1"), address(tokenA), 50e18, user1);
    }

    function test_Initialize_TssCannotRecordLock() public {
        vm.prank(tss);
        vm.expectRevert();
        vault.recordLock(address(tokenA), 100e18);
    }

    // ================================================================
    // RECORD LOCK — HAPPY PATH
    // ================================================================

    function test_RecordLock_Success() public {
        tokenA.mint(address(vault), 100e18);

        vm.prank(gatewayPC);
        vm.expectEmit(true, false, false, true);
        emit TokensLocked(address(tokenA), 100e18, 100e18);
        vault.recordLock(address(tokenA), 100e18);

        assertEq(vault.totalLocked(address(tokenA)), 100e18);
    }

    function test_RecordLock_MultipleSameToken() public {
        tokenA.mint(address(vault), 300e18);

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 100e18);

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 200e18);

        assertEq(vault.totalLocked(address(tokenA)), 300e18);
    }

    function test_RecordLock_MultipleDifferentTokens() public {
        tokenA.mint(address(vault), 100e18);
        tokenB.mint(address(vault), 200e18);

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 100e18);

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenB), 200e18);

        assertEq(vault.totalLocked(address(tokenA)), 100e18);
        assertEq(vault.totalLocked(address(tokenB)), 200e18);
    }

    function test_RecordLock_EventCumulativeTotalLocked() public {
        tokenA.mint(address(vault), 300e18);

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 100e18);

        vm.prank(gatewayPC);
        vm.expectEmit(true, false, false, true);
        emit TokensLocked(address(tokenA), 200e18, 300e18);
        vault.recordLock(address(tokenA), 200e18);
    }

    // ================================================================
    // RECORD LOCK — REVERTS
    // ================================================================

    function test_RecordLock_RevertsNonGateway() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.recordLock(address(tokenA), 100e18);
    }

    function test_RecordLock_RevertsNoPriorTransfer() public {
        vm.prank(gatewayPC);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.recordLock(address(tokenA), 100e18);
    }

    function test_RecordLock_RevertsInsufficientBalance() public {
        tokenA.mint(address(vault), 50e18);

        vm.prank(gatewayPC);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.recordLock(address(tokenA), 100e18);
    }

    function test_RecordLock_WorksWhilePaused() public {
        tokenA.mint(address(vault), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 100e18);

        assertEq(vault.totalLocked(address(tokenA)), 100e18);
    }

    // ================================================================
    // UNLOCK — HAPPY PATH
    // ================================================================

    function test_Unlock_Success() public {
        _lockTokens(address(tokenA), 1000e18);

        bytes32 subTxId = keccak256("unlock1");

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit TokensUnlocked(subTxId, address(tokenA), 400e18, user1);
        vault.unlock(subTxId, address(tokenA), 400e18, user1);

        assertEq(vault.totalLocked(address(tokenA)), 600e18);
        assertEq(tokenA.balanceOf(user1), 400e18);
    }

    function test_Unlock_Partial() public {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("u1"),
            address(tokenA),
            300e18,
            user1
        );

        assertEq(vault.totalLocked(address(tokenA)), 700e18);
        assertEq(tokenA.balanceOf(user1), 300e18);
    }

    function test_Unlock_MultipleForSameToken() public {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(tss);
        vault.unlock(keccak256("u1"), address(tokenA), 300e18, user1);

        vm.prank(tss);
        vault.unlock(keccak256("u2"), address(tokenA), 200e18, user2);

        assertEq(vault.totalLocked(address(tokenA)), 500e18);
        assertEq(tokenA.balanceOf(user1), 300e18);
        assertEq(tokenA.balanceOf(user2), 200e18);
    }

    function test_Unlock_DifferentTokens() public {
        _lockTokens(address(tokenA), 500e18);
        _lockTokens(address(tokenB), 800e18);

        vm.prank(tss);
        vault.unlock(keccak256("uA"), address(tokenA), 200e18, user1);

        vm.prank(tss);
        vault.unlock(keccak256("uB"), address(tokenB), 300e18, user1);

        assertEq(vault.totalLocked(address(tokenA)), 300e18);
        assertEq(vault.totalLocked(address(tokenB)), 500e18);
    }

    function test_Unlock_SetsIsExecuted() public {
        _lockTokens(address(tokenA), 100e18);
        bytes32 subTxId = keccak256("exec1");

        assertFalse(vault.isExecuted(subTxId));

        vm.prank(tss);
        vault.unlock(subTxId, address(tokenA), 50e18, user1);

        assertTrue(vault.isExecuted(subTxId));
    }

    // ================================================================
    // UNLOCK — REVERTS
    // ================================================================

    function test_Unlock_RevertsReplay() public {
        _lockTokens(address(tokenA), 200e18);
        bytes32 subTxId = keccak256("replay");

        vm.prank(tss);
        vault.unlock(subTxId, address(tokenA), 100e18, user1);

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.unlock(subTxId, address(tokenA), 100e18, user1);
    }

    function test_Unlock_RevertsNonTss() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(attacker);
        vm.expectRevert();
        vault.unlock(keccak256("x"), address(tokenA), 50e18, user1);
    }

    function test_Unlock_RevertsZeroToken() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.unlock(keccak256("x"), address(0), 50e18, user1);
    }

    function test_Unlock_RevertsZeroAmount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.unlock(
            keccak256("x"),
            address(tokenA),
            0,
            user1
        );
    }

    function test_Unlock_RevertsZeroRecipient() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.unlock(
            keccak256("x"),
            address(tokenA),
            50e18,
            address(0)
        );
    }

    function test_Unlock_RevertsInsufficientLocked() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.unlock(
            keccak256("x"),
            address(tokenA),
            200e18,
            user1
        );
    }

    function test_Unlock_RevertsWhenPaused() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.unlock(keccak256("x"), address(tokenA), 50e18, user1);
    }

    // ================================================================
    // REVERT EXPORT — HAPPY PATH
    // ================================================================

    function test_RevertExport_Success() public {
        _lockTokens(address(tokenA), 1000e18);

        bytes32 subTxId = keccak256("revert1");

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit ExportReverted(
            subTxId,
            address(tokenA),
            400e18,
            user1
        );
        vault.revertExport(subTxId, address(tokenA), 400e18, user1);

        assertEq(vault.totalLocked(address(tokenA)), 600e18);
        assertEq(tokenA.balanceOf(user1), 400e18);
    }

    function test_RevertExport_SetsIsExecuted() public {
        _lockTokens(address(tokenA), 100e18);
        bytes32 subTxId = keccak256("rv1");

        vm.prank(tss);
        vault.revertExport(subTxId, address(tokenA), 50e18, user1);

        assertTrue(vault.isExecuted(subTxId));
    }

    // ================================================================
    // REVERT EXPORT — REVERTS
    // ================================================================

    function test_RevertExport_RevertsReplay() public {
        _lockTokens(address(tokenA), 200e18);
        bytes32 subTxId = keccak256("rvReplay");

        vm.prank(tss);
        vault.revertExport(
            subTxId, address(tokenA), 100e18, user1
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.revertExport(
            subTxId, address(tokenA), 100e18, user1
        );
    }

    function test_RevertExport_RevertsNonTss() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(attacker);
        vm.expectRevert();
        vault.revertExport(
            keccak256("x"), address(tokenA), 50e18, user1
        );
    }

    function test_RevertExport_RevertsZeroToken() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertExport(
            keccak256("x"), address(0), 50e18, user1
        );
    }

    function test_RevertExport_RevertsZeroAmount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.revertExport(
            keccak256("x"), address(tokenA), 0, user1
        );
    }

    function test_RevertExport_RevertsZeroRecipient() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.revertExport(
            keccak256("x"),
            address(tokenA),
            50e18,
            address(0)
        );
    }

    function test_RevertExport_RevertsInsufficientLocked() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.revertExport(
            keccak256("x"),
            address(tokenA),
            200e18,
            user1
        );
    }

    function test_RevertExport_RevertsWhenPaused() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertExport(
            keccak256("x"), address(tokenA), 50e18, user1
        );
    }

    // ================================================================
    // IS_EXECUTED — CROSS-FUNCTION REPLAY
    // ================================================================

    function test_IsExecuted_UnlockBlocksRevert() public {
        _lockTokens(address(tokenA), 200e18);
        bytes32 subTxId = keccak256("cross1");

        vm.prank(tss);
        vault.unlock(subTxId, address(tokenA), 100e18, user1);

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.revertExport(
            subTxId, address(tokenA), 100e18, user1
        );
    }

    function test_IsExecuted_RevertBlocksUnlock() public {
        _lockTokens(address(tokenA), 200e18);
        bytes32 subTxId = keccak256("cross2");

        vm.prank(tss);
        vault.revertExport(
            subTxId, address(tokenA), 100e18, user1
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.unlock(subTxId, address(tokenA), 100e18, user2);
    }

    function test_IsExecuted_DifferentIdsAreIndependent() public {
        _lockTokens(address(tokenA), 300e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("idA"),
            address(tokenA),
            100e18,
            user1
        );

        vm.prank(tss);
        vault.unlock(
            keccak256("idB"),
            address(tokenA),
            100e18,
            user2
        );

        assertTrue(vault.isExecuted(keccak256("idA")));
        assertTrue(vault.isExecuted(keccak256("idB")));
        assertEq(vault.totalLocked(address(tokenA)), 100e18);
    }

    // ================================================================
    // EMERGENCY WITHDRAW
    // ================================================================

    function test_EmergencyWithdraw_Success() public {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit EmergencyWithdrawal(address(tokenA), user1, 500e18);
        vault.emergencyWithdraw(address(tokenA), user1, 500e18);

        assertEq(tokenA.balanceOf(user1), 500e18);
    }

    function test_EmergencyWithdraw_DoesNotDecrementTotalLocked()
        public
    {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.emergencyWithdraw(
            address(tokenA), user1, 500e18
        );

        assertEq(vault.totalLocked(address(tokenA)), 1000e18);
        assertEq(tokenA.balanceOf(address(vault)), 500e18);
    }

    function test_EmergencyWithdraw_RevertsWhenNotPaused() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(admin);
        vm.expectRevert();
        vault.emergencyWithdraw(
            address(tokenA), user1, 50e18
        );
    }

    function test_EmergencyWithdraw_RevertsNonAdmin() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert();
        vault.emergencyWithdraw(
            address(tokenA), user1, 50e18
        );
    }

    function test_EmergencyWithdraw_RevertsZeroToken() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.emergencyWithdraw(address(0), user1, 50e18);
    }

    function test_EmergencyWithdraw_RevertsZeroRecipient() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.emergencyWithdraw(
            address(tokenA), address(0), 50e18
        );
    }

    function test_EmergencyWithdraw_RevertsZeroAmount() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.emergencyWithdraw(
            address(tokenA), user1, 0
        );
    }

    function test_EmergencyWithdraw_RevertsInsufficientBalance()
        public
    {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectRevert();
        vault.emergencyWithdraw(
            address(tokenA), user1, 100e18
        );
    }

    // ================================================================
    // PAUSE / UNPAUSE
    // ================================================================

    function test_Pause_OnlyPauserCanPause() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_NonPauserReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_OnlyOperatorCanUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_NonOperatorReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Pause_BlocksUnlock() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.unlock(keccak256("x"), address(tokenA), 50e18, user1);
    }

    function test_Pause_BlocksRevertExport() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertExport(
            keccak256("x"), address(tokenA), 50e18, user1
        );
    }

    function test_Pause_DoesNotBlockRecordLock() public {
        tokenA.mint(address(vault), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 100e18);
        assertEq(vault.totalLocked(address(tokenA)), 100e18);
    }

    function test_Unpause_ReenablesUnlock() public {
        _lockTokens(address(tokenA), 100e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.unpause();

        vm.prank(tss);
        vault.unlock(keccak256("x"), address(tokenA), 50e18, user1);

        assertEq(tokenA.balanceOf(user1), 50e18);
    }

    // ================================================================
    // UPDATE UNIVERSAL GATEWAY PC
    // ================================================================

    function test_UpdateGatewayPC_Success() public {
        address newGateway = makeAddr("newGateway");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit UniversalGatewayPCUpdated(gatewayPC, newGateway);
        vault.updateUniversalGatewayPC(newGateway);

        assertEq(vault.universalGatewayPC(), newGateway);
    }

    function test_UpdateGatewayPC_OldLosesRole() public {
        address newGateway = makeAddr("newGateway");

        vm.prank(admin);
        vault.updateUniversalGatewayPC(newGateway);

        assertFalse(
            vault.hasRole(vault.GATEWAY_ROLE(), gatewayPC)
        );

        tokenA.mint(address(vault), 100e18);
        vm.prank(gatewayPC);
        vm.expectRevert();
        vault.recordLock(address(tokenA), 100e18);
    }

    function test_UpdateGatewayPC_NewHasRole() public {
        address newGateway = makeAddr("newGateway");

        vm.prank(admin);
        vault.updateUniversalGatewayPC(newGateway);

        assertTrue(
            vault.hasRole(vault.GATEWAY_ROLE(), newGateway)
        );

        tokenA.mint(address(vault), 100e18);
        vm.prank(newGateway);
        vault.recordLock(address(tokenA), 100e18);
        assertEq(vault.totalLocked(address(tokenA)), 100e18);
    }

    function test_UpdateGatewayPC_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.updateUniversalGatewayPC(address(0));
    }

    function test_UpdateGatewayPC_RevertsNonOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.updateUniversalGatewayPC(makeAddr("new"));
    }

    // ================================================================
    // ACCOUNTING INTEGRITY
    // ================================================================

    function test_Accounting_MixedOpsTracksCorrectly() public {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("u1"), address(tokenA), 300e18, user1
        );

        tokenA.mint(address(vault), 500e18);
        vm.prank(gatewayPC);
        vault.recordLock(address(tokenA), 500e18);

        vm.prank(tss);
        vault.revertExport(
            keccak256("rv1"), address(tokenA), 200e18, user2
        );

        // 1000 - 300 + 500 - 200 = 1000
        assertEq(vault.totalLocked(address(tokenA)), 1000e18);
    }

    function test_Accounting_PerTokenIndependence() public {
        _lockTokens(address(tokenA), 500e18);
        _lockTokens(address(tokenB), 300e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("uA"), address(tokenA), 200e18, user1
        );

        assertEq(vault.totalLocked(address(tokenA)), 300e18);
        assertEq(vault.totalLocked(address(tokenB)), 300e18);
    }

    function test_Accounting_BalanceGeTotalLockedAfterOps()
        public
    {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("u1"), address(tokenA), 400e18, user1
        );

        vm.prank(tss);
        vault.revertExport(
            keccak256("rv1"), address(tokenA), 100e18, user2
        );

        assertGe(
            tokenA.balanceOf(address(vault)),
            vault.totalLocked(address(tokenA))
        );
    }

    function test_Accounting_EmergencyBreaksInvariant() public {
        _lockTokens(address(tokenA), 1000e18);

        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.emergencyWithdraw(
            address(tokenA), user1, 500e18
        );

        assertEq(vault.totalLocked(address(tokenA)), 1000e18);
        assertEq(tokenA.balanceOf(address(vault)), 500e18);
        assertLt(
            tokenA.balanceOf(address(vault)),
            vault.totalLocked(address(tokenA))
        );
    }

    function test_Accounting_FullUnlockZerosTotalLocked()
        public
    {
        _lockTokens(address(tokenA), 500e18);

        vm.prank(tss);
        vault.unlock(
            keccak256("full"),
            address(tokenA),
            500e18,
            user1
        );

        assertEq(vault.totalLocked(address(tokenA)), 0);
        assertEq(tokenA.balanceOf(user1), 500e18);
    }

    // ================================================================
    // HELPERS
    // ================================================================

    function _lockTokens(address token, uint256 amount) internal {
        MockERC20(token).mint(address(vault), amount);
        vm.prank(gatewayPC);
        vault.recordLock(token, amount);
    }
}
