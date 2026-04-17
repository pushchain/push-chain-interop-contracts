// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  MockReturnFalsePRC20
/// @notice Minimal PRC20 mock that returns false on transferFrom and burn instead of reverting.
///         Used to test that UniversalGatewayPC correctly checks and rejects false return values.
contract MockReturnFalsePRC20 {
    string public SOURCE_CHAIN_NAMESPACE;

    constructor(string memory chainNamespace) {
        SOURCE_CHAIN_NAMESPACE = chainNamespace;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function burn(uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
