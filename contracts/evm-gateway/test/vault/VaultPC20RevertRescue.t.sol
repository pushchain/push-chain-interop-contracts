// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {PC20Factory} from "../../src/PC20Factory.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {RevertInstructions} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockCEAFactory} from "../mocks/MockCEAFactory.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract VaultPC20RevertRescueTest is Test {
    Vault public vault;
    UniversalGateway public gateway;
    PC20Factory public pc20Factory;
    MockCEAFactory public ceaFactory;

    address public admin;
    address public pauser;
    address public tss;
    address public recipient;
    address public attacker;
    address public weth;

    address public sourceAsset;
    PC20Wrapper public wrapper;

    bytes32 constant SUB_TX_ID = bytes32(uint256(5001));
    bytes32 constant UNIVERSAL_TX_ID = bytes32(uint256(6001));
    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");
        sourceAsset = makeAddr("sourceAsset");

        ceaFactory = new MockCEAFactory();

        Vault vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeCall(
            Vault.initialize,
            (admin, pauser, tss, address(1), address(ceaFactory))
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl), vaultInitData
        );
        vault = Vault(payable(address(vaultProxy)));

        ceaFactory.setVault(address(vault));

        UniversalGateway gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeCall(
            UniversalGateway.initialize,
            (
                admin, pauser, tss, address(vault),
                1e18, 10e18,
                address(0), address(0), weth
            )
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl), gatewayInitData
        );
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        vm.prank(admin);
        vault.updateGateway(address(gateway));

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
        pc20Factory = PC20Factory(address(factoryProxy));

        vm.prank(admin);
        vault.updatePC20Factory(address(pc20Factory));

        vm.prank(admin);
        gateway.updatePC20Factory(address(pc20Factory));

        // Deploy wrapper via the PC20 export path
        bytes memory pc20Data = abi.encodePacked(
            bytes4(0x50433230),
            abi.encode(
                "Push Token", "pTKN", uint8(18), bytes("")
            )
        );
        vm.prank(tss);
        vault.finalizeUniversalTx(
            bytes32(uint256(9999)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            recipient,
            sourceAsset,
            10_000e18,
            pc20Data
        );

        wrapper = PC20Wrapper(pc20Factory.getWrapper(sourceAsset));
    }

    // ======================================================
    //  REVERT — Happy Path
    // ======================================================

    function test_RevertPC20_Success() public {
        uint256 balBefore = wrapper.balanceOf(recipient);
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxReverted(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        assertEq(
            wrapper.balanceOf(recipient),
            balBefore + AMOUNT
        );
    }

    function test_RevertPC20_NoMsgValue() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx{value: 1 ether}(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    function test_RevertPC20_DoesNotTransferFromVault() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        uint256 vaultBal = wrapper.balanceOf(address(vault));
        assertEq(vaultBal, 0);

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        assertEq(wrapper.balanceOf(address(vault)), 0);
        assertEq(
            wrapper.balanceOf(recipient),
            10_000e18 + AMOUNT
        );
    }

    // ======================================================
    //  REVERT — Access Control
    // ======================================================

    function test_RevertPC20_Reverts_NonTSS() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(attacker);
        vm.expectRevert();
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    function test_RevertPC20_Reverts_WhenPaused() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  REVERT — Validation
    // ======================================================

    function test_RevertPC20_Reverts_ZeroAmount() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), 0, ri
        );
    }

    function test_RevertPC20_Reverts_ZeroRecipient() public {
        RevertInstructions memory ri =
            RevertInstructions(address(0), "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  REVERT — Replay Protection
    // ======================================================

    function test_RevertPC20_ReplayProtection() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  RESCUE — Happy Path
    // ======================================================

    function test_RescuePC20_Success() public {
        uint256 balBefore = wrapper.balanceOf(recipient);
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.expectEmit(true, true, true, true);
        emit IVault.FundsRescued(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        assertEq(
            wrapper.balanceOf(recipient),
            balBefore + AMOUNT
        );
    }

    function test_RescuePC20_NoMsgValue() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds{value: 1 ether}(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  RESCUE — Access Control
    // ======================================================

    function test_RescuePC20_Reverts_NonTSS() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(attacker);
        vm.expectRevert();
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  RESCUE — Validation
    // ======================================================

    function test_RescuePC20_Reverts_ZeroAmount() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), 0, ri
        );
    }

    function test_RescuePC20_Reverts_ZeroRecipient() public {
        RevertInstructions memory ri =
            RevertInstructions(address(0), "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  RESCUE — Replay Protection
    // ======================================================

    function test_RescuePC20_ReplayProtection() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  Shared isExecuted — Revert & Rescue cross-block
    // ======================================================

    function test_RevertAndRescue_ShareIsExecuted() public {
        bytes32 sharedId = bytes32(uint256(42));
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            sharedId, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.rescueFunds(
            sharedId, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  Event Distinction
    // ======================================================

    function test_RevertAndRescue_EmitDifferentEvents() public {
        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.expectEmit(true, true, true, true);
        emit IVault.UniversalTxReverted(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );

        bytes32 rescueId = bytes32(uint256(7001));
        vm.expectEmit(true, true, true, true);
        emit IVault.FundsRescued(
            rescueId, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
        vm.prank(tss);
        vault.rescueFunds(
            rescueId, UNIVERSAL_TX_ID,
            address(wrapper), AMOUNT, ri
        );
    }

    // ======================================================
    //  PRC20 revert still works (no regression)
    // ======================================================

    function test_PRC20Revert_StillWorks() public {
        MockERC20 prc20 = new MockERC20("PRC20", "PRC", 18, 0);
        prc20.mint(address(vault), 10_000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(prc20);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(prc20), 500e18, ri
        );

        assertEq(prc20.balanceOf(recipient), 500e18);
    }

    // ======================================================
    //  PC20Factory not set — PRC20 path still works
    // ======================================================

    function test_NoPC20Factory_PRC20RevertStillWorks() public {
        Vault vaultImpl2 = new Vault();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(vaultImpl2),
            abi.encodeCall(
                Vault.initialize,
                (
                    admin, pauser, tss,
                    address(1), address(ceaFactory)
                )
            )
        );
        Vault vault2 = Vault(payable(address(proxy2)));

        UniversalGateway gw2Impl = new UniversalGateway();
        ERC1967Proxy gw2Proxy = new ERC1967Proxy(
            address(gw2Impl),
            abi.encodeCall(
                UniversalGateway.initialize,
                (
                    admin, pauser, tss, address(vault2),
                    1e18, 10e18,
                    address(0), address(0), weth
                )
            )
        );
        UniversalGateway gw2 = UniversalGateway(
            payable(address(gw2Proxy))
        );

        vm.prank(admin);
        vault2.updateGateway(address(gw2));

        MockERC20 tok = new MockERC20("T", "T", 18, 0);
        tok.mint(address(vault2), 10_000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(tok);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gw2.setTokenLimitThresholds(tokens, thresholds);

        RevertInstructions memory ri =
            RevertInstructions(recipient, "");

        vm.prank(tss);
        vault2.revertUniversalTx(
            SUB_TX_ID, UNIVERSAL_TX_ID,
            address(tok), 100e18, ri
        );

        assertEq(tok.balanceOf(recipient), 100e18);
    }
}
