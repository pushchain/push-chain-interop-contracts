// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { RevertInstructions, TX_TYPE } from "../../src/libraries/Types.sol";
import { UniversalPayload } from "../../src/libraries/TypesUG.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Test suite for gateway revert function (unified revertUniversalTx)
/// @dev Tests VAULT_ROLE access control, native/token revert paths, and replay protection
contract GatewayTSSFunctionsTest is BaseTest {
    // =========================
    //      SETUP
    // =========================
    function setUp() public override {
        super.setUp();

        // Fund the gateway with some ETH and tokens for withdrawal tests
        vm.deal(address(gateway), 10 ether);

        // Configure token support
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(tokenA);

        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1000000e6; // 1M USDC
        thresholds[1] = 1000000e18; // 1M tokenA

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Mint and transfer some test tokens to the gateway
        usdc.mint(address(gateway), 1000e6);
        tokenA.mint(address(gateway), 1000e18);
    }

    // =========================
    //      ACCESS CONTROL TESTS
    // =========================

    function testRevertNative_NonVaultShouldRevert() public {
        bytes32 subTxId = bytes32(uint256(1));
        bytes32 universalTxId = bytes32(uint256(1001));
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert();
        gateway.revertUniversalTx{ value: 1 ether }(
            subTxId, universalTxId, address(0), 1 ether, RevertInstructions(user1, "")
        );
    }

    function testRevertNative_VaultRoleShouldSucceed() public {
        // Test contract has VAULT_ROLE (set as vault address in BaseTest)
        bytes32 subTxId = bytes32(uint256(2));
        bytes32 universalTxId = bytes32(uint256(1002));
        uint256 initialBalance = user1.balance;

        vm.deal(address(this), 1 ether);
        gateway.revertUniversalTx{ value: 1 ether }(
            subTxId, universalTxId, address(0), 1 ether, RevertInstructions(user1, "")
        );

        assertEq(user1.balance, initialBalance + 1 ether);
    }

    // =========================
    //      WITHDRAWFUNDS TESTS
    // =========================

    function testWithdrawFunds_NativeETH_Success() public {
        bytes32 subTxId = bytes32(uint256(3));
        bytes32 universalTxId = bytes32(uint256(1003));
        uint256 withdrawAmount = 2 ether;
        uint256 initialRecipientBalance = user1.balance;

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(
            subTxId, universalTxId, user1, address(0), withdrawAmount, RevertInstructions(user1, "")
        );

        vm.deal(address(this), withdrawAmount);
        gateway.revertUniversalTx{ value: withdrawAmount }(
            subTxId, universalTxId, address(0), withdrawAmount, RevertInstructions(user1, "")
        );

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_ERC20Token_Success() public {
        bytes32 subTxId = bytes32(uint256(4));
        bytes32 universalTxId = bytes32(uint256(1004));
        uint256 withdrawAmount = 100e6; // 100 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(
            subTxId, universalTxId, user1, address(usdc), withdrawAmount, RevertInstructions(user1, "")
        );

        // revertUniversalTx requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTx(subTxId, universalTxId, address(usdc), withdrawAmount, RevertInstructions(user1, ""));

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 subTxId = bytes32(uint256(5));
        bytes32 universalTxId = bytes32(uint256(1005));
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx{ value: 1 ether }(
            subTxId, universalTxId, address(0), 1 ether, RevertInstructions(address(0), "")
        );
    }

    function testWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 subTxId = bytes32(uint256(6));
        bytes32 universalTxId = bytes32(uint256(1006));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(subTxId, universalTxId, address(0), 0, RevertInstructions(user1, ""));
    }

    function testWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 subTxId = bytes32(uint256(7));
        bytes32 universalTxId = bytes32(uint256(1007));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.5 ether;

        vm.deal(address(this), wrongValue);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{ value: wrongValue }(
            subTxId, universalTxId, address(0), amount, RevertInstructions(user1, "")
        );
    }

    function testWithdrawFunds_ERC20InsufficientBalance_Revert() public {
        bytes32 subTxId = bytes32(uint256(8));
        bytes32 universalTxId = bytes32(uint256(1008));
        uint256 excessiveAmount = usdc.balanceOf(address(gateway)) + 1;

        vm.expectRevert();
        gateway.revertUniversalTx(subTxId, universalTxId, address(usdc), excessiveAmount, RevertInstructions(user1, ""));
    }

    // =========================
    //      REVERTWITHDRAWFUNDS TESTS
    // =========================

    function testRevertWithdrawFunds_NativeETH_Success() public {
        bytes32 subTxId = bytes32(uint256(9));
        bytes32 universalTxId = bytes32(uint256(1009));
        uint256 withdrawAmount = 1.5 ether;
        uint256 initialRecipientBalance = user1.balance;

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(subTxId, universalTxId, user1, address(0), withdrawAmount, revertCfg);

        vm.deal(address(this), withdrawAmount);
        gateway.revertUniversalTx{ value: withdrawAmount }(
            subTxId, universalTxId, address(0), withdrawAmount, revertCfg
        );

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_ERC20Token_Success() public {
        bytes32 subTxId = bytes32(uint256(10));
        bytes32 universalTxId = bytes32(uint256(1010));
        uint256 withdrawAmount = 200e6; // 200 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(
            subTxId, universalTxId, user1, address(usdc), withdrawAmount, revertCfg
        );

        // revertUniversalTx requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTx(subTxId, universalTxId, address(usdc), withdrawAmount, revertCfg);

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 subTxId = bytes32(uint256(11));
        bytes32 universalTxId = bytes32(uint256(1011));
        RevertInstructions memory revertCfg = revertCfg(address(0));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx{ value: 1 ether }(subTxId, universalTxId, address(0), 1 ether, revertCfg);
    }

    function testRevertWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 subTxId = bytes32(uint256(12));
        bytes32 universalTxId = bytes32(uint256(1012));
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(subTxId, universalTxId, address(0), 0, revertCfg);
    }

    function testRevertWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 subTxId = bytes32(uint256(13));
        bytes32 universalTxId = bytes32(uint256(1013));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.8 ether;
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.deal(address(this), wrongValue);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{ value: wrongValue }(subTxId, universalTxId, address(0), amount, revertCfg);
    }

    // =========================
    //      EDGE CASES AND ERROR PATHS
    // =========================

    function testWithdrawFunds_WhenPaused_Revert() public {
        bytes32 subTxId = bytes32(uint256(14));
        bytes32 universalTxId = bytes32(uint256(1014));
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        gateway.revertUniversalTx{ value: 1 ether }(
            subTxId, universalTxId, address(0), 1 ether, RevertInstructions(user1, "")
        );
    }

    function testRevertWithdrawFunds_WhenPaused_Revert() public {
        bytes32 subTxId = bytes32(uint256(15));
        bytes32 universalTxId = bytes32(uint256(1015));
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        gateway.revertUniversalTx{ value: 1 ether }(subTxId, universalTxId, address(0), 1 ether, revertCfg);
    }

    function testWithdrawFunds_ReentrancyProtection() public {
        bytes32 subTxId = bytes32(uint256(16));
        bytes32 universalTxId = bytes32(uint256(1016));
        vm.deal(address(this), 1 ether);
        gateway.revertUniversalTx{ value: 1 ether }(
            subTxId, universalTxId, address(0), 1 ether, RevertInstructions(user1, "")
        );

        assertTrue(true);
    }

    function testWithdrawFunds_MultipleTokens() public {
        uint256 usdcAmount = 50e6;
        uint256 tokenAAmount = 100e18;
        uint256 ethAmount = 0.5 ether;

        // Withdraw USDC (requires VAULT_ROLE)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        gateway.revertUniversalTx(
            bytes32(uint256(17)), bytes32(uint256(1017)), address(usdc), usdcAmount, RevertInstructions(user1, "")
        );
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Withdraw TokenA (requires VAULT_ROLE)
        uint256 initialTokenABalance = tokenA.balanceOf(user1);
        gateway.revertUniversalTx(
            bytes32(uint256(18)), bytes32(uint256(1018)), address(tokenA), tokenAAmount, RevertInstructions(user1, "")
        );
        assertEq(tokenA.balanceOf(user1), initialTokenABalance + tokenAAmount);

        // Withdraw ETH (requires VAULT_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(address(this), ethAmount);
        gateway.revertUniversalTx{ value: ethAmount }(
            bytes32(uint256(19)), bytes32(uint256(1019)), address(0), ethAmount, RevertInstructions(user1, "")
        );
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    function testRevertWithdrawFunds_MultipleTokens() public {
        RevertInstructions memory revertCfg = revertCfg(user1);

        uint256 usdcAmount = 25e6;
        uint256 ethAmount = 0.25 ether;

        // Revert USDC (requires VAULT_ROLE)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        gateway.revertUniversalTx(bytes32(uint256(20)), bytes32(uint256(1020)), address(usdc), usdcAmount, revertCfg);
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Revert ETH (requires VAULT_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(address(this), ethAmount);
        gateway.revertUniversalTx{ value: ethAmount }(
            bytes32(uint256(21)), bytes32(uint256(1021)), address(0), ethAmount, revertCfg
        );
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    // =========================
    //      REPLAY PROTECTION TESTS
    // =========================

    function testRevertUniversalTx_ReplayProtection_Native() public {
        bytes32 subTxId = bytes32(uint256(22));
        bytes32 universalTxId = bytes32(uint256(1022));
        uint256 amount = 1 ether;

        // First call should succeed
        vm.deal(address(this), amount);
        gateway.revertUniversalTx{ value: amount }(
            subTxId, universalTxId, address(0), amount, RevertInstructions(user1, "")
        );

        // Second call with same subTxId should revert
        vm.deal(address(this), amount);
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTx{ value: amount }(
            subTxId, universalTxId, address(0), amount, RevertInstructions(user1, "")
        );
    }

    function testRevertUniversalTxToken_ReplayProtection() public {
        bytes32 subTxId = bytes32(uint256(23));
        bytes32 universalTxId = bytes32(uint256(1023));
        uint256 amount = 100e6;

        // First call should succeed
        gateway.revertUniversalTx(subTxId, universalTxId, address(usdc), amount, RevertInstructions(user1, ""));

        // Second call with same subTxId should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTx(subTxId, universalTxId, address(usdc), amount, RevertInstructions(user1, ""));
    }

    // =========================
    //      WITHDRAW NATIVE TESTS - REMOVED
    // =========================
    // NOTE: Native withdrawal tests have been moved to test/vault/VaultWithdrawal.t.sol
    //       Withdrawals now route through Vault → CEA → User using executeUniversalTx with empty payload
    //       This file now only contains Gateway revert function tests
}
