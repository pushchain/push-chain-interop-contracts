// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ICEAFactory } from "../../src/interfaces/ICEAFactory.sol";
import { MockCEA } from "./MockCEA.sol";

/**
 * @title MockCEAFactory
 * @notice Mock implementation of ICEAFactory that resembles the real CEAFactory contract
 * @dev Simplified version for testing that maintains key behaviors:
 *      - onlyVault modifier for deployCEA
 *      - Deterministic address computation using salt
 *      - Bidirectional mappings (UEA_to_CEA and CEA_to_UEA)
 *      - Already deployed checks
 *      - Actually deploys MockCEA instances
 */
contract MockCEAFactory is ICEAFactory {
    // =========================
    //           State
    // =========================
    /// @notice Address of the Vault contract that can deploy CEAs
    address public vault;

    /// @notice Mapping from UEA on Push Chain -> CEA on this chain
    mapping(address => address) public UEA_to_CEA;

    /// @notice Mapping from CEA on this chain -> UEA on Push Chain
    mapping(address => address) public CEA_to_UEA;

    /// @notice When true, deployCEA will revert (for failure propagation tests)
    bool public shouldFailDeploy;

    /// @notice When true, deployCEA will return address(0) instead of reverting
    bool public shouldReturnZeroAddress;

    /// @notice Tracks which CEAs have been deployed (have code)
    mapping(address => bool) private _deployed;

    /// @notice Stores deployed MockCEA instances
    mapping(address => MockCEA) private _deployedCEAs;

    // =========================
    //          Errors
    // =========================
    error ZeroAddress();
    error NotVault();
    error CEAAlreadyDeployed();
    error DeployFailed();

    // =========================
    //        Modifiers
    // =========================
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // =========================
    //      Constructor
    // =========================
    constructor() {
        // VAULT will be set after deployment via setVault
        // For tests, we can set it in setUp
    }

    // =========================
    //      Setup (for tests)
    // =========================
    /// @notice Set the Vault address (for test setup)
    /// @dev This is a test helper, not part of the real CEAFactory
    function setVault(address _vault) external {
        vault = _vault;
    }

    /// @notice Set whether deployCEA should fail (for failure propagation tests)
    function setShouldFailDeploy(bool _shouldFail) external {
        shouldFailDeploy = _shouldFail;
    }

    /// @notice Set whether deployCEA should return address(0) (for testing bad factory)
    function setShouldReturnZeroAddress(bool _shouldReturnZero) external {
        shouldReturnZeroAddress = _shouldReturnZero;
    }

    // =========================
    //        View helpers
    // =========================
    /// @inheritdoc ICEAFactory
    function getCEAForPushAccount(address _pushAccount) external view override returns (address cea, bool isDeployed) {
        address mapped = UEA_to_CEA[_pushAccount];
        if (mapped != address(0)) {
            cea = mapped;
        } else {
            cea = _computeCEAInternal(_pushAccount);
        }
        isDeployed = _hasCode(cea);
    }

    // =========================
    //      Core function
    // =========================
    /// @inheritdoc ICEAFactory
    function deployCEA(address ueaOnPush) external override onlyVault returns (address cea) {
        if (ueaOnPush == address(0)) revert ZeroAddress();
        if (shouldFailDeploy) revert DeployFailed();
        if (shouldReturnZeroAddress) return address(0); // Return zero address for testing bad factory

        // If a mapping already exists and code is present, treat as already deployed
        address existing = UEA_to_CEA[ueaOnPush];
        if (existing != address(0) && _hasCode(existing)) {
            revert CEAAlreadyDeployed();
        }

        // Deploy a new MockCEA instance
        MockCEA newCEA = new MockCEA();
        cea = address(newCEA);

        // Mark as deployed
        _deployed[cea] = true;
        _deployedCEAs[cea] = newCEA;

        // Store mappings
        UEA_to_CEA[ueaOnPush] = cea;
        CEA_to_UEA[cea] = ueaOnPush;

        // Note: Real CEAFactory emits CEADeployed event, but we skip it in mock
    }

    /// @inheritdoc ICEAFactory
    function isCEA(address _cea) external view override returns (bool) {
        return CEA_to_UEA[_cea] != address(0);
    }

    /// @inheritdoc ICEAFactory
    function getPushAccountForCEA(address _cea) external view override returns (address uea) {
        return CEA_to_UEA[_cea];
    }

    /// @notice Get the MockCEA instance for a given address (test helper)
    /// @dev This is a test helper, not part of the real CEAFactory
    function getMockCEA(address cea) external view returns (MockCEA) {
        return _deployedCEAs[cea];
    }

    // =========================
    //          Internals
    // =========================
    function _computeCEAInternal(address ueaOnPush) internal view returns (address) {
        // Use similar salt generation as real CEAFactory
        bytes32 salt = _generateSalt(ueaOnPush);

        // In real contract, this uses Clones.predictDeterministicAddress
        // For mock, we compute a deterministic address based on salt and factory address
        // This mimics CREATE2 behavior without circular reference
        // Using a fixed bytecode hash to avoid circular reference
        bytes32 bytecodeHash = keccak256(abi.encodePacked("MOCK_CEA_PROXY"));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }

    function _generateSalt(address ueaOnPush) internal pure returns (bytes32) {
        // Same salt generation as real CEAFactory: keccak256(abi.encode(ueaOnPush))
        return keccak256(abi.encode(ueaOnPush));
    }

    function _hasCode(address addr) internal view returns (bool) {
        // In mock, check our _deployed mapping
        // In real contract, this checks extcodesize
        // Also check if we have a deployed MockCEA instance
        return _deployed[addr] && address(_deployedCEAs[addr]) != address(0);
    }
}
