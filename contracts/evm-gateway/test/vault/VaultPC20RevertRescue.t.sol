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
import {RevertInstructions} from "../../src/libraries/Types.sol";
import {MockCEAFactory} from "../mocks/MockCEAFactory.sol";

contract VaultPC20RevertRescueTest is Test {
    Vault public vault;
    PC20Factory public factory;
    MockCEAFactory public ceaFactory;
    UniversalGateway public gateway;

    address public admin;
    address public pauser;
    address public tss;
    address public pushAccount;
    address public recipient;
    address public userA;

    address public sourceA;
    address public wrapperA;

    bytes32 constant SUB_TX_EXPORT = bytes32(uint256(1));
    bytes32 constant SUB_TX_REVERT = bytes32(uint256(100));
    bytes32 constant SUB_TX_RESCUE = bytes32(uint256(200));
    bytes32 constant UNIVERSAL_TX_ID = bytes32(uint256(42));
    bytes4 constant PC_20_SEL = 0x50433230;

    event UniversalTxReverted(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    event FundsRescued(
        bytes32 indexed subTxId,
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        pushAccount = makeAddr("pushAccount");
        recipient = makeAddr("recipient");
        userA = makeAddr("userA");
        sourceA = makeAddr("sourceA");

        // Deploy Gateway
        UniversalGateway gwImpl = new UniversalGateway();
        ERC1967Proxy gwProxy = new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(
                UniversalGateway.initialize,
                (
                    admin, pauser, tss,
                    address(this),
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

        // Wire pc20Factory into Vault and Gateway
        vm.prank(admin);
        vault.updatePC20Factory(address(factory));
        vm.prank(admin);
        gateway.updatePC20Factory(address(factory));

        // Deploy a wrapper via a PC20 export so we have a
        // real wrapper token for revert/rescue tests
        _doPC20Export(SUB_TX_EXPORT, sourceA, 1000e18);
        wrapperA = factory.getWrapper(sourceA);
        assertTrue(wrapperA != address(0));
    }

    // =========================================================
    //  Helpers
    // =========================================================

    function _tx(uint256 id) internal pure returns (bytes32) {
        return bytes32(id);
    }

    string constant DEST_CHAIN = "eip155:1";

    function _buildPC20Data(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes memory userData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            PC_20_SEL,
            abi.encode(DEST_CHAIN, name, symbol, decimals),
            userData
        );
    }

    function _doPC20Export(
        bytes32 subTxId,
        address source,
        uint256 amount
    ) internal {
        vm.prank(tss);
        vault.finalizeUniversalTx(
            subTxId, UNIVERSAL_TX_ID, pushAccount, recipient,
            source, amount,
            _buildPC20Data("Push Token", "pTKN", 18, "")
        );
    }

    // =========================================================
    //  REVERT — PC20 Wrapper Happy Path
    // =========================================================

    function test_Revert_PC20Wrapper_Success() public {
        uint256 amount = 500e18;
        uint256 recipientBefore = PC20Wrapper(wrapperA).balanceOf(recipient);
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        assertEq(
            PC20Wrapper(wrapperA).balanceOf(recipient),
            recipientBefore + amount
        );
    }

    function test_Revert_PC20Wrapper_VaultHoldsZeroBalance() public {
        assertEq(
            PC20Wrapper(wrapperA).balanceOf(address(vault)), 0
        );

        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );

        assertEq(PC20Wrapper(wrapperA).balanceOf(recipient), 100e18);
    }

    function test_Revert_PC20Wrapper_EmitsEvent() public {
        uint256 amount = 250e18;
        RevertInstructions memory ri = RevertInstructions(
            recipient, "pc20 revert"
        );

        vm.expectEmit(true, true, true, true);
        emit UniversalTxReverted(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );
    }

    function test_Revert_PC20Wrapper_MintedViaFactory() public {
        uint256 supplyBefore = PC20Wrapper(wrapperA).totalSupply();
        uint256 amount = 300e18;
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        assertEq(
            PC20Wrapper(wrapperA).totalSupply(),
            supplyBefore + amount
        );
    }

    // =========================================================
    //  RESCUE — PC20 Wrapper Happy Path
    // =========================================================

    function test_Rescue_PC20Wrapper_Success() public {
        uint256 amount = 500e18;
        uint256 recipientBefore = PC20Wrapper(wrapperA).balanceOf(recipient);
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        assertEq(
            PC20Wrapper(wrapperA).balanceOf(recipient),
            recipientBefore + amount
        );
    }

    function test_Rescue_PC20Wrapper_VaultHoldsZeroBalance() public {
        assertEq(
            PC20Wrapper(wrapperA).balanceOf(address(vault)), 0
        );

        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );

        assertEq(PC20Wrapper(wrapperA).balanceOf(recipient), 100e18);
    }

    function test_Rescue_PC20Wrapper_EmitsEvent() public {
        uint256 amount = 250e18;
        RevertInstructions memory ri = RevertInstructions(
            recipient, "pc20 rescue"
        );

        vm.expectEmit(true, true, true, true);
        emit FundsRescued(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );
    }

    function test_Rescue_PC20Wrapper_MintedViaFactory() public {
        uint256 supplyBefore = PC20Wrapper(wrapperA).totalSupply();
        uint256 amount = 300e18;
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, amount, ri
        );

        assertEq(
            PC20Wrapper(wrapperA).totalSupply(),
            supplyBefore + amount
        );
    }

    // =========================================================
    //  Validation — Shared with standard revert/rescue
    // =========================================================

    function test_Revert_PC20Wrapper_ZeroAmountReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 0, ri
        );
    }

    function test_Revert_PC20Wrapper_ZeroRecipientReverts() public {
        RevertInstructions memory ri = RevertInstructions(address(0), "");
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Rescue_PC20Wrapper_ZeroAmountReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 0, ri
        );
    }

    function test_Rescue_PC20Wrapper_ZeroRecipientReverts() public {
        RevertInstructions memory ri = RevertInstructions(address(0), "");
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Revert_PC20Wrapper_NonTSSReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(userA);
        vm.expectRevert();
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Rescue_PC20Wrapper_NonTSSReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(userA);
        vm.expectRevert();
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Revert_PC20Wrapper_WhenPausedReverts() public {
        vm.prank(pauser);
        vault.pause();

        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vm.expectRevert();
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Revert_PC20Wrapper_MsgValueReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx{value: 1 ether}(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Rescue_PC20Wrapper_MsgValueReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds{value: 1 ether}(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    // =========================================================
    //  Gateway replay protection works for PC20 reverts
    // =========================================================

    function test_Revert_PC20Wrapper_ReplayProtection() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Rescue_PC20Wrapper_ReplayProtection() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    // =========================================================
    //  PC20Factory paused blocks revert mint
    // =========================================================

    function test_Revert_PC20Wrapper_FactoryPausedReverts() public {
        vm.prank(pauser);
        factory.pause();

        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vm.expectRevert();
        vault.revertUniversalTx(
            SUB_TX_REVERT, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }

    function test_Rescue_PC20Wrapper_FactoryPausedReverts() public {
        vm.prank(pauser);
        factory.pause();

        RevertInstructions memory ri = RevertInstructions(recipient, "");
        vm.prank(tss);
        vm.expectRevert();
        vault.rescueFunds(
            SUB_TX_RESCUE, UNIVERSAL_TX_ID, wrapperA, 100e18, ri
        );
    }
}
