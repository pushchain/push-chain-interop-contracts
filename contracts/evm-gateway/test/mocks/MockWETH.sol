// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

/**
 * @title MockWETH
 * @notice A mock WETH (Wrapped Ether) contract for testing purposes
 * @dev Implements the IWETH interface with additional testing utilities
 */
contract MockWETH is ERC20, IWETH {
    uint8 private constant _DECIMALS = 18;
    
    bool public depositPaused;
    bool public withdrawPaused;
    bool public transferPaused;
    
    mapping(address => bool) public blacklisted;
    
    event DepositPaused(address account);
    event DepositUnpaused(address account);
    event WithdrawPaused(address account);
    event WithdrawUnpaused(address account);
    event TransferPaused(address account);
    event TransferUnpaused(address account);
    event Blacklisted(address account);
    event Unblacklisted(address account);
    event MockDeposit(address indexed dst, uint256 wad);
    event MockWithdrawal(address indexed src, uint256 wad);

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        // No initial supply - WETH is typically minted through deposits
    }

    /**
     * @dev Returns the number of decimals used to get its user representation
     */
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /**
     * @dev Deposit ETH and mint WETH tokens
     */
    function deposit() external payable {
        require(!depositPaused, "MockWETH: deposits are paused");
        require(!blacklisted[msg.sender], "MockWETH: account is blacklisted");
        require(msg.value > 0, "MockWETH: deposit amount must be greater than 0");
        
        _mint(msg.sender, msg.value);
        emit MockDeposit(msg.sender, msg.value);
    }

    /**
     * @dev Withdraw WETH tokens and receive ETH
     * @param wad The amount of WETH to withdraw
     */
    function withdraw(uint256 wad) external override {
        require(!withdrawPaused, "MockWETH: withdrawals are paused");
        require(!blacklisted[msg.sender], "MockWETH: account is blacklisted");
        require(wad > 0, "MockWETH: withdrawal amount must be greater than 0");
        require(balanceOf(msg.sender) >= wad, "MockWETH: insufficient balance");
        
        _burn(msg.sender, wad);
        
        // In a real WETH contract, this would transfer ETH
        // For testing, we'll just emit an event
        emit MockWithdrawal(msg.sender, wad);
        
        // Simulate ETH transfer (in real contract: payable(msg.sender).transfer(wad))
        // For testing purposes, we'll just emit the event
    }

    /**
     * @dev Override transfer to add blacklist and pause checks
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        require(!transferPaused, "MockWETH: transfers are paused");
        require(!blacklisted[msg.sender], "MockWETH: sender is blacklisted");
        require(!blacklisted[to], "MockWETH: recipient is blacklisted");
        return super.transfer(to, amount);
    }

    /**
     * @dev Override transferFrom to add blacklist and pause checks
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        require(!transferPaused, "MockWETH: transfers are paused");
        require(!blacklisted[from], "MockWETH: sender is blacklisted");
        require(!blacklisted[to], "MockWETH: recipient is blacklisted");
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev Mints WETH tokens to a specified address (for testing)
     * @param to The address to mint tokens to
     * @param amount The amount of WETH to mint
     */
    function mint(address to, uint256 amount) external {
        require(!blacklisted[to], "MockWETH: recipient is blacklisted");
        _mint(to, amount);
    }

    /**
     * @dev Burns WETH tokens from a specified address (for testing)
     * @param from The address to burn tokens from
     * @param amount The amount of WETH to burn
     */
    function burn(address from, uint256 amount) external {
        require(!blacklisted[from], "MockWETH: account is blacklisted");
        _burn(from, amount);
    }

    /**
     * @dev Burns WETH tokens from the caller's balance (for testing)
     * @param amount The amount of WETH to burn
     */
    function burn(uint256 amount) external {
        require(!blacklisted[msg.sender], "MockWETH: account is blacklisted");
        _burn(msg.sender, amount);
    }

    /**
     * @dev Pauses deposits
     */
    function pauseDeposits() external {
        depositPaused = true;
        emit DepositPaused(msg.sender);
    }

    /**
     * @dev Unpauses deposits
     */
    function unpauseDeposits() external {
        depositPaused = false;
        emit DepositUnpaused(msg.sender);
    }

    /**
     * @dev Pauses withdrawals
     */
    function pauseWithdrawals() external {
        withdrawPaused = true;
        emit WithdrawPaused(msg.sender);
    }

    /**
     * @dev Unpauses withdrawals
     */
    function unpauseWithdrawals() external {
        withdrawPaused = false;
        emit WithdrawUnpaused(msg.sender);
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
     * @dev Blacklists an address (prevents deposits, withdrawals, transfers)
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
     * @dev Simulates a failed deposit (for testing error conditions)
     */
    function simulateDepositFailure() external pure {
        revert("MockWETH: simulated deposit failure");
    }

    /**
     * @dev Simulates a failed withdrawal (for testing error conditions)
     */
    function simulateWithdrawalFailure(uint256 /* wad */) external pure {
        revert("MockWETH: simulated withdrawal failure");
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
     * @dev Returns the WETH balance in ETH equivalent
     * @param account The account to check
     * @return The balance in wei
     */
    function getETHBalance(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @dev Converts WETH amount to ETH amount (1:1 ratio)
     * @param wad The WETH amount
     * @return The equivalent ETH amount
     */
    function wethToEth(uint256 wad) external pure returns (uint256) {
        return wad; // 1:1 ratio
    }

    /**
     * @dev Converts ETH amount to WETH amount (1:1 ratio)
     * @param ethAmount The ETH amount
     * @return The equivalent WETH amount
     */
    function ethToWeth(uint256 ethAmount) external pure returns (uint256) {
        return ethAmount; // 1:1 ratio
    }

    /**
     * @dev Returns the total supply in ETH equivalent
     * @return The total supply in wei
     */
    function getTotalSupplyInETH() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @dev Simulates a real ETH transfer (for testing purposes)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function simulateETHTransfer(address to, uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "MockWETH: insufficient balance");
        _burn(msg.sender, amount);
        _mint(to, amount);
    }

    /**
     * @dev Returns contract information as a string
     * @return Contract info string
     */
    function getContractInfo() external view returns (string memory) {
        return string(abi.encodePacked(
            "MockWETH - ",
            name(),
            " (",
            symbol(),
            ") - Total Supply: ",
            _toString(totalSupply()),
            " wei"
        ));
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
