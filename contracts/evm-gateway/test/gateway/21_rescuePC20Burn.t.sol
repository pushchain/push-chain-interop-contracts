// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.t.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {PC20Factory} from "../../src/PC20Factory.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";
import {IUniversalGateway} from "../../src/interfaces/IUniversalGateway.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Vault} from "../../src/Vault.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCEAFactory} from "../mocks/MockCEAFactory.sol";

contract RescuePC20BurnTest is BaseTest {
    PC20Factory public pc20Factory;
    address public sourceAsset;
    PC20Wrapper public wrapper;
    Vault public vaultContract;
    MockCEAFactory public ceaFactory;

    bytes32 constant SUB_TX_ID = bytes32(uint256(2001));
    uint256 constant RESCUE_AMOUNT = 1_000e18;

    function setUp() public override {
        super.setUp();

        sourceAsset = makeAddr("sourceAsset");

        ceaFactory = new MockCEAFactory();

        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                Vault.initialize,
                (
                    admin, pauser, tss,
                    address(gateway),
                    address(ceaFactory)
                )
            )
        );
        vaultContract = Vault(payable(address(vaultProxy)));
        ceaFactory.setVault(address(vaultContract));

        PC20Factory factoryImpl = new PC20Factory();
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(
                address(factoryImpl),
                makeAddr("factoryProxyAdmin"),
                abi.encodeCall(
                    PC20Factory.initialize,
                    (
                        admin,
                        pauser,
                        address(vaultContract),
                        address(gateway)
                    )
                )
            );
        pc20Factory = PC20Factory(address(factoryProxy));

        vm.prank(admin);
        vaultContract.updatePC20Factory(address(pc20Factory));

        vm.prank(admin);
        gateway.updatePC20Factory(address(pc20Factory));

        // Deploy wrapper + mint tokens via Vault PC20 export path
        bytes memory pc20Data = abi.encodePacked(
            bytes4(0x50433230),
            abi.encode("Push Token", "pTKN", uint8(18), bytes(""))
        );
        vm.prank(tss);
        vaultContract.finalizeUniversalTx(
            bytes32(uint256(9999)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            user1,
            sourceAsset,
            10_000e18,
            pc20Data
        );

        wrapper = PC20Wrapper(pc20Factory.getWrapper(sourceAsset));
    }

    // =========================================================
    //  Happy Path
    // =========================================================

    function test_RescuePC20Burn_Success() public {
        uint256 balBefore = wrapper.balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.PC20BurnRescued(
            SUB_TX_ID, sourceAsset, user1, RESCUE_AMOUNT
        );

        vm.prank(tss);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );

        assertEq(
            wrapper.balanceOf(user1),
            balBefore + RESCUE_AMOUNT
        );
    }

    function test_RescuePC20Burn_DifferentRecipient() public {
        vm.prank(tss);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user2
        );

        assertEq(wrapper.balanceOf(user2), RESCUE_AMOUNT);
    }

    // =========================================================
    //  Access Control
    // =========================================================

    function test_RescuePC20Burn_Reverts_NonTSS() public {
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );
    }

    function test_RescuePC20Burn_Reverts_WhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(tss);
        vm.expectRevert();
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );
    }

    // =========================================================
    //  Replay Protection
    // =========================================================

    function test_RescuePC20Burn_Reverts_AlreadyExecuted() public {
        vm.prank(tss);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );
    }

    function test_RescuePC20Burn_DifferentSubTxIds() public {
        vm.prank(tss);
        gateway.rescuePC20Burn(
            bytes32(uint256(1)),
            sourceAsset,
            RESCUE_AMOUNT,
            user1
        );

        vm.prank(tss);
        gateway.rescuePC20Burn(
            bytes32(uint256(2)),
            sourceAsset,
            RESCUE_AMOUNT,
            user1
        );

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 + (RESCUE_AMOUNT * 2)
        );
    }

    // =========================================================
    //  Validation
    // =========================================================

    function test_RescuePC20Burn_Reverts_ZeroAmount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, 0, user1
        );
    }

    function test_RescuePC20Burn_Reverts_ZeroSourceAsset() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.rescuePC20Burn(
            SUB_TX_ID, address(0), RESCUE_AMOUNT, user1
        );
    }

    function test_RescuePC20Burn_Reverts_ZeroRecipient() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, address(0)
        );
    }

    function test_RescuePC20Burn_Reverts_WrapperNotDeployed()
        public
    {
        address fakeSource = makeAddr("noWrapper");
        vm.prank(tss);
        vm.expectRevert(
            abi.encodeWithSelector(
                PC20Factory.WrapperNotDeployed.selector,
                fakeSource
            )
        );
        gateway.rescuePC20Burn(
            SUB_TX_ID, fakeSource, RESCUE_AMOUNT, user1
        );
    }

    // =========================================================
    //  Event Distinction from Revert
    // =========================================================

    function test_RescueEmitsDifferentEventThanRevert() public {
        // Rescue emits PC20BurnRescued
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.PC20BurnRescued(
            SUB_TX_ID, sourceAsset, user1, RESCUE_AMOUNT
        );

        vm.prank(tss);
        gateway.rescuePC20Burn(
            SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1
        );

        // Revert emits PC20BurnReverted (different event)
        bytes32 revertSubTxId = bytes32(uint256(3001));
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.PC20BurnReverted(
            revertSubTxId, sourceAsset, user1, RESCUE_AMOUNT
        );

        vm.prank(tss);
        gateway.revertPC20Burn(
            revertSubTxId, sourceAsset, RESCUE_AMOUNT, user1
        );
    }

    // =========================================================
    //  Shared isExecuted with Revert
    // =========================================================

    function test_RescueAndRevert_ShareIsExecuted() public {
        bytes32 sharedId = bytes32(uint256(42));

        vm.prank(tss);
        gateway.rescuePC20Burn(
            sharedId, sourceAsset, RESCUE_AMOUNT, user1
        );

        // Same ID used for revert should fail
        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        gateway.revertPC20Burn(
            sharedId, sourceAsset, RESCUE_AMOUNT, user1
        );
    }

    // =========================================================
    //  Non-payable
    // =========================================================

    function test_RescuePC20Burn_IsNotPayable() public {
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        (bool ok,) = address(gateway).call{value: 1 ether}(
            abi.encodeCall(
                gateway.rescuePC20Burn,
                (SUB_TX_ID, sourceAsset, RESCUE_AMOUNT, user1)
            )
        );
        assertFalse(ok);
    }
}
