// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/**
 * @title MockTokenApprovalVariants
 * @notice Consolidated mock token for testing various approve behavior scenarios
 * @dev Replaces MockTokenReturnsFalse, MockTokenNoReturnData, and MockTokenRevertsOnZeroApproval
 *      Use setApprovalBehavior() to configure the desired behavior
 */
contract MockTokenApprovalVariants is MockERC20 {
    /**
     * @notice Enum defining different approval behaviors for testing
     */
    enum ApprovalBehavior {
        NORMAL, // Standard ERC20 behavior (returns true)
        RETURN_FALSE, // Returns false instead of true on approve
        NO_RETURN_DATA, // Simulates tokens with no return value (but still returns true for interface)
        REVERT_ON_ZERO, // Reverts when approving amount = 0
        ALWAYS_REVERT // Always reverts on approve
    }

    ApprovalBehavior public behavior;

    constructor() MockERC20("Approval Variants Token", "AVT", 18, 1000000e18) {
        behavior = ApprovalBehavior.NORMAL;
    }

    /**
     * @notice Configure the approval behavior for testing
     * @param _behavior The desired approval behavior
     */
    function setApprovalBehavior(ApprovalBehavior _behavior) external {
        behavior = _behavior;
    }

    /**
     * @notice Overridden approve function with configurable behavior
     * @param spender The address to approve
     * @param amount The amount to approve
     * @return success Boolean indicating success based on configured behavior
     */
    function approve(address spender, uint256 amount) public override returns (bool) {
        // Handle revert cases first
        if (behavior == ApprovalBehavior.ALWAYS_REVERT) {
            revert("Approve always fails");
        }

        if (behavior == ApprovalBehavior.REVERT_ON_ZERO && amount == 0) {
            revert("Cannot approve zero amount");
        }

        // Store the approval for all non-reverting cases
        _approve(msg.sender, spender, amount);

        // Return based on behavior
        if (behavior == ApprovalBehavior.RETURN_FALSE) {
            return false;
        }

        // NORMAL and NO_RETURN_DATA both return true
        // (NO_RETURN_DATA simulates tokens that don't return, but we still return true for interface compatibility)
        return true;
    }
}
