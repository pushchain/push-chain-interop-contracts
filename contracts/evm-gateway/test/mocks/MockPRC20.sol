// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUniversalCore } from "../../src/interfaces/IUniversalCore.sol";

/**
 * @title MockPRC20
 * @notice Accurate mock implementation of PRC20 for testing
 * @dev This mock closely follows the real PRC20 implementation from pc-core-2nd
 */
contract MockPRC20 {
    // ========= Constants =========
    /// @notice The protocol's privileged executor module (auth & fee sink)
    address public immutable UNIVERSAL_EXECUTOR_MODULE = 0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7;

    // ========= State =========
    /// @notice Source chain this PRC20 mirrors (used for oracle lookups)
    string public SOURCE_CHAIN_NAMESPACE;
    /// @notice Source Chain ERC20 address of the PRC20
    string public SOURCE_TOKEN_ADDRESS;

    /// @notice Classification of this synthetic
    enum TokenType {
        PC,
        NATIVE,
        ERC20
    }

    TokenType public TOKEN_TYPE;

    /// @notice UniversalCore contract providing gas oracles (gas coin token & gas price)
    address public universalCore;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ========= Events =========
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(bytes indexed from, address indexed to, uint256 amount);
    event Withdrawal(address indexed from, bytes indexed to, uint256 amount, uint256 gasFee, uint256 protocolFee);
    event UpdatedUniversalCore(address addr);
    //*** MODIFIERS ***//

    /// @notice Restricts to the Universal Executor Module (protocol owner)
    modifier onlyUniversalExecutor() {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not Universal Executor");
        _;
    }

    //*** CONSTRUCTOR ***//

    /// @dev For testing convenience, we use a constructor instead of initialize pattern
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        string memory sourceChainId_,
        TokenType tokenType_,
        address universalCore_,
        string memory sourceTokenAddress_
    ) {
        require(universalCore_ != address(0), "MockPRC20: zero address");

        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;

        SOURCE_CHAIN_NAMESPACE = sourceChainId_;
        TOKEN_TYPE = tokenType_;
        universalCore = universalCore_;
        SOURCE_TOKEN_ADDRESS = sourceTokenAddress_;
    }

    // ========= View Functions =========
    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ========= IPRC20 Implementation =========
    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "MockPRC20: insufficient allowance");

        unchecked {
            _allowances[sender][msg.sender] = currentAllowance - amount;
        }
        emit Approval(sender, msg.sender, _allowances[sender][msg.sender]);

        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(spender != address(0), "MockPRC20: approve to zero address");
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function burn(uint256 amount) external returns (bool) {
        _burn(msg.sender, amount);
        return true;
    }

    //*** BRIDGE ENTRYPOINTS ***//

    /// @notice         Mint PRC20 on inbound bridge (lock on source)
    /// @dev            Only callable by universalCore or UNIVERSAL_EXECUTOR_MODULE
    /// @param to       Recipient on Push EVM
    /// @param amount   Amount to mint
    function deposit(address to, uint256 amount) external returns (bool) {
        require(msg.sender == universalCore || msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: Invalid sender");

        _mint(to, amount);

        emit Deposit(abi.encodePacked(UNIVERSAL_EXECUTOR_MODULE), to, amount);
        return true;
    }

    //*** GAS FEE DELEGATION TO UNIVERSAL CORE ***//

    /// @notice Get gas fee with custom gas limit (delegates to UniversalCore)
    function withdrawGasFeeWithGasLimit(uint256 gasLimit)
        external
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace,
            uint256 gasLimitUsed
        )
    {
        return IUniversalCore(universalCore).getOutboundTxGasAndFees(address(this), gasLimit);
    }

    //*** ADMIN FUNCTIONS ***//

    /// @notice Update UniversalCore contract (gas coin & price oracle source)
    /// @dev only Universal Executor may update
    function updateUniversalCore(address addr) external onlyUniversalExecutor {
        require(addr != address(0), "MockPRC20: zero address");
        universalCore = addr;
        emit UpdatedUniversalCore(addr);
    }

    /// @notice Update token name
    function setName(string memory newName) external onlyUniversalExecutor {
        _name = newName;
    }

    /// @notice Update token symbol
    function setSymbol(string memory newSymbol) external onlyUniversalExecutor {
        _symbol = newSymbol;
    }

    //*** INTERNAL ERC-20 HELPERS ***//

    /**
     * @notice          Internal function to transfer PRC20 tokens between addresses
     * @dev             Handles the core transfer logic with balance and zero address checks
     * @param sender    Address to transfer tokens from
     * @param recipient Address to transfer tokens to
     * @param amount    Amount of PRC20 tokens to transfer
     */
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0) && recipient != address(0), "MockPRC20: zero address");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "MockPRC20: insufficient balance");

        unchecked {
            _balances[sender] = senderBalance - amount;
            _balances[recipient] += amount;
        }

        emit Transfer(sender, recipient, amount);
    }

    /**
     * @notice          Internal function to mint new PRC20 tokens
     * @dev             Creates new tokens and assigns them to the specified account
     * @dev             Increases total supply and account balance
     * @param account   Address to mint tokens to
     * @param amount    Amount of PRC20 tokens to mint
     */
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "MockPRC20: zero address");
        require(amount > 0, "MockPRC20: zero amount");

        unchecked {
            _totalSupply += amount;
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /**
     * @notice          Internal function to burn PRC20 tokens
     * @dev             Burns tokens from the specified account and reduces total supply
     * @param account   Address to burn tokens from
     * @param amount    Amount of PRC20 tokens to burn
     */
    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "MockPRC20: zero address");
        require(amount > 0, "MockPRC20: zero amount");

        uint256 bal = _balances[account];
        require(bal >= amount, "MockPRC20: insufficient balance");

        unchecked {
            _balances[account] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    // ========= Test Helper Functions =========
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function setAllowance(address owner, address spender, uint256 amount) external {
        _allowances[owner][spender] = amount;
    }
}
