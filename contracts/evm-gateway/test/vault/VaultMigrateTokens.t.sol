// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

contract ReentrantReceiver {
    Vault public target;
    address public newVault;
    address[] public tokens;

    constructor(Vault _target, address _newVault, address[] memory _tokens) {
        target = _target;
        newVault = _newVault;
        tokens = _tokens;
    }

    receive() external payable {
        target.migrateTokens(newVault, tokens);
    }
}

contract VaultMigrateTokensTest is Test {
    Vault public vault;
    Vault public newVault;
    UniversalGateway public gateway;
    MockCEAFactory public ceaFactory;

    MockERC20 public token;
    MockERC20 public token2;
    MockERC20 public token3;

    address public admin;
    address public pauser;
    address public tss;
    address public attacker;
    address public weth;

    event TokensMigrated(
        address indexed newVault,
        address[] tokens,
        uint256[] amounts,
        uint256 nativeAmount
    );

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");

        ceaFactory = new MockCEAFactory();

        // Deploy old vault with placeholder gateway
        Vault vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin, pauser, tss,
            address(1),
            address(ceaFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = Vault(payable(address(vaultProxy)));

        // Deploy gateway pointing to vault
        UniversalGateway gwImpl = new UniversalGateway();
        bytes memory gwInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss,
            address(vault),
            1e18, 10e18,
            address(0), address(0),
            weth
        );
        ERC1967Proxy gwProxy = new ERC1967Proxy(address(gwImpl), gwInitData);
        gateway = UniversalGateway(payable(address(gwProxy)));

        // Point vault at real gateway
        vm.prank(admin);
        vault.updateGateway(address(gateway));

        ceaFactory.setVault(address(vault));

        // Deploy new vault
        Vault newVaultImpl = new Vault();
        bytes memory newVaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin, pauser, tss,
            address(gateway),
            address(ceaFactory)
        );
        ERC1967Proxy newVaultProxy = new ERC1967Proxy(address(newVaultImpl), newVaultInitData);
        newVault = Vault(payable(address(newVaultProxy)));

        // Deploy and fund tokens
        token = new MockERC20("Token A", "TKNA", 18, 0);
        token2 = new MockERC20("Token B", "TKNB", 6, 0);
        token3 = new MockERC20("Token C", "TKNC", 18, 0);

        token.mint(address(vault), 100_000e18);
        token2.mint(address(vault), 100_000e6);
        token3.mint(address(vault), 50_000e18);
    }

    // ==============================
    //    HELPERS
    // ==============================

    function _pauseBoth() internal {
        vm.prank(pauser);
        gateway.pause();
        vm.prank(pauser);
        vault.pause();
    }

    function _tokenList1() internal view returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = address(token);
        return t;
    }

    function _tokenListAll() internal view returns (address[] memory) {
        address[] memory t = new address[](3);
        t[0] = address(token);
        t[1] = address(token2);
        t[2] = address(token3);
        return t;
    }

    // ==============================
    //    A. HAPPY PATH
    // ==============================

    function test_MigrateTokens_SingleToken() public {
        _pauseBoth();

        uint256 bal = token.balanceOf(address(vault));
        assertGt(bal, 0);

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenList1());

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(newVault)), bal);
    }

    function test_MigrateTokens_MultipleTokens() public {
        _pauseBoth();

        uint256 bal1 = token.balanceOf(address(vault));
        uint256 bal2 = token2.balanceOf(address(vault));
        uint256 bal3 = token3.balanceOf(address(vault));

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenListAll());

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token2.balanceOf(address(vault)), 0);
        assertEq(token3.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(newVault)), bal1);
        assertEq(token2.balanceOf(address(newVault)), bal2);
        assertEq(token3.balanceOf(address(newVault)), bal3);
    }

    function test_MigrateTokens_EmitsEvent() public {
        _pauseBoth();

        uint256[] memory expectedAmounts = new uint256[](3);
        expectedAmounts[0] = token.balanceOf(address(vault));
        expectedAmounts[1] = token2.balanceOf(address(vault));
        expectedAmounts[2] = token3.balanceOf(address(vault));

        vm.expectEmit(true, false, false, true);
        emit TokensMigrated(address(newVault), _tokenListAll(), expectedAmounts, 0);

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenListAll());
    }

    function test_MigrateTokens_WithNativeETH() public {
        _pauseBoth();
        vm.deal(address(vault), 5 ether);

        uint256 tokenBal = token.balanceOf(address(vault));

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenList1());

        assertEq(address(vault).balance, 0);
        assertEq(address(newVault).balance, 5 ether);
        assertEq(token.balanceOf(address(newVault)), tokenBal);
    }

    function test_MigrateTokens_FullWorkflow() public {
        _pauseBoth();

        uint256 bal1 = token.balanceOf(address(vault));
        uint256 bal2 = token2.balanceOf(address(vault));
        uint256 bal3 = token3.balanceOf(address(vault));

        // Step 1: Migrate tokens
        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenListAll());

        // Step 2: Update vault in gateway
        vm.prank(admin);
        gateway.updateVault(address(newVault));

        // Verify gateway points to new vault
        assertEq(gateway.VAULT(), address(newVault));
        assertTrue(gateway.hasRole(gateway.VAULT_ROLE(), address(newVault)));
        assertFalse(gateway.hasRole(gateway.VAULT_ROLE(), address(vault)));

        // Verify new vault has all the tokens
        assertEq(token.balanceOf(address(newVault)), bal1);
        assertEq(token2.balanceOf(address(newVault)), bal2);
        assertEq(token3.balanceOf(address(newVault)), bal3);

        // Step 3: Unpause gateway (requires OPERATOR_ROLE, held by admin at bootstrap)
        vm.prank(admin);
        gateway.unpause();
        assertFalse(gateway.paused());
    }

    // ==============================
    //    B. ACCESS CONTROL
    // ==============================

    function test_MigrateTokens_RevertNotAdmin() public {
        _pauseBoth();

        vm.prank(attacker);
        vm.expectRevert();
        vault.migrateTokens(address(newVault), _tokenList1());
    }

    function test_MigrateTokens_RevertVaultNotPaused() public {
        // Only pause gateway, not vault
        vm.prank(pauser);
        gateway.pause();

        vm.prank(admin);
        vm.expectRevert();
        vault.migrateTokens(address(newVault), _tokenList1());
    }

    function test_MigrateTokens_RevertGatewayNotPaused() public {
        // Only pause vault, not gateway
        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vm.expectRevert(Errors.GatewayNotPaused.selector);
        vault.migrateTokens(address(newVault), _tokenList1());
    }

    function test_MigrateTokens_RevertTSSCannotCall() public {
        _pauseBoth();

        vm.prank(tss);
        vm.expectRevert();
        vault.migrateTokens(address(newVault), _tokenList1());
    }

    // ==============================
    //    C. VALIDATION
    // ==============================

    function test_MigrateTokens_RevertZeroAddress() public {
        _pauseBoth();

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.migrateTokens(address(0), _tokenList1());
    }

    function test_MigrateTokens_RevertEmptyTokenList() public {
        _pauseBoth();

        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(Errors.EmptyTokenList.selector);
        vault.migrateTokens(address(newVault), empty);
    }

    // ==============================
    //    D. EDGE CASES
    // ==============================

    function test_MigrateTokens_ZeroBalanceToken_Skipped() public {
        _pauseBoth();

        MockERC20 emptyToken = new MockERC20("Empty", "EMP", 18, 0);
        address[] memory t = new address[](2);
        t[0] = address(token);
        t[1] = address(emptyToken);

        uint256 tokenBal = token.balanceOf(address(vault));

        vm.prank(admin);
        vault.migrateTokens(address(newVault), t);

        assertEq(token.balanceOf(address(newVault)), tokenBal);
        assertEq(emptyToken.balanceOf(address(newVault)), 0);
    }

    function test_MigrateTokens_AllZeroBalances() public {
        _pauseBoth();

        MockERC20 empty1 = new MockERC20("E1", "E1", 18, 0);
        MockERC20 empty2 = new MockERC20("E2", "E2", 18, 0);
        address[] memory t = new address[](2);
        t[0] = address(empty1);
        t[1] = address(empty2);

        vm.prank(admin);
        vault.migrateTokens(address(newVault), t);

        assertEq(empty1.balanceOf(address(newVault)), 0);
        assertEq(empty2.balanceOf(address(newVault)), 0);
    }

    function test_MigrateTokens_DuplicateTokenInList() public {
        _pauseBoth();

        uint256 bal = token.balanceOf(address(vault));
        address[] memory t = new address[](2);
        t[0] = address(token);
        t[1] = address(token);

        vm.prank(admin);
        vault.migrateTokens(address(newVault), t);

        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(newVault)), bal);
    }

    function test_MigrateTokens_NoNativeBalance() public {
        _pauseBoth();

        assertEq(address(vault).balance, 0);

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = token.balanceOf(address(vault));

        vm.expectEmit(true, false, false, true);
        emit TokensMigrated(address(newVault), _tokenList1(), expectedAmounts, 0);

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenList1());
    }

    function test_MigrateTokens_NativeTransferFails_Reverts() public {
        _pauseBoth();
        vm.deal(address(vault), 1 ether);

        EthRejecter rejecter = new EthRejecter();

        uint256 tokenBalBefore = token.balanceOf(address(vault));

        vm.prank(admin);
        vm.expectRevert(Errors.WithdrawFailed.selector);
        vault.migrateTokens(address(rejecter), _tokenList1());

        // Verify atomic rollback — tokens still in old vault
        assertEq(token.balanceOf(address(vault)), tokenBalBefore);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_MigrateTokens_CalledTwice_SecondIsNoOp() public {
        _pauseBoth();

        uint256 bal = token.balanceOf(address(vault));

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenList1());
        assertEq(token.balanceOf(address(newVault)), bal);

        // Second call — all zero balances
        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenList1());
        assertEq(token.balanceOf(address(newVault)), bal);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // ==============================
    //    E. REENTRANCY
    // ==============================

    function test_MigrateTokens_ReentrancyProtected() public {
        _pauseBoth();
        vm.deal(address(vault), 1 ether);

        ReentrantReceiver reentrant = new ReentrantReceiver(
            vault,
            address(newVault),
            _tokenList1()
        );

        vm.prank(admin);
        vm.expectRevert();
        vault.migrateTokens(address(reentrant), _tokenList1());
    }

    // ==============================
    //    F. STATE INTEGRITY
    // ==============================

    function test_MigrateTokens_RolesUnchanged() public {
        _pauseBoth();

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        bytes32 pauserRole = vault.PAUSER_ROLE();
        bytes32 tssRole = vault.TSS_ROLE();

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenListAll());

        assertTrue(vault.hasRole(adminRole, admin));
        assertTrue(vault.hasRole(pauserRole, pauser));
        assertTrue(vault.hasRole(tssRole, tss));
    }

    function test_MigrateTokens_GatewayPointerUnchanged() public {
        _pauseBoth();

        address gwBefore = address(vault.gateway());

        vm.prank(admin);
        vault.migrateTokens(address(newVault), _tokenListAll());

        assertEq(address(vault.gateway()), gwBefore);
    }
}
