pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";


/// @notice Test suite for the deposit functions that use NATIVE Token only. 
/// @dev Deposit functions in EVM UniversalGatewayV1 are of 2 main types:
///      - Deposit functions that works with NATIVE Token.
///      - Deposit functions that works with ERC20 Tokens.
///     This test suite is for the first type of deposit functions, such as:
///      - depositForInstantTx
///      - depositForUniversalTxFunds
///      - depositForUniversalTxFundsAndPayload
contract GatewayDepositNativeTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }
}