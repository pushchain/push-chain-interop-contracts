// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

contract VaultRescueFundsTest is Test {
    Vault public vault;
    UniversalGateway public gateway;
    MockERC20 public token;
    MockCEAFactory public ceaFactory;

    address public admin;
    address public pauser;
    address public tss;
    address public recipient;
    address public attacker;
    address public weth;

    bytes32 constant SUB_TX_ID = bytes32(uint256(99));
    bytes32 constant UNIVERSAL_TX_ID = bytes32(uint256(42));

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
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");

        // Deploy CEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault impl + proxy (use temporary gateway placeholder)
        Vault vaultImpl = new Vault();
        // We need the vault address before deploying gateway, so use a placeholder
        // and update later. Deploy vault first to get its address.
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            address(1), // placeholder gateway
            address(ceaFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );
        vault = Vault(payable(address(vaultProxy)));

        // Deploy UniversalGateway with vault address so VAULT_ROLE is granted
        UniversalGateway gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            address(vault),
            1e18,
            10e18,
            address(0),
            address(0),
            weth
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            gatewayInitData
        );
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Update vault to point to the real gateway
        vm.prank(admin);
        vault.updateGateway(address(gateway));

        // Deploy tokens
        token = new MockERC20("Test Token", "TST", 18, 1_000_000e18);

        // Fund vault with ERC20
        token.mint(address(vault), 100_000e18);

        // Support token in gateway
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(0);
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000 ether;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    // ==============================
    //       HAPPY PATH TESTS
    // ==============================

    function testRescueFundsERC20Success() public {
        uint256 amount = 1000e18;
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 recipientBefore = token.balanceOf(recipient);
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit FundsRescued(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), amount, ri);
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), amount, ri);

        assertEq(token.balanceOf(address(vault)), vaultBefore - amount);
        assertEq(token.balanceOf(recipient), recipientBefore + amount);
    }

    function testRescueFundsNativeSuccess() public {
        uint256 amount = 5 ether;
        uint256 recipientBefore = recipient.balance;
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit FundsRescued(SUB_TX_ID, UNIVERSAL_TX_ID, address(0), amount, ri);
        vault.rescueFunds{ value: amount }(
            SUB_TX_ID, UNIVERSAL_TX_ID, address(0), amount, ri
        );

        assertEq(recipient.balance, recipientBefore + amount);
    }

    // ==============================
    //      ACCESS CONTROL TESTS
    // ==============================

    function testRescueFundsRevertNotTSS() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(attacker);
        vm.expectRevert();
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), 100e18, ri);
    }

    function testRescueFundsRevertWhenPaused() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), 100e18, ri);
    }

    // ==============================
    //      VALIDATION TESTS
    // ==============================

    function testRescueFundsRevertZeroAmount() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), 0, ri);
    }

    function testRescueFundsRevertZeroRecipient() public {
        RevertInstructions memory ri = RevertInstructions(address(0), "");

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), 100e18, ri);
    }

    function testRescueFundsRevertInsufficientBalanceERC20() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.rescueFunds(
            SUB_TX_ID, UNIVERSAL_TX_ID, address(token), vaultBalance + 1, ri
        );
    }

    // ==============================
    //     MSG.VALUE MISMATCH TESTS
    // ==============================

    function testRescueFundsNativeWrongValueReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.deal(tss, 10 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds{ value: 3 ether }(
            SUB_TX_ID, UNIVERSAL_TX_ID, address(0), 5 ether, ri
        );
    }

    function testRescueFundsERC20NonZeroValueReverts() public {
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds{ value: 1 ether }(
            SUB_TX_ID, UNIVERSAL_TX_ID, address(token), 100e18, ri
        );
    }

    // ==============================
    //     REPLAY PROTECTION TESTS
    // ==============================

    function testRescueFundsReplayProtection() public {
        uint256 amount = 100e18;
        RevertInstructions memory ri = RevertInstructions(recipient, "");

        vm.prank(tss);
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), amount, ri);

        vm.prank(tss);
        vm.expectRevert(Errors.PayloadExecuted.selector);
        vault.rescueFunds(SUB_TX_ID, UNIVERSAL_TX_ID, address(token), amount, ri);
    }

    // ==============================
    //   NATIVE TRANSFER FAILURE TEST
    // ==============================

    function testRescueFundsNativeTransferFailure() public {
        EthRejecter rejecter = new EthRejecter();
        RevertInstructions memory ri = RevertInstructions(address(rejecter), "");

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.WithdrawFailed.selector);
        vault.rescueFunds{ value: 1 ether }(
            SUB_TX_ID, UNIVERSAL_TX_ID, address(0), 1 ether, ri
        );
    }
}
