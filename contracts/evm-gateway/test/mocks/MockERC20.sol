// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice A comprehensive mock ERC20 token for testing purposes
 * @dev Extends OpenZeppelin's ERC20 with additional testing utilities
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    bool public transferPaused;
    bool public mintPaused;
    bool public burnPaused;
    
    mapping(address => bool) public blacklisted;
    
    event TransferPaused(address account);
    event TransferUnpaused(address account);
    event MintPaused(address account);
    event MintUnpaused(address account);
    event BurnPaused(address account);
    event BurnUnpaused(address account);
    event Blacklisted(address account);
    event Unblacklisted(address account);

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _decimals = decimals_;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /**
     * @dev Returns the number of decimals used to get its user representation
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Mints tokens to a specified address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        require(!mintPaused, "MockERC20: minting is paused");
        require(!blacklisted[to], "MockERC20: recipient is blacklisted");
        _mint(to, amount);
    }

    /**
     * @dev Burns tokens from a specified address
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        require(!burnPaused, "MockERC20: burning is paused");
        require(!blacklisted[from], "MockERC20: account is blacklisted");
        _burn(from, amount);
    }

    /**
     * @dev Burns tokens from the caller's balance
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external {
        require(!burnPaused, "MockERC20: burning is paused");
        require(!blacklisted[msg.sender], "MockERC20: account is blacklisted");
        _burn(msg.sender, amount);
    }

    /**
     * @dev Override transfer to add blacklist and pause checks
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        require(!transferPaused, "MockERC20: transfers are paused");
        require(!blacklisted[msg.sender], "MockERC20: sender is blacklisted");
        require(!blacklisted[to], "MockERC20: recipient is blacklisted");
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to add blacklist and pause checks
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        require(!transferPaused, "MockERC20: transfers are paused");
        require(!blacklisted[from], "MockERC20: sender is blacklisted");
        require(!blacklisted[to], "MockERC20: recipient is blacklisted");
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Pauses all transfers
     */
    function pauseTransfers() external {
        transferPaused = true;
        emit TransferPaused(msg.sender);
    }

    /**
     * @dev Unpauses all transfers
     */
    function unpauseTransfers() external {
        transferPaused = false;
        emit TransferUnpaused(msg.sender);
    }

    /**
     * @dev Pauses minting
     */
    function pauseMinting() external {
        mintPaused = true;
        emit MintPaused(msg.sender);
    }

    /**
     * @dev Unpauses minting
     */
    function unpauseMinting() external {
        mintPaused = false;
        emit MintUnpaused(msg.sender);
    }

    /**
     * @dev Pauses burning
     */
    function pauseBurning() external {
        burnPaused = true;
        emit BurnPaused(msg.sender);
    }

    /**
     * @dev Unpauses burning
     */
    function unpauseBurning() external {
        burnPaused = false;
        emit BurnUnpaused(msg.sender);
    }

    /**
     * @dev Blacklists an address (prevents transfers, minting, burning)
     * @param account The address to blacklist
     */
    function blacklist(address account) external {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @dev Removes an address from blacklist
     * @param account The address to unblacklist
     */
    function unblacklist(address account) external {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    /**
     * @dev Checks if an address is blacklisted
     * @param account The address to check
     * @return True if blacklisted, false otherwise
     */
    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    /**
     * @dev Simulates a failed transfer (for testing error conditions)
     * @param to The recipient address
     * @param amount The amount to transfer
     * @return Always returns false to simulate failure
     */
    function simulateTransferFailure(address to, uint256 amount) external pure returns (bool) {
        // This function always reverts to simulate transfer failure
        revert("MockERC20: simulated transfer failure");
    }

    /**
     * @dev Simulates a failed approval (for testing error conditions)
     * @param spender The spender address
     * @param amount The amount to approve
     * @return Always returns false to simulate failure
     */
    function simulateApprovalFailure(address spender, uint256 amount) external pure returns (bool) {
        // This function always reverts to simulate approval failure
        revert("MockERC20: simulated approval failure");
    }

    /**
     * @dev Force sets the balance of an address (for testing purposes)
     * @param account The address to set balance for
     * @param amount The new balance amount
     */
    function forceSetBalance(address account, uint256 amount) external {
        uint256 currentBalance = balanceOf(account);
        if (amount > currentBalance) {
            _mint(account, amount - currentBalance);
        } else if (amount < currentBalance) {
            _burn(account, currentBalance - amount);
        }
    }

    /**
     * @dev Force sets the allowance (for testing purposes)
     * @param owner The owner address
     * @param spender The spender address
     * @param amount The new allowance amount
     */
    function forceSetAllowance(address owner, address spender, uint256 amount) external {
        _approve(owner, spender, amount);
    }

    /**
     * @dev Returns the total supply in a different format (for testing)
     * @return The total supply as a string
     */
    function getTotalSupplyString() external view returns (string memory) {
        return string(abi.encodePacked("Total Supply: ", _toString(totalSupply())));
    }

    /**
     * @dev Internal function to convert uint256 to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
