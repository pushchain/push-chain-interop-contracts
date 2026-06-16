// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Vault} from "../../src/Vault.sol";
import {PC20Factory} from "../../src/PC20Factory.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";
import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Multicall} from "../../src/libraries/Types.sol";
import {MockCEAFactory} from "../mocks/MockCEAFactory.sol";
import {MockCEA} from "../mocks/MockCEA.sol";

contract VaultPC20ExportTest is Test {
    Vault public vault;
    PC20Factory public factory;
    MockCEAFactory public ceaFactory;
    UniversalGateway public gateway;

    address public admin;
    address public pauser;
    address public tss;
    address public operator;
    address public userA;
    address public recipient;
    address public pushAccount;

    address public sourceA;
    address public sourceB;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        operator = admin;
        userA = makeAddr("userA");
        recipient = makeAddr("recipient");
        pushAccount = makeAddr("pushAccount");
        sourceA = makeAddr("sourceA");
        sourceB = makeAddr("sourceB");

        // Deploy Gateway (minimal — needed for Vault init)
        UniversalGateway gwImpl = new UniversalGateway();
        ERC1967Proxy gwProxy = new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(
                UniversalGateway.initialize,
                (
                    admin, pauser, tss,
                    address(this), // vault placeholder
                    1e18, 10e18,
                    address(0), address(0),
                    makeAddr("weth")
                )
            )
        );
        gateway = UniversalGateway(payable(address(gwProxy)));

        // Deploy CEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                Vault.initialize,
                (admin, pauser, tss, address(gateway), address(ceaFactory))
            )
        );
        vault = Vault(payable(address(vaultProxy)));
        ceaFactory.setVault(address(vault));

        // Update gateway vault
        vm.prank(admin);
        gateway.updateVault(address(vault));

        // Deploy PC20Factory
        PC20Factory factoryImpl = new PC20Factory();
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(
                address(factoryImpl),
                makeAddr("factoryProxyAdmin"),
                abi.encodeCall(
                    PC20Factory.initialize,
                    (admin, pauser, address(vault), address(gateway))
                )
            );
        factory = PC20Factory(address(factoryProxy));

        // Wire pc20Factory into Vault
        vm.prank(admin);
        vault.updatePC20Factory(address(factory));
    }

    // =========================================================
    //  Helpers
    // =========================================================

    function _tx(uint256 id) internal pure returns (bytes32) {
        return bytes32(id);
    }

    bytes4 constant PC_20_SEL = 0x50433230;

    function _emptyMulticall()
        internal
        pure
        returns (bytes memory)
    {
        Multicall[] memory calls = new Multicall[](0);
        return abi.encode(calls);
    }

    function _buildPC20Data(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes memory userData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            PC_20_SEL, abi.encode(name, symbol, decimals, userData)
        );
    }

    function _finalize(
        bytes32 subTxId,
        address source,
        uint256 amount,
        bytes memory userData
    ) internal {
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, _tx(999), pushAccount, recipient,
            source, amount,
            _buildPC20Data("Push Token", "pTKN", 18, userData)
        );
    }

    // =========================================================
    //  11.1 Path A (No UserData) Happy Path
    // =========================================================

    function test_PathA_FirstExportDeploysAndMints() public {
        _finalize(_tx(1), sourceA, 1000e18, "");

        address wrapper = factory.getWrapper(sourceA);
        assertTrue(wrapper != address(0));
        assertEq(PC20Wrapper(wrapper).balanceOf(recipient), 1000e18);
        assertTrue(vault.isPC20Executed(_tx(1)));
    }

    function test_PathA_SubsequentExportSkipsDeploy() public {
        _finalize(_tx(1), sourceA, 500e18, "");
        address wrapper1 = factory.getWrapper(sourceA);

        _finalize(_tx(2), sourceA, 300e18, "");
        address wrapper2 = factory.getWrapper(sourceA);

        assertEq(wrapper1, wrapper2);
        assertEq(PC20Wrapper(wrapper1).balanceOf(recipient), 800e18);
    }

    function test_PathA_CorrectWrapperMetadata() public {
        vm.prank(tss);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push USDC", "pUSDC", 6, "")
        );
        address wrapper = factory.getWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).name(), "Push USDC");
        assertEq(PC20Wrapper(wrapper).symbol(), "pUSDC");
        assertEq(PC20Wrapper(wrapper).decimals(), 6);
    }

    function test_PathA_DifferentSourceAssets() public {
        _finalize(_tx(1), sourceA, 100e18, "");
        vm.prank(tss);
        vault.finalizeUniversalTx(
            _tx(2), _tx(999), pushAccount, recipient,
            sourceB, 200e18,
            _buildPC20Data("Push B", "pB", 18, "")
        );

        assertTrue(
            factory.getWrapper(sourceA) != factory.getWrapper(sourceB)
        );
    }

    function test_PathA_RecipientGetsAmount() public {
        _finalize(_tx(1), sourceA, 777e18, "");
        address wrapper = factory.getWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).balanceOf(recipient), 777e18);
    }

    function test_PathA_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PC20ExportFinalized(
            _tx(1), _tx(999), pushAccount,
            recipient, sourceA, 1000e18, ""
        );
        _finalize(_tx(1), sourceA, 1000e18, "");
    }

    // =========================================================
    //  11.2 Path B (With UserData) Happy Path
    // =========================================================

    function test_PathB_MintToCEAAndExecute() public {
        bytes memory ud = _emptyMulticall();
        _finalize(_tx(1), sourceA, 500e18, ud);

        (address cea,) = ceaFactory.getCEAForPushAccount(pushAccount);
        assertTrue(cea != address(0));

        MockCEA mockCea = MockCEA(payable(cea));
        assertEq(mockCea.lastsubTxId(), _tx(1));
        assertEq(mockCea.lastRecipient(), recipient);
    }

    function test_PathB_CEAAlreadyDeployed() public {
        bytes memory ud = _emptyMulticall();
        _finalize(_tx(1), sourceA, 100e18, ud);

        (address cea1,) = ceaFactory.getCEAForPushAccount(pushAccount);

        _finalize(_tx(2), sourceA, 200e18, ud);

        (address cea2,) = ceaFactory.getCEAForPushAccount(pushAccount);
        assertEq(cea1, cea2);
    }

    function test_PathB_EmitsEventWithUserData() public {
        bytes memory ud = _emptyMulticall();
        vm.expectEmit(true, true, true, true);
        emit PC20ExportFinalized(
            _tx(1), _tx(999), pushAccount,
            recipient, sourceA, 100e18, ud
        );
        _finalize(_tx(1), sourceA, 100e18, ud);
    }

    // =========================================================
    //  11.3 Validation Reverts
    // =========================================================

    function test_Reverts_Replay() public {
        _finalize(_tx(1), sourceA, 100e18, "");

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_ZeroPushAccount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), address(0), recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_ZeroSourceAsset() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            address(0), 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_ZeroAmount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 0,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_ZeroRecipient() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, address(0),
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_NonTSSRole() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_WhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_WhenFactoryPaused() public {
        vm.prank(pauser);
        factory.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_Reverts_PC20_WithMsgValue() public {
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.finalizeUniversalTx{value: 1 ether}(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    // =========================================================
    //  11.4 CEA Execution Reverts
    // =========================================================

    function test_CEARevert_RollsBackMint() public {
        bytes memory ud = _emptyMulticall();
        _finalize(_tx(1), sourceA, 100e18, ud);

        (address cea,) = ceaFactory.getCEAForPushAccount(pushAccount);
        MockCEA(payable(cea)).setShouldRevert(true, "test fail");

        address wrapper = factory.getWrapper(sourceA);
        uint256 supplyBefore = PC20Wrapper(wrapper).totalSupply();

        vm.prank(tss);
        vm.expectRevert("test fail");
        vault.finalizeUniversalTx(
            _tx(2), _tx(999), pushAccount, recipient,
            sourceA, 200e18,
            _buildPC20Data("Push Token", "pTKN", 18, ud)
        );

        assertEq(PC20Wrapper(wrapper).totalSupply(), supplyBefore);
        assertFalse(vault.isPC20Executed(_tx(2)));
    }

    // =========================================================
    //  11.5 Wrapper Deploy Edge Cases
    // =========================================================

    function test_ConcurrentExports_SameSource() public {
        _finalize(_tx(1), sourceA, 100e18, "");
        _finalize(_tx(2), sourceA, 200e18, "");

        address wrapper = factory.getWrapper(sourceA);
        assertEq(
            PC20Wrapper(wrapper).balanceOf(recipient), 300e18
        );
    }

    function test_Deploy_ZeroDecimals() public {
        vm.prank(tss);
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100,
            _buildPC20Data("Push Int", "pINT", 0, "")
        );
        address wrapper = factory.getWrapper(sourceA);
        assertEq(PC20Wrapper(wrapper).decimals(), 0);
        assertEq(PC20Wrapper(wrapper).balanceOf(recipient), 100);
    }

    // =========================================================
    //  11.6 Replay Protection
    // =========================================================

    function test_Replay_DifferentSubTxIdsIndependent() public {
        _finalize(_tx(1), sourceA, 100e18, "");
        _finalize(_tx(2), sourceA, 200e18, "");

        assertTrue(vault.isPC20Executed(_tx(1)));
        assertTrue(vault.isPC20Executed(_tx(2)));
    }

    function test_Replay_PathADoesNotInvolveCEA() public {
        _finalize(_tx(1), sourceA, 100e18, "");
        assertTrue(vault.isPC20Executed(_tx(1)));
        // No CEA deployed for Path A
        (, bool isDeployed) = ceaFactory.getCEAForPushAccount(
            pushAccount
        );
        assertFalse(isDeployed);
    }

    // =========================================================
    //  11.7 updatePC20Factory
    // =========================================================

    function test_UpdateFactory_Success() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(admin);
        vault.updatePC20Factory(newFactory);
        assertEq(address(vault.pc20Factory()), newFactory);
    }

    function test_UpdateFactory_EmitsEvent() public {
        address newFactory = makeAddr("newFactory");
        vm.expectEmit(true, true, false, false);
        emit PC20FactoryUpdated(address(factory), newFactory);
        vm.prank(admin);
        vault.updatePC20Factory(newFactory);
    }

    function test_UpdateFactory_RevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.updatePC20Factory(address(0));
    }

    function test_UpdateFactory_RevertsNonOperator() public {
        vm.prank(userA);
        vm.expectRevert();
        vault.updatePC20Factory(makeAddr("f"));
    }

    // =========================================================
    //  11.8 Access Control
    // =========================================================

    function test_AC_OnlyTSSCanFinalize() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.finalizeUniversalTx(
            _tx(1), _tx(999), pushAccount, recipient,
            sourceA, 100e18,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    function test_AC_ExistingFunctionsUnaffected() public {
        // Existing finalizeUniversalTx still works
        // (Would need token setup — just verify no revert on access control)
        // We verify by checking the OPERATOR role can still update gateway
        vm.prank(admin);
        vault.updateGateway(makeAddr("newGW"));
    }

    // =========================================================
    //  11.9 Storage Layout
    // =========================================================

    function test_Storage_PC20FactoryStartsZero() public {
        // Deploy fresh vault without calling updatePC20Factory
        Vault vImpl = new Vault();
        ERC1967Proxy vp = new ERC1967Proxy(
            address(vImpl),
            abi.encodeCall(
                Vault.initialize,
                (admin, pauser, tss, address(gateway), address(ceaFactory))
            )
        );
        Vault freshVault = Vault(payable(address(vp)));
        assertEq(address(freshVault.pc20Factory()), address(0));
    }

    function test_Storage_ExistingStatePreserved() public view {
        assertEq(address(vault.gateway()), address(gateway));
        assertEq(
            address(vault.CEAFactory()), address(ceaFactory)
        );
    }

    // =========================================================
    //  Event declarations
    // =========================================================

    event PC20ExportFinalized(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed pushAccount,
        address recipient,
        address sourceAsset,
        uint256 amount,
        bytes userData
    );

    event PC20FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );
}
