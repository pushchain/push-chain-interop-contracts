// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Fuzz tests for Vault.sol — msg.value/token invariants, balance conservation, zero-address guards.
contract Vault_InvariantsFuzz is Test {
    Vault public vault;
    UniversalGateway public gateway;
    MockERC20 public mockToken;
    MockCEAFactory public ceaFactory;

    address public admin;
    address public pauser;
    address public tss;
    address public weth;

    function setUp() public {
        admin  = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss    = makeAddr("tss");
        weth   = makeAddr("weth");

        ceaFactory = new MockCEAFactory();

        // Deploy gateway
        UniversalGateway gatewayImpl = new UniversalGateway();
        bytes memory gatewayInit = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss,
            1e18, 10e18,
            address(0), address(0), weth,
            address(0), address(0), address(0)
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInit);
        gateway = UniversalGateway(payable(address(gatewayProxy)));
        vm.startPrank(admin);
        gateway.grantRole(gateway.ROLE_MANAGER_ROLE(), admin);
        gateway.grantRole(gateway.UG_ADMIN_ROLE(), admin);
        gateway.grantRole(gateway.OPERATOR_ROLE(), admin);
        vm.stopPrank();

        // Deploy vault
        Vault vaultImpl = new Vault();
        bytes memory vaultInit = abi.encodeWithSelector(
            Vault.initialize.selector, admin, pauser, tss, address(gateway), address(ceaFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInit);
        vault = Vault(payable(address(vaultProxy)));

        ceaFactory.setVault(address(vault));

        // Point gateway at real vault and register it with VAULT_ROLE
        vm.prank(admin);
        gateway.updateVault(address(vault));

        // Deploy token and register it in gateway
        mockToken = new MockERC20("Mock", "MCK", 18, 0);

        address[] memory tokens     = new address[](2);
        uint256[] memory thresholds = new uint256[](2);
        tokens[0] = address(mockToken);
        tokens[1] = address(0); // native
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000 ether;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    // =========================================================
    //   FV-1: finalizeUniversalTx — msg.value / token invariant
    // =========================================================

    /// @dev Native flow: msg.value != amount always reverts InvalidAmount.
    function testFuzz_Finalize_Native_MsgValueMismatch_Reverts(
        uint256 amount,
        uint256 sentValue
    ) public {
        amount    = bound(amount,    1, 100 ether);
        sentValue = bound(sentValue, 0, 200 ether);
        vm.assume(sentValue != amount);

        address pushAccount = makeAddr("pushUser");
        vm.deal(tss, sentValue + 1);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.finalizeUniversalTx{ value: sentValue }(
            bytes32(0), bytes32(0),
            pushAccount, makeAddr("recip"),
            address(0), amount, bytes("")
        );
    }

    /// @dev ERC20 flow: any non-zero msg.value always reverts InvalidAmount.
    function testFuzz_Finalize_ERC20_NonZeroMsgValue_Reverts(
        uint96 amount,
        uint96 sentValue
    ) public {
        amount    = uint96(bound(amount,    1, 10_000e18));
        sentValue = uint96(bound(sentValue, 1, 10 ether));

        mockToken.mint(address(vault), amount);
        vm.deal(tss, sentValue + 1);

        address pushAccount = makeAddr("pushUser");
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.finalizeUniversalTx{ value: sentValue }(
            bytes32(0), bytes32(0),
            pushAccount, makeAddr("recip"),
            address(mockToken), amount, bytes("")
        );
    }

    /// @dev ERC20 flow: vault balance decreases by exactly amount after a successful finalize.
    function testFuzz_Finalize_ERC20_BalanceConservation(uint96 amount) public {
        amount = uint96(bound(amount, 1, 10_000e18));

        mockToken.mint(address(vault), amount);
        uint256 vaultBefore = mockToken.balanceOf(address(vault));

        address pushAccount = makeAddr("pushUser");
        vm.prank(tss);
        vault.finalizeUniversalTx(
            bytes32(0), bytes32(0),
            pushAccount, makeAddr("recip"),
            address(mockToken), amount, bytes("")
        );

        uint256 vaultAfter = mockToken.balanceOf(address(vault));
        assertEq(vaultAfter, vaultBefore - uint256(amount), "vault balance must decrease by exactly amount");
    }

    // =========================================================
    //   FV-2: revertUniversalTx & rescueFunds — invariants
    // =========================================================

    /// @dev Native revert: msg.value != amount always reverts InvalidAmount.
    function testFuzz_RevertTx_Native_MsgValueMismatch_Reverts(
        uint256 amount,
        uint256 sentValue
    ) public {
        amount    = bound(amount,    1, 100 ether);
        sentValue = bound(sentValue, 0, 200 ether);
        vm.assume(sentValue != amount);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.deal(tss, sentValue + 1);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx{ value: sentValue }(
            bytes32(0), bytes32(0), address(0), amount, cfg
        );
    }

    /// @dev ERC20 revert: any non-zero msg.value always reverts InvalidAmount.
    function testFuzz_RevertTx_ERC20_NonZeroMsgValue_Reverts(
        uint96 amount,
        uint96 sentValue
    ) public {
        amount    = uint96(bound(amount,    1, 10_000e18));
        sentValue = uint96(bound(sentValue, 1, 10 ether));

        mockToken.mint(address(vault), amount);
        vm.deal(tss, sentValue + 1);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx{ value: sentValue }(
            bytes32(0), bytes32(0), address(mockToken), amount, cfg
        );
    }

    /// @dev ERC20 revert: amount > vault balance always reverts InsufficientBalance.
    function testFuzz_RevertTx_ERC20_InsufficientBalance_Reverts(
        uint96 vaultBalance,
        uint96 amount
    ) public {
        vaultBalance = uint96(bound(vaultBalance, 0, 10_000e18 - 1));
        amount       = uint96(bound(amount, uint256(vaultBalance) + 1, 10_000e18));

        mockToken.mint(address(vault), vaultBalance);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.revertUniversalTx(bytes32(0), bytes32(0), address(mockToken), amount, cfg);
    }

    /// @dev rescueFunds ERC20: amount > vault balance always reverts InsufficientBalance.
    function testFuzz_RescueFunds_ERC20_InsufficientBalance_Reverts(
        uint96 vaultBalance,
        uint96 amount
    ) public {
        vaultBalance = uint96(bound(vaultBalance, 0, 10_000e18 - 1));
        amount       = uint96(bound(amount, uint256(vaultBalance) + 1, 10_000e18));

        mockToken.mint(address(vault), vaultBalance);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.rescueFunds(bytes32(0), bytes32(0), address(mockToken), amount, cfg);
    }

    /// @dev rescueFunds native: msg.value != amount always reverts InvalidAmount.
    function testFuzz_RescueFunds_Native_MsgValueMismatch_Reverts(
        uint256 amount,
        uint256 sentValue
    ) public {
        amount    = bound(amount,    1, 100 ether);
        sentValue = bound(sentValue, 0, 200 ether);
        vm.assume(sentValue != amount);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.deal(tss, sentValue + 1);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds{ value: sentValue }(
            bytes32(0), bytes32(0), address(0), amount, cfg
        );
    }

    // =========================================================
    //   FV-3: ZERO-ADDRESS PARAMETER VALIDATION
    // =========================================================

    /// @dev pushAccount == address(0) always reverts ZeroAddress in finalizeUniversalTx.
    function testFuzz_Finalize_ZeroPushAccount_Reverts(uint96 amount) public {
        amount = uint96(bound(amount, 1, 1000e18));
        mockToken.mint(address(vault), amount);

        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.finalizeUniversalTx(
            bytes32(0), bytes32(0),
            address(0), makeAddr("recip"),
            address(mockToken), amount, bytes("")
        );
    }

    /// @dev revertRecipient == address(0) always reverts InvalidRecipient in revertUniversalTx.
    function testFuzz_RevertTx_ZeroRevertRecipient_Reverts(uint96 amount, bytes32 subTxId) public {
        amount = uint96(bound(amount, 1, 1000e18));
        mockToken.mint(address(vault), amount);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: address(0),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.revertUniversalTx(subTxId, bytes32(0), address(mockToken), amount, cfg);
    }

    /// @dev amount == 0 always reverts InvalidAmount in revertUniversalTx.
    function testFuzz_RevertTx_ZeroAmount_Reverts(bytes32 subTxId) public {
        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTx(subTxId, bytes32(0), address(mockToken), 0, cfg);
    }

    /// @dev amount == 0 always reverts InvalidAmount in rescueFunds.
    function testFuzz_RescueFunds_ZeroAmount_Reverts(bytes32 subTxId) public {
        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: makeAddr("recip"),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.rescueFunds(subTxId, bytes32(0), address(mockToken), 0, cfg);
    }

    /// @dev revertRecipient == address(0) always reverts InvalidRecipient in rescueFunds.
    function testFuzz_RescueFunds_ZeroRevertRecipient_Reverts(uint96 amount, bytes32 subTxId) public {
        amount = uint96(bound(amount, 1, 1000e18));
        mockToken.mint(address(vault), amount);

        RevertInstructions memory cfg = RevertInstructions({
            revertRecipient: address(0),
            revertMsg: bytes("")
        });

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.rescueFunds(subTxId, bytes32(0), address(mockToken), amount, cfg);
    }
}
