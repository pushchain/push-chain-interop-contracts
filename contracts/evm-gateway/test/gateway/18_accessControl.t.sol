// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { Vault } from "../../src/Vault.sol";
import { VaultPC } from "../../src/VaultPC.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockWETH } from "../mocks/MockWETH.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract AccessControlTest is Test {
    UniversalGateway public gw;
    UniversalGatewayPC public gwPC;
    Vault public vault;
    VaultPC public vaultPC;

    address public admin;
    address public pauser;
    address public tss;
    address public attacker;
    address public newAddr;
    address public proxyDeployer;

    MockWETH public weth;
    MockCEAFactory public ceaFactory;
    MockAggregatorV3 public ethUsdFeed;

    // Cached role constants (avoids vm.prank being consumed by view calls)
    bytes32 public DEFAULT_ADMIN_ROLE;
    bytes32 public ROLE_MANAGER_ROLE;
    bytes32 public UG_ADMIN_ROLE;
    bytes32 public OPERATOR_ROLE;
    bytes32 public PAUSER_ROLE;
    bytes32 public VAULT_ROLE;
    bytes32 public TSS_ROLE;
    bytes32 public VAULT_ADMIN_ROLE;
    bytes32 public VPC_ADMIN_ROLE;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        attacker = makeAddr("attacker");
        newAddr = makeAddr("newAddr");
        proxyDeployer = makeAddr("proxyDeployer");

        weth = new MockWETH("WETH", "WETH");
        ceaFactory = new MockCEAFactory();
        ethUsdFeed = new MockAggregatorV3(8);
        ethUsdFeed.setAnswer(2000e8, block.timestamp);

        vm.startPrank(proxyDeployer);

        UniversalGateway gwImpl = new UniversalGateway();
        gw = UniversalGateway(payable(address(
            new TransparentUpgradeableProxy(
                address(gwImpl),
                proxyDeployer,
                abi.encodeWithSelector(
                    UniversalGateway.initialize.selector,
                    admin, pauser, tss, address(this),
                    1e18, 10e18,
                    address(0), address(0), address(weth)
                )
            )
        )));

        Vault vaultImpl = new Vault();
        vault = Vault(payable(address(
            new TransparentUpgradeableProxy(
                address(vaultImpl),
                proxyDeployer,
                abi.encodeWithSelector(
                    Vault.initialize.selector,
                    admin, pauser, tss, address(gw), address(ceaFactory)
                )
            )
        )));

        UniversalGatewayPC gwPCImpl = new UniversalGatewayPC();
        gwPC = UniversalGatewayPC(payable(address(
            new TransparentUpgradeableProxy(
                address(gwPCImpl),
                proxyDeployer,
                abi.encodeWithSelector(
                    UniversalGatewayPC.initialize.selector,
                    admin, pauser, address(0x100), address(0x200)
                )
            )
        )));

        VaultPC vpcImpl = new VaultPC();
        vaultPC = VaultPC(payable(address(
            new TransparentUpgradeableProxy(
                address(vpcImpl),
                proxyDeployer,
                abi.encodeWithSelector(
                    VaultPC.initialize.selector,
                    admin, pauser, admin
                )
            )
        )));

        vm.stopPrank();

        // Cache role constants to avoid consuming vm.prank on view calls
        DEFAULT_ADMIN_ROLE = gw.DEFAULT_ADMIN_ROLE();
        ROLE_MANAGER_ROLE = gw.ROLE_MANAGER_ROLE();
        UG_ADMIN_ROLE = gw.UG_ADMIN_ROLE();
        OPERATOR_ROLE = gw.OPERATOR_ROLE();
        PAUSER_ROLE = gw.PAUSER_ROLE();
        VAULT_ROLE = gw.VAULT_ROLE();
        TSS_ROLE = vault.TSS_ROLE();
        VAULT_ADMIN_ROLE = vault.VAULT_ADMIN_ROLE();
        VPC_ADMIN_ROLE = vaultPC.VPC_ADMIN_ROLE();

        vm.prank(admin);
        gw.setEthUsdFeed(address(ethUsdFeed));
    }

    // ============================================================
    // A. ADR CORE TESTS
    // ============================================================

    function test_defaultAdminDelay_is1Day() public view {
        assertEq(gw.defaultAdminDelay(), 1 days);
        assertEq(gwPC.defaultAdminDelay(), 1 days);
        assertEq(vault.defaultAdminDelay(), 1 days);
        assertEq(vaultPC.defaultAdminDelay(), 1 days);
    }

    function test_defaultAdmin_isAdminAddress() public view {
        assertEq(gw.defaultAdmin(), admin);
        assertEq(gwPC.defaultAdmin(), admin);
        assertEq(vault.defaultAdmin(), admin);
        assertEq(vaultPC.defaultAdmin(), admin);
    }

    function test_beginDefaultAdminTransfer_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.beginDefaultAdminTransfer(attacker);

        vm.prank(admin);
        gw.beginDefaultAdminTransfer(newAddr);
    }

    function test_acceptDefaultAdminTransfer_afterDelay() public {
        vm.prank(admin);
        gw.beginDefaultAdminTransfer(newAddr);

        vm.prank(newAddr);
        vm.expectRevert();
        gw.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(newAddr);
        gw.acceptDefaultAdminTransfer();
        assertEq(gw.defaultAdmin(), newAddr);
    }

    function test_cancelDefaultAdminTransfer() public {
        vm.prank(admin);
        gw.beginDefaultAdminTransfer(newAddr);

        vm.prank(admin);
        gw.cancelDefaultAdminTransfer();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(newAddr);
        vm.expectRevert();
        gw.acceptDefaultAdminTransfer();
    }

    function test_grantRole_defaultAdmin_reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        gw.grantRole(DEFAULT_ADMIN_ROLE, newAddr);
    }

    function test_revokeRole_defaultAdmin_reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        gw.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ============================================================
    // B. ROLE HIERARCHY TESTS (UniversalGateway)
    // ============================================================

    function test_roleManager_canGrantUGAdmin() public {
        vm.prank(admin);
        gw.grantRole(UG_ADMIN_ROLE, newAddr);
        assertTrue(gw.hasRole(UG_ADMIN_ROLE, newAddr));
    }

    function test_roleManager_canRevokeUGAdmin() public {
        vm.prank(admin);
        gw.grantRole(UG_ADMIN_ROLE, newAddr);

        vm.prank(admin);
        gw.revokeRole(UG_ADMIN_ROLE, newAddr);
        assertFalse(gw.hasRole(UG_ADMIN_ROLE, newAddr));
    }

    function test_roleManager_canGrantOperator() public {
        vm.prank(admin);
        gw.grantRole(OPERATOR_ROLE, newAddr);
        assertTrue(gw.hasRole(OPERATOR_ROLE, newAddr));
    }

    function test_roleManager_canGrantPauser() public {
        vm.prank(admin);
        gw.grantRole(PAUSER_ROLE, newAddr);
        assertTrue(gw.hasRole(PAUSER_ROLE, newAddr));
    }

    function test_roleManager_canGrantVaultRole() public {
        vm.prank(admin);
        gw.grantRole(VAULT_ROLE, newAddr);
        assertTrue(gw.hasRole(VAULT_ROLE, newAddr));
    }

    function test_defaultAdmin_canGrantRoleManager() public {
        vm.prank(admin);
        gw.grantRole(ROLE_MANAGER_ROLE, newAddr);
        assertTrue(gw.hasRole(ROLE_MANAGER_ROLE, newAddr));
    }

    function test_ugAdmin_cannotGrantRoles() public {
        vm.prank(admin);
        gw.grantRole(UG_ADMIN_ROLE, newAddr);

        vm.prank(newAddr);
        vm.expectRevert();
        gw.grantRole(OPERATOR_ROLE, attacker);
    }

    function test_operator_cannotGrantRoles() public {
        vm.prank(admin);
        gw.grantRole(OPERATOR_ROLE, newAddr);

        vm.prank(newAddr);
        vm.expectRevert();
        gw.grantRole(PAUSER_ROLE, attacker);
    }

    function test_pauser_cannotGrantRoles() public {
        vm.prank(pauser);
        vm.expectRevert();
        gw.grantRole(UG_ADMIN_ROLE, attacker);
    }

    // ============================================================
    // C. FUNCTION ACCESS TESTS — UniversalGateway
    // ============================================================

    function test_setCapsUSD_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setCapsUSD(1e18, 10e18);
    }

    function test_setBlockUsdCap_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setBlockUsdCap(1e18);
    }

    function test_setTokenLimitThresholds_onlyUGAdmin() public {
        address[] memory t = new address[](1);
        uint256[] memory th = new uint256[](1);
        t[0] = address(0x1);
        th[0] = 1e18;

        vm.prank(attacker);
        vm.expectRevert();
        gw.setTokenLimitThresholds(t, th);
    }

    function test_updateEpochDuration_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.updateEpochDuration(1 hours);
    }

    function test_setEthUsdFeed_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setEthUsdFeed(address(0x1));
    }

    function test_setChainlinkStalePeriod_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setChainlinkStalePeriod(1 hours);
    }

    function test_setL2SequencerFeed_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setL2SequencerFeed(address(0x1));
    }

    function test_setL2SequencerGracePeriod_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setL2SequencerGracePeriod(1 hours);
    }

    function test_setDefaultSwapDeadline_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setDefaultSwapDeadline(10 minutes);
    }

    function test_setV3FeeOrder_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setV3FeeOrder(500, 3000, 10000);
    }

    function test_setProtocolFee_onlyUGAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.setProtocolFee(0.01 ether);
    }

    function test_updateTSS_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.updateTSS(address(0x1));
    }

    function test_updateVault_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.updateVault(address(0x1));
    }

    function test_updateUniswapV3Config_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.updateUniswapV3Config(address(0x1), address(0x2));
    }

    function test_updateCEAFactory_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.updateCEAFactory(address(0x1));
    }

    function test_unpause_onlyOperator_UG() public {
        vm.prank(pauser);
        gw.pause();

        vm.prank(pauser);
        vm.expectRevert();
        gw.unpause();

        vm.prank(admin);
        gw.unpause();
        assertFalse(gw.paused());
    }

    function test_pause_onlyPauser_UG() public {
        vm.prank(attacker);
        vm.expectRevert();
        gw.pause();

        vm.prank(pauser);
        gw.pause();
        assertTrue(gw.paused());
    }

    // ============================================================
    // D. FUNCTION ACCESS TESTS — UniversalGatewayPC
    // ============================================================

    function test_updateVaultPC_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gwPC.updateVaultPC(address(0x1));
    }

    function test_updateUniversalCore_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        gwPC.updateUniversalCore(address(0x1));
    }

    function test_unpause_onlyOperator_UGPC() public {
        vm.prank(pauser);
        gwPC.pause();

        vm.prank(pauser);
        vm.expectRevert();
        gwPC.unpause();

        vm.prank(admin);
        gwPC.unpause();
        assertFalse(gwPC.paused());
    }

    function test_pause_onlyPauser_UGPC() public {
        vm.prank(attacker);
        vm.expectRevert();
        gwPC.pause();
    }

    // ============================================================
    // E. FUNCTION ACCESS TESTS — Vault
    // ============================================================

    function test_updateGateway_onlyOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.updateGateway(address(0x1));
    }

    function test_updateCEAFactory_onlyOperator_Vault() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.updateCEAFactory(address(0x1));
    }

    function test_migrateTokens_onlyVaultAdmin() public {
        vm.prank(pauser);
        vault.pause();
        vm.prank(pauser);
        gw.pause();

        address[] memory tokens = new address[](0);

        vm.prank(attacker);
        vm.expectRevert();
        vault.migrateTokens(address(0x1), tokens);
    }

    function test_unpause_onlyOperator_Vault() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_finalizeUniversalTx_onlyTSS() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            bytes32(0), bytes32(0), address(0x1),
            address(0x2), address(0), 0, bytes("")
        );
    }

    // ============================================================
    // F. FUNCTION ACCESS TESTS — VaultPC
    // ============================================================

    function test_withdraw_onlyVPCAdmin() public {
        vm.deal(address(vaultPC), 1 ether);

        vm.prank(attacker);
        vm.expectRevert();
        vaultPC.withdraw(address(0x1), 1 ether);
    }

    function test_withdrawToken_onlyVPCAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        vaultPC.withdrawToken(address(0x1), address(0x2), 1e18);
    }

    function test_unpause_onlyOperator_VaultPC() public {
        vm.prank(pauser);
        vaultPC.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vaultPC.unpause();

        vm.prank(admin);
        vaultPC.unpause();
        assertFalse(vaultPC.paused());
    }

    // ============================================================
    // G. ROLE SEPARATION SCENARIOS
    // ============================================================

    function test_separateAdminAndOperator() public {
        address ugAdminAddr = makeAddr("ugAdmin");
        address operatorAddr = makeAddr("operator");

        vm.startPrank(admin);
        gw.grantRole(UG_ADMIN_ROLE, ugAdminAddr);
        gw.grantRole(OPERATOR_ROLE, operatorAddr);
        vm.stopPrank();

        vm.prank(ugAdminAddr);
        gw.setCapsUSD(2e18, 20e18);

        vm.prank(ugAdminAddr);
        vm.expectRevert();
        gw.updateTSS(address(0x999));

        vm.prank(operatorAddr);
        gw.updateTSS(address(0x999));

        vm.prank(operatorAddr);
        vm.expectRevert();
        gw.setCapsUSD(3e18, 30e18);
    }

    function test_pauserCannotUnpause() public {
        vm.prank(pauser);
        gw.pause();

        vm.prank(pauser);
        vm.expectRevert();
        gw.unpause();
    }

    function test_operatorCannotPause() public {
        vm.prank(admin);
        gw.grantRole(OPERATOR_ROLE, newAddr);

        vm.prank(newAddr);
        vm.expectRevert();
        gw.pause();
    }

    function test_roleRotation_viaRoleManager() public {
        address oldOp = makeAddr("oldOp");
        address newOp = makeAddr("newOp");

        vm.startPrank(admin);
        gw.grantRole(OPERATOR_ROLE, oldOp);
        vm.stopPrank();

        vm.prank(oldOp);
        gw.updateTSS(makeAddr("tss2"));

        vm.startPrank(admin);
        gw.revokeRole(OPERATOR_ROLE, oldOp);
        gw.grantRole(OPERATOR_ROLE, newOp);
        vm.stopPrank();

        vm.prank(oldOp);
        vm.expectRevert();
        gw.updateTSS(makeAddr("tss3"));

        vm.prank(newOp);
        gw.updateTSS(makeAddr("tss3"));
    }

    // ============================================================
    // H. BOOTSTRAP GRANTS VERIFICATION
    // ============================================================

    function test_bootstrapGrants_UG() public view {
        assertTrue(gw.hasRole(ROLE_MANAGER_ROLE, admin));
        assertTrue(gw.hasRole(UG_ADMIN_ROLE, admin));
        assertTrue(gw.hasRole(OPERATOR_ROLE, admin));
        assertTrue(gw.hasRole(PAUSER_ROLE, pauser));
        assertTrue(gw.hasRole(VAULT_ROLE, address(this)));
    }

    function test_bootstrapGrants_UGPC() public view {
        assertTrue(gwPC.hasRole(ROLE_MANAGER_ROLE, admin));
        assertTrue(gwPC.hasRole(OPERATOR_ROLE, admin));
        assertTrue(gwPC.hasRole(PAUSER_ROLE, pauser));
    }

    function test_bootstrapGrants_Vault() public view {
        assertTrue(vault.hasRole(ROLE_MANAGER_ROLE, admin));
        assertTrue(vault.hasRole(VAULT_ADMIN_ROLE, admin));
        assertTrue(vault.hasRole(OPERATOR_ROLE, admin));
        assertTrue(vault.hasRole(PAUSER_ROLE, pauser));
        assertTrue(vault.hasRole(TSS_ROLE, tss));
    }

    function test_bootstrapGrants_VaultPC() public view {
        assertTrue(vaultPC.hasRole(ROLE_MANAGER_ROLE, admin));
        assertTrue(vaultPC.hasRole(VPC_ADMIN_ROLE, admin));
        assertTrue(vaultPC.hasRole(OPERATOR_ROLE, admin));
        assertTrue(vaultPC.hasRole(PAUSER_ROLE, pauser));
    }

    receive() external payable {}
}
