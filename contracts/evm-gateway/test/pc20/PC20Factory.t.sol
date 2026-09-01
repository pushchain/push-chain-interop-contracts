// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from
    "@openzeppelin/contracts/access/IAccessControl.sol";
import {PC20Factory} from "../../src/PC20Factory.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract PC20FactoryTest is Test {
    PC20Factory public factory;

    address public admin;
    address public pauser;
    address public vaultAddr;
    address public gatewayAddr;
    address public operator;
    address public userA;
    address public userB;

    address public sourceA;
    address public sourceB;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        vaultAddr = makeAddr("vault");
        gatewayAddr = makeAddr("gateway");
        operator = admin;
        userA = makeAddr("userA");
        userB = makeAddr("userB");
        sourceA = makeAddr("sourceA");
        sourceB = makeAddr("sourceB");

        PC20Factory impl = new PC20Factory();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("proxyAdmin"),
            abi.encodeCall(
                PC20Factory.initialize,
                (admin, pauser, vaultAddr, gatewayAddr)
            )
        );
        factory = PC20Factory(address(proxy));
    }

    // =========================================================
    //  Helpers
    // =========================================================

    function _deployWrapper(
        address source,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal returns (address) {
        vm.prank(vaultAddr);
        return factory.deployWrapper(source, name, symbol, decimals);
    }

    function _deployDefaultWrapper()
        internal
        returns (address)
    {
        return _deployWrapper(sourceA, "Push Token", "pTKN", 18);
    }

    // =========================================================
    //  13.1 initialize
    // =========================================================

    function test_Init_RolesGranted() public view {
        assertTrue(
            factory.hasRole(factory.ROLE_MANAGER_ROLE(), admin)
        );
        assertTrue(factory.hasRole(factory.OPERATOR_ROLE(), admin));
        assertTrue(factory.hasRole(factory.PAUSER_ROLE(), pauser));
        assertTrue(factory.hasRole(factory.VAULT_ROLE(), vaultAddr));
        assertTrue(
            factory.hasRole(factory.GATEWAY_ROLE(), gatewayAddr)
        );
    }

    function test_Init_VaultGatewayStored() public view {
        assertEq(factory.vault(), vaultAddr);
        assertEq(factory.gateway(), gatewayAddr);
    }

    function test_Init_PauserCanPause() public {
        vm.prank(pauser);
        factory.pause();
        assertTrue(factory.paused());
    }

    function test_Init_PauserCannotUnpause() public {
        vm.prank(pauser);
        factory.pause();

        vm.prank(pauser);
        vm.expectRevert();
        factory.unpause();
    }

    function test_Init_RevertsOnZeroAdmin() public {
        PC20Factory impl = new PC20Factory();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("pa2"),
            abi.encodeCall(
                PC20Factory.initialize,
                (address(0), pauser, vaultAddr, gatewayAddr)
            )
        );
    }

    function test_Init_RevertsOnZeroPauser() public {
        PC20Factory impl = new PC20Factory();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("pa2"),
            abi.encodeCall(
                PC20Factory.initialize,
                (admin, address(0), vaultAddr, gatewayAddr)
            )
        );
    }

    function test_Init_RevertsOnZeroVault() public {
        PC20Factory impl = new PC20Factory();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("pa2"),
            abi.encodeCall(
                PC20Factory.initialize,
                (admin, pauser, address(0), gatewayAddr)
            )
        );
    }

    function test_Init_RevertsOnZeroGateway() public {
        PC20Factory impl = new PC20Factory();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            makeAddr("pa2"),
            abi.encodeCall(
                PC20Factory.initialize,
                (admin, pauser, vaultAddr, address(0))
            )
        );
    }

    function test_Init_CannotInitTwice() public {
        vm.expectRevert();
        factory.initialize(admin, pauser, vaultAddr, gatewayAddr);
    }

    function test_Init_RoleAdminHierarchy() public view {
        assertEq(
            factory.getRoleAdmin(factory.VAULT_ROLE()),
            factory.ROLE_MANAGER_ROLE()
        );
        assertEq(
            factory.getRoleAdmin(factory.GATEWAY_ROLE()),
            factory.ROLE_MANAGER_ROLE()
        );
        assertEq(
            factory.getRoleAdmin(factory.OPERATOR_ROLE()),
            factory.ROLE_MANAGER_ROLE()
        );
        assertEq(
            factory.getRoleAdmin(factory.PAUSER_ROLE()),
            factory.ROLE_MANAGER_ROLE()
        );
    }

    // =========================================================
    //  13.2 deployWrapper — Happy Path
    // =========================================================

    function test_Deploy_Success() public {
        address wrapper = _deployDefaultWrapper();
        assertEq(factory.sourceToWrapper(sourceA), wrapper);
        assertEq(factory.wrapperToSource(wrapper), sourceA);
        assertTrue(wrapper != address(0));
    }

    function test_Deploy_WrapperMetadata() public {
        address wrapper = _deployDefaultWrapper();
        PC20Wrapper w = PC20Wrapper(wrapper);
        assertEq(w.name(), "Push Token");
        assertEq(w.symbol(), "pTKN");
        assertEq(w.decimals(), 18);
        assertEq(w.SOURCE_ASSET(), sourceA);
        assertEq(w.factory(), address(factory));
    }

    function test_Deploy_EmitsEvent() public {
        vm.prank(vaultAddr);
        vm.expectEmit(true, false, false, true);
        emit PC20WrapperDeployed(
            sourceA, address(0), "Push Token", "pTKN", 18
        );
        factory.deployWrapper(sourceA, "Push Token", "pTKN", 18);
    }

    function test_Deploy_Decimals0() public {
        address wrapper = _deployWrapper(
            sourceA, "Push NFT", "pNFT", 0
        );
        assertEq(PC20Wrapper(wrapper).decimals(), 0);
    }

    function test_Deploy_Decimals6() public {
        address wrapper = _deployWrapper(
            sourceA, "Push USDC", "pUSDC", 6
        );
        assertEq(PC20Wrapper(wrapper).decimals(), 6);
    }

    function test_Deploy_MaxNameLength() public {
        bytes memory longName = new bytes(64);
        for (uint256 i; i < 64; i++) longName[i] = "A";
        _deployWrapper(sourceA, string(longName), "pTKN", 18);
    }

    function test_Deploy_MaxSymbolLength() public {
        bytes memory longSym = new bytes(32);
        for (uint256 i; i < 32; i++) longSym[i] = "S";
        _deployWrapper(sourceA, "Name", string(longSym), 18);
    }

    function test_Deploy_MultipleSources() public {
        address wA = _deployWrapper(
            sourceA, "Push A", "pA", 18
        );
        address wB = _deployWrapper(
            sourceB, "Push B", "pB", 18
        );
        assertTrue(wA != wB);
        assertEq(factory.sourceToWrapper(sourceA), wA);
        assertEq(factory.sourceToWrapper(sourceB), wB);
    }

    function test_Deploy_ReturnMatchesMapping() public {
        address wrapper = _deployDefaultWrapper();
        assertEq(wrapper, factory.sourceToWrapper(sourceA));
    }

    // =========================================================
    //  13.3 deployWrapper — Reverts
    // =========================================================

    function test_Deploy_RevertsOnZeroSource() public {
        vm.prank(vaultAddr);
        vm.expectRevert(PC20Factory.InvalidSourceAsset.selector);
        factory.deployWrapper(
            address(0), "Name", "SYM", 18
        );
    }

    function test_Deploy_RevertsOnDuplicate() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                PC20Factory.WrapperAlreadyDeployed.selector,
                sourceA
            )
        );
        factory.deployWrapper(sourceA, "Push Token", "pTKN", 18);
    }

    function test_Deploy_RevertsOnEmptyName() public {
        vm.prank(vaultAddr);
        vm.expectRevert(PC20Factory.EmptyName.selector);
        factory.deployWrapper(sourceA, "", "pTKN", 18);
    }

    function test_Deploy_RevertsOnNameTooLong() public {
        bytes memory longName = new bytes(65);
        for (uint256 i; i < 65; i++) longName[i] = "A";
        vm.prank(vaultAddr);
        vm.expectRevert(PC20Factory.NameTooLong.selector);
        factory.deployWrapper(sourceA, string(longName), "pTKN", 18);
    }

    function test_Deploy_RevertsOnEmptySymbol() public {
        vm.prank(vaultAddr);
        vm.expectRevert(PC20Factory.EmptySymbol.selector);
        factory.deployWrapper(sourceA, "Name", "", 18);
    }

    function test_Deploy_RevertsOnSymbolTooLong() public {
        bytes memory longSym = new bytes(33);
        for (uint256 i; i < 33; i++) longSym[i] = "S";
        vm.prank(vaultAddr);
        vm.expectRevert(PC20Factory.SymbolTooLong.selector);
        factory.deployWrapper(sourceA, "Name", string(longSym), 18);
    }

    function test_Deploy_RevertsFromNonVaultRole() public {
        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.deployWrapper(sourceA, "Name", "SYM", 18);
    }

    function test_Deploy_RevertsWhenPaused() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.deployWrapper(sourceA, "Name", "SYM", 18);
    }

    // =========================================================
    //  13.4 mintFor — Happy Path
    // =========================================================

    function test_MintFor_Success() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);
        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(
            PC20Wrapper(wrapper).balanceOf(userA), 1000e18
        );
    }

    function test_MintFor_Accumulates() public {
        _deployDefaultWrapper();
        vm.startPrank(vaultAddr);
        factory.mintFor(sourceA, userA, 100e18);
        factory.mintFor(sourceA, userA, 200e18);
        vm.stopPrank();
        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(userA), 300e18);
    }

    function test_MintFor_DifferentRecipients() public {
        _deployDefaultWrapper();
        vm.startPrank(vaultAddr);
        factory.mintFor(sourceA, userA, 100e18);
        factory.mintFor(sourceA, userB, 200e18);
        vm.stopPrank();
        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(userA), 100e18);
        assertEq(PC20Wrapper(wrapper).balanceOf(userB), 200e18);
    }

    // =========================================================
    //  13.5 mintFor — Reverts
    // =========================================================

    function test_MintFor_RevertsUndeployed() public {
        vm.prank(vaultAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                PC20Factory.WrapperNotDeployed.selector,
                sourceA
            )
        );
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_MintFor_RevertsFromNonVaultRole() public {
        _deployDefaultWrapper();
        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_MintFor_RevertsWhenPaused() public {
        _deployDefaultWrapper();
        vm.prank(pauser);
        factory.pause();
        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_MintFor_RevertsToAddressZero() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, address(0), 100e18);
    }

    // =========================================================
    //  13.6 burnFrom — Happy Path
    // =========================================================

    function test_BurnFrom_Success() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(gatewayAddr);
        factory.burnFrom(sourceA, userA, 400e18);

        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(userA), 600e18);
    }

    function test_BurnFrom_AllTokens() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(gatewayAddr);
        factory.burnFrom(sourceA, userA, 1000e18);

        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(userA), 0);
    }

    function test_BurnFrom_Multiple() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.startPrank(gatewayAddr);
        factory.burnFrom(sourceA, userA, 200e18);
        factory.burnFrom(sourceA, userA, 300e18);
        vm.stopPrank();

        address wrapper = factory.sourceToWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(userA), 500e18);
    }

    // =========================================================
    //  13.7 burnFrom — Reverts
    // =========================================================

    function test_BurnFrom_RevertsUndeployed() public {
        vm.prank(gatewayAddr);
        vm.expectRevert(
            abi.encodeWithSelector(
                PC20Factory.WrapperNotDeployed.selector,
                sourceA
            )
        );
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_BurnFrom_RevertsFromNonGatewayRole() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_BurnFrom_RevertsWhenPaused() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(pauser);
        factory.pause();

        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_BurnFrom_RevertsExceedsBalance() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 100e18);

        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 200e18);
    }

    // =========================================================
    //  13.8 getWrapper
    // =========================================================

    function test_GetWrapper_ReturnsDeployed() public {
        address wrapper = _deployDefaultWrapper();
        assertEq(factory.getWrapper(sourceA), wrapper);
    }

    function test_GetWrapper_ReturnsZeroForUndeployed() public view {
        assertEq(factory.getWrapper(sourceA), address(0));
    }

    // =========================================================
    //  13.9 isPC20Wrapper
    // =========================================================

    function test_IsPC20Wrapper_TrueForDeployed() public {
        address wrapper = _deployDefaultWrapper();
        assertTrue(factory.isPC20Wrapper(wrapper));
    }

    function test_IsPC20Wrapper_FalseForUndeployed() public view {
        assertFalse(factory.isPC20Wrapper(address(0xdead)));
    }

    function test_IsPC20Wrapper_FalseForZero() public view {
        assertFalse(factory.isPC20Wrapper(address(0)));
    }

    function test_IsPC20Wrapper_FalseForSourceAsset() public {
        _deployDefaultWrapper();
        assertFalse(factory.isPC20Wrapper(sourceA));
    }

    // =========================================================
    //  13.10 computeWrapperAddress
    // =========================================================

    function test_ComputeAddress_MatchesActual() public {
        address predicted = factory.computeWrapperAddress(sourceA);
        address actual = _deployDefaultWrapper();
        assertEq(predicted, actual);
    }

    function test_ComputeAddress_DifferentSources() public view {
        address pA = factory.computeWrapperAddress(sourceA);
        address pB = factory.computeWrapperAddress(sourceB);
        assertTrue(pA != pB);
    }

    function test_ComputeAddress_Deterministic() public view {
        address p1 = factory.computeWrapperAddress(sourceA);
        address p2 = factory.computeWrapperAddress(sourceA);
        assertEq(p1, p2);
    }

    function test_ComputeAddress_IndependentOfMetadata() public view {
        address p = factory.computeWrapperAddress(sourceA);
        assertNotEq(p, address(0));
    }

    // =========================================================
    //  13.11 updateVault
    // =========================================================

    function test_UpdateVault_Success() public {
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        factory.updateVault(newVault);
        assertEq(factory.vault(), newVault);
    }

    function test_UpdateVault_OldLosesRole() public {
        _deployDefaultWrapper();
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        factory.updateVault(newVault);

        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_UpdateVault_NewHasRole() public {
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        factory.updateVault(newVault);

        vm.prank(newVault);
        factory.deployWrapper(sourceA, "Push Token", "pTKN", 18);
    }

    function test_UpdateVault_EmitsEvent() public {
        address newVault = makeAddr("newVault");
        vm.expectEmit(true, true, false, false);
        emit VaultUpdated(vaultAddr, newVault);
        vm.prank(admin);
        factory.updateVault(newVault);
    }

    function test_UpdateVault_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.updateVault(address(0));
    }

    function test_UpdateVault_RevertsFromNonOperator() public {
        vm.prank(pauser);
        vm.expectRevert();
        factory.updateVault(makeAddr("v"));
    }

    // =========================================================
    //  13.12 updateGateway
    // =========================================================

    function test_UpdateGateway_Success() public {
        address newGW = makeAddr("newGateway");
        vm.prank(admin);
        factory.updateGateway(newGW);
        assertEq(factory.gateway(), newGW);
    }

    function test_UpdateGateway_OldLosesRole() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        address newGW = makeAddr("newGateway");
        vm.prank(admin);
        factory.updateGateway(newGW);

        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_UpdateGateway_NewHasRole() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        address newGW = makeAddr("newGateway");
        vm.prank(admin);
        factory.updateGateway(newGW);

        vm.prank(newGW);
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_UpdateGateway_EmitsEvent() public {
        address newGW = makeAddr("newGateway");
        vm.expectEmit(true, true, false, false);
        emit GatewayUpdated(gatewayAddr, newGW);
        vm.prank(admin);
        factory.updateGateway(newGW);
    }

    function test_UpdateGateway_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.updateGateway(address(0));
    }

    function test_UpdateGateway_RevertsFromNonOperator() public {
        vm.prank(pauser);
        vm.expectRevert();
        factory.updateGateway(makeAddr("gw"));
    }

    // =========================================================
    //  13.13 pause / unpause
    // =========================================================

    function test_Pause_BlocksDeploy() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.deployWrapper(sourceA, "Name", "SYM", 18);
    }

    function test_Pause_BlocksMint() public {
        _deployDefaultWrapper();
        vm.prank(pauser);
        factory.pause();
        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_Pause_BlocksBurn() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(pauser);
        factory.pause();

        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_Unpause_ReenablesOps() public {
        _deployDefaultWrapper();
        vm.prank(pauser);
        factory.pause();
        vm.prank(admin);
        factory.unpause();

        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 100e18);
    }

    function test_Pause_OnlyPauserCanPause() public {
        vm.prank(userA);
        vm.expectRevert();
        factory.pause();
    }

    function test_Unpause_OnlyOperatorCanUnpause() public {
        vm.prank(pauser);
        factory.pause();
        vm.prank(pauser);
        vm.expectRevert();
        factory.unpause();
    }

    // =========================================================
    //  13.14 Role Separation
    // =========================================================

    function test_VaultRoleCannotBurn() public {
        _deployDefaultWrapper();
        vm.prank(vaultAddr);
        factory.mintFor(sourceA, userA, 1000e18);

        vm.prank(vaultAddr);
        vm.expectRevert();
        factory.burnFrom(sourceA, userA, 100e18);
    }

    function test_GatewayRoleCannotDeploy() public {
        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.deployWrapper(sourceA, "Name", "SYM", 18);
    }

    function test_GatewayRoleCannotMint() public {
        _deployDefaultWrapper();
        vm.prank(gatewayAddr);
        vm.expectRevert();
        factory.mintFor(sourceA, userA, 100e18);
    }

    // =========================================================
    //  13.15 Mapping Consistency
    // =========================================================

    function test_MappingsSymmetric() public {
        address wA = _deployWrapper(sourceA, "A", "pA", 18);
        address wB = _deployWrapper(sourceB, "B", "pB", 18);

        assertEq(factory.sourceToWrapper(sourceA), wA);
        assertEq(factory.sourceToWrapper(sourceB), wB);
        assertEq(factory.wrapperToSource(wA), sourceA);
        assertEq(factory.wrapperToSource(wB), sourceB);
    }

    // =========================================================
    //  Event declarations for expectEmit
    // =========================================================

    event PC20WrapperDeployed(
        address indexed sourceAsset,
        address indexed wrapper,
        string name,
        string symbol,
        uint8 decimals
    );

    event VaultUpdated(
        address indexed oldVault,
        address indexed newVault
    );

    event GatewayUpdated(
        address indexed oldGateway,
        address indexed newGateway
    );
}
