// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { VaultPC } from "../../src/VaultPC.sol";
import { UniversalOutboundTxRequest } from "../../src/libraries/Types.sol";
import { TX_TYPE } from "../../src/libraries/Types.sol";

interface IERC20 {
    function approve(address to, uint256 value) external returns (bool);
}

contract MultiTxRequestScript is Script {
    address constant GATEWAY_PROXY = 0x00000000000000000000000000000000000000C1;
    address constant VAULT_PROXY = 0x00000000000000000000000000000000000000B0;
    address constant PETH_TOKEN = 0x2971824Db68229D087931155C2b8bB820B275809; // pETH (native token, 18 decimals)
    address constant USDT_TOKEN = 0xCA0C5E6F002A389E1580F0DB7cd06e4549B5F9d3; // USDT (ERC20 token, 6 decimals)

    bytes constant COMMON_TARGET = abi.encodePacked(address(0x778D3206374f8AC265728E18E3fE2Ae6b93E4ce4));
    address constant COMMON_REVERT_RECIPIENT = 0x778D3206374f8AC265728E18E3fE2Ae6b93E4ce4;

    // FUNDS
    uint256 constant FUNDS_AMOUNT = 10 ether;
    uint256 constant FUNDS_AMOUNT_USDT = 10 * 10**6; // 10 USDT (6 decimals)
    uint256 constant FUNDS_GAS_LIMIT = 150_000;
    bytes constant FUNDS_PAYLOAD = "";

    // FUNDS_AND_PAYLOAD
    uint256 constant FUNDS_AND_PAYLOAD_AMOUNT = 10 ether;
    uint256 constant FUNDS_AND_PAYLOAD_AMOUNT_USDT = 10 * 10**6; // 10 USDT (6 decimals)
    uint256 constant FUNDS_AND_PAYLOAD_GAS_LIMIT = 300_000;
    bytes constant FUNDS_AND_PAYLOAD_PAYLOAD = abi.encodeWithSignature("transfer(address,uint256)", address(0x4444444444444444444444444444444444444444), 100);

    // GAS_AND_PAYLOAD
    uint256 constant GAS_AND_PAYLOAD_AMOUNT = 10 ether;
    uint256 constant GAS_AND_PAYLOAD_AMOUNT_USDT = 10 * 10**6; // 10 USDT (6 decimals)
    uint256 constant GAS_AND_PAYLOAD_GAS_LIMIT = 200_000;
    bytes constant GAS_AND_PAYLOAD_PAYLOAD = abi.encodeWithSignature("executePayload(bytes)", bytes("0x1234"));

    uint256 constant TOTAL_PETH_AMOUNT = 
        FUNDS_AMOUNT + 
        FUNDS_AND_PAYLOAD_AMOUNT + 
        GAS_AND_PAYLOAD_AMOUNT + 0.5 ether; // 0.5 ether for extra gas approval

    uint256 constant TOTAL_USDT_AMOUNT = 
        FUNDS_AMOUNT_USDT + 
        FUNDS_AND_PAYLOAD_AMOUNT_USDT + 
        GAS_AND_PAYLOAD_AMOUNT_USDT;

    function run() external {
        vm.startBroadcast();

        _approveTokens();

        _sendTokenRequests(PETH_TOKEN, "pETH");
        _sendTokenRequests(USDT_TOKEN, "USDT");

        vm.stopBroadcast();
    }

    /// @notice Approve both tokens for the gateway
    function _approveTokens() private {
        IERC20(PETH_TOKEN).approve(GATEWAY_PROXY, TOTAL_PETH_AMOUNT);
        IERC20(USDT_TOKEN).approve(GATEWAY_PROXY, TOTAL_USDT_AMOUNT);
    }

    /// @notice Send all three request types for a given token (FUNDS, FUNDS_AND_PAYLOAD, GAS_AND_PAYLOAD)
    /// @param token The token address to use for requests
    /// @param tokenName The token name for logging/debugging
    function _sendTokenRequests(address token, string memory tokenName) private {
        // Determine amounts based on token
        uint256 fundsAmt = _isUSDT(token) ? FUNDS_AMOUNT_USDT : FUNDS_AMOUNT;
        uint256 fundsPayloadAmt = _isUSDT(token) ? FUNDS_AND_PAYLOAD_AMOUNT_USDT : FUNDS_AND_PAYLOAD_AMOUNT;
        uint256 gasPayloadAmt = _isUSDT(token) ? GAS_AND_PAYLOAD_AMOUNT_USDT : GAS_AND_PAYLOAD_AMOUNT;

        // FUNDS request
        _sendRequest(
            COMMON_TARGET,
            token,
            fundsAmt,
            FUNDS_GAS_LIMIT,
            FUNDS_PAYLOAD,
            COMMON_REVERT_RECIPIENT,
            string.concat(tokenName, "_FUNDS")
        );

        // FUNDS_AND_PAYLOAD request
        _sendRequest(
            COMMON_TARGET,
            token,
            fundsPayloadAmt,
            FUNDS_AND_PAYLOAD_GAS_LIMIT,
            FUNDS_AND_PAYLOAD_PAYLOAD,
            COMMON_REVERT_RECIPIENT,
            string.concat(tokenName, "_FUNDS_AND_PAYLOAD")
        );

        // GAS_AND_PAYLOAD request
        _sendRequest(
            COMMON_TARGET,
            token,
            gasPayloadAmt,
            GAS_AND_PAYLOAD_GAS_LIMIT,
            GAS_AND_PAYLOAD_PAYLOAD,
            COMMON_REVERT_RECIPIENT,
            string.concat(tokenName, "_GAS_AND_PAYLOAD")
        );
    }

    /// @notice Helper to check if token is USDT
    function _isUSDT(address token) private pure returns (bool) {
        return token == USDT_TOKEN;
    }

    /// @notice Generic request builder and executor
    /// @param target Destination address (encoded as bytes)
    /// @param token Token address to transfer
    /// @param amount Amount to transfer
    /// @param gasLimit Gas limit for the request
    /// @param payload Execution payload (empty for funds-only)
    /// @param revertRecipient Address for revert refunds
    /// @param requestType String identifier for logging/debugging
    function _sendRequest(
        bytes memory target,
        address token,
        uint256 amount,
        uint256 gasLimit,
        bytes memory payload,
        address revertRecipient,
        string memory requestType
    ) private {
        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            target: target,
            token: token,
            amount: amount,
            gasLimit: gasLimit,
            payload: payload,
            revertRecipient: revertRecipient
        });

        _executeRequest(req, requestType);
    }

    /// @notice Execute a request with try-catch for error handling
    /// @param req The UniversalOutboundTxRequest to execute
    /// @param requestType String identifier for logging/debugging
    function _executeRequest(
        UniversalOutboundTxRequest memory req,
        string memory requestType
    ) private {
        try UniversalGatewayPC(GATEWAY_PROXY).sendUniversalTxOutbound(req) {
            // Request succeeded
        } catch Error(string memory reason) {
            // Expected reverts with error messages during local setup
            // In production setup, these should succeed with proper mocks
        } catch (bytes memory) {
            // Low-level revert data
            // Expected during local setup without full UniversalCore/PRC20 mocks
        }
    }
}
