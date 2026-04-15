// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IUniversalCore } from "../../src/interfaces/IUniversalCore.sol";
import { MockPRC20 } from "./MockPRC20.sol";

/**
 * @title MockUniversalCoreReal
 * @notice Accurate mock implementation of UniversalCore for testing
 * @dev This mock closely follows the real UniversalCore implementation from pc-core-2nd
 */
contract MockUniversalCoreReal is IUniversalCore {
    // ========= State =========
    /// @notice Fungible address is always the same, it's on protocol level.
    address public immutable UNIVERSAL_EXECUTOR_MODULE;

    /// @notice Map to know the gas price of each chain given a chain id.
    mapping(string => uint256) public gasPriceByChainNamespace;

    /// @notice Map to know the PRC20 address of a token given a chain id, ex pETH, pBNB etc.
    mapping(string => address) public gasTokenPRC20ByChainNamespace;

    /// @notice Map to know Uniswap V3 pool of PC/PRC20 given a chain id.
    mapping(string => address) public gasPCPoolByChainId;

    /// @notice Supproted token list for auto swap to PC using Uniswap V3.
    mapping(address => bool) public isAutoSwapSupported;

    /// @notice Default fee tier for each token (0 = not set)
    mapping(address => uint24) public defaultFeeTier;

    /// @notice Slippage tolerance for each token in basis points (e.g., 300 = 3%)
    mapping(address => uint256) public slippageTolerance;

    /// @notice Default deadline in minutes for swaps
    uint256 public defaultDeadlineMins = 20;

    /// @notice Uniswap V3 addresses.
    address public uniswapV3FactoryAddress;
    address public uniswapV3SwapRouterAddress;
    address public uniswapV3QuoterAddress;

    /// @notice Address of the wrapped PC to interact with Uniswap V3.
    address public wPCContractAddress;

    /// @notice Base gas limit for the cross-chain outbound transactions.
    uint256 public BASE_GAS_LIMIT = 500_000;

    /// @notice Per-chain base gas limit (fallback when BASE_GAS_LIMIT is 0).
    mapping(string => uint256) public baseGasLimitByChainNamespace;

    /// @notice Protocol fee per token in native PC
    mapping(address => uint256) public protocolFeeByToken;

    /// @notice Rescue funds gas limit per chain namespace
    mapping(string => uint256) public rescueFundsGasLimitByChainNamespace;

    /// @notice Role for managing gas-related configurations
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    // Role assignments
    mapping(bytes32 => mapping(address => bool)) private _roles;

    // Pause state
    bool private _paused;

    // Supported tokens mapping
    mapping(address => bool) private _supportedTokens;

    // ========= Events =========
    event SetGasPrice(string indexed chainID, uint256 price);
    event SetGasToken(string indexed chainID, address token);
    event SetGasPCPool(string indexed chainID, address pool, uint24 fee);
    event SetAutoSwapSupported(address indexed token, bool supported);
    event SetWPC(address addr);
    event SetUniswapV3Addresses(address factory, address swapRouter, address quoter);
    event SetDefaultFeeTier(address indexed token, uint24 feeTier);
    event SetSlippageTolerance(address indexed token, uint256 tolerance);
    event SetDefaultDeadlineMins(uint256 mins);
    event BaseGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event DepositPRC20WithAutoSwap(
        address indexed prc20, uint256 amountIn, address indexed wpc, uint256 pcOut, uint24 fee, address indexed target
    );

    constructor(address uem) {
        UNIVERSAL_EXECUTOR_MODULE = uem;
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        _roles[MANAGER_ROLE][uem] = true;
    }

    // ========= Modifiers =========
    modifier onlyUEModule() {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockUniversalCore: caller is not UEM");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), "MockUniversalCore: caller doesn't have role");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "MockUniversalCore: paused");
        _;
    }

    // ========= Role Functions =========
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
    }

    // ========= Token Support Functions =========
    function isSupportedToken(address token) external view returns (bool) {
        return _supportedTokens[token];
    }

    function setSupportedToken(address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _supportedTokens[token] = supported;
    }

    // ========= Core Functions =========
    function depositPRC20Token(address prc20, uint256 amount, address target) external onlyUEModule whenNotPaused {
        require(target != UNIVERSAL_EXECUTOR_MODULE && target != address(this), "MockUniversalCore: invalid target");
        require(prc20 != address(0), "MockUniversalCore: zero address");
        require(amount > 0, "MockUniversalCore: zero amount");

        // Call deposit directly on the contract without interface casting
        // since MockPRC20 has deposit() but IPRC20 interface doesn't
        (bool success,) = prc20.call(abi.encodeWithSignature("deposit(address,uint256)", target, amount));
        require(success, "MockUniversalCore: deposit failed");
    }

    function depositPRC20WithAutoSwap(
        address prc20,
        uint256 amount,
        address target,
        uint24 fee,
        uint256 minPCOut,
        uint256 deadline
    ) external onlyUEModule whenNotPaused {
        require(target != UNIVERSAL_EXECUTOR_MODULE && target != address(this), "MockUniversalCore: invalid target");
        require(prc20 != address(0), "MockUniversalCore: zero address");
        require(amount > 0, "MockUniversalCore: zero amount");
        require(isAutoSwapSupported[prc20], "MockUniversalCore: auto swap not supported");

        // Use default fee tier if not provided
        if (fee == 0) {
            fee = defaultFeeTier[prc20];
            require(fee != 0, "MockUniversalCore: invalid fee tier");
        }

        if (deadline == 0) {
            deadline = block.timestamp + (defaultDeadlineMins * 1 minutes);
        }

        require(block.timestamp <= deadline, "MockUniversalCore: deadline expired");

        // In the mock, we'll simulate the swap without actually doing it
        uint256 pcOut = amount; // Simplified for testing

        // Emit the event to track the call
        emit DepositPRC20WithAutoSwap(prc20, amount, wPCContractAddress, pcOut, fee, target);
    }

    // ========= Manager Functions =========
    function setGasPCPool(string memory chainID, address gasToken, uint24 fee) external onlyRole(MANAGER_ROLE) {
        require(gasToken != address(0), "MockUniversalCore: zero address");

        // In the real implementation, we would get the pool from Uniswap V3 Factory
        // For the mock, we'll just use the gasToken as the pool address
        address pool = gasToken; // Simplified for testing

        gasPCPoolByChainId[chainID] = pool;
        emit SetGasPCPool(chainID, pool, fee);
    }

    function setGasPrice(string memory chainID, uint256 price) external onlyRole(MANAGER_ROLE) {
        gasPriceByChainNamespace[chainID] = price;
        emit SetGasPrice(chainID, price);
    }

    function setGasTokenPRC20(string memory chainID, address prc20) external onlyRole(MANAGER_ROLE) {
        require(prc20 != address(0), "MockUniversalCore: zero address");
        gasTokenPRC20ByChainNamespace[chainID] = prc20;
        emit SetGasToken(chainID, prc20);
    }

    function setProtocolFeeByToken(address token, uint256 fee) external onlyRole(MANAGER_ROLE) {
        protocolFeeByToken[token] = fee;
    }

    function setRescueFundsGasLimitByChain(string memory chainNamespace, uint256 gasLimit)
        external
        onlyRole(MANAGER_ROLE)
    {
        rescueFundsGasLimitByChainNamespace[chainNamespace] = gasLimit;
    }

    // ========= Admin Functions =========
    modifier onlyOwner() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "MockUniversalCore: caller is not owner");
        _;
    }

    function setAutoSwapSupported(address token, bool supported) external onlyOwner {
        isAutoSwapSupported[token] = supported;
        emit SetAutoSwapSupported(token, supported);
    }

    function setWPCContractAddress(address addr) external onlyOwner {
        require(addr != address(0), "MockUniversalCore: zero address");
        wPCContractAddress = addr;
        emit SetWPC(addr);
    }

    function setUniswapV3Addresses(address factory, address swapRouter, address quoter) external onlyOwner {
        require(
            factory != address(0) && swapRouter != address(0) && quoter != address(0), "MockUniversalCore: zero address"
        );
        uniswapV3FactoryAddress = factory;
        uniswapV3SwapRouterAddress = swapRouter;
        uniswapV3QuoterAddress = quoter;
        emit SetUniswapV3Addresses(factory, swapRouter, quoter);
    }

    function setDefaultFeeTier(address token, uint24 feeTier) external onlyOwner {
        require(token != address(0), "MockUniversalCore: zero address");
        require(feeTier == 500 || feeTier == 3000 || feeTier == 10000, "MockUniversalCore: invalid fee tier");
        defaultFeeTier[token] = feeTier;
        emit SetDefaultFeeTier(token, feeTier);
    }

    function setSlippageTolerance(address token, uint256 tolerance) external onlyOwner {
        require(token != address(0), "MockUniversalCore: zero address");
        require(tolerance <= 5000, "MockUniversalCore: invalid slippage tolerance"); // Max 50%
        slippageTolerance[token] = tolerance;
        emit SetSlippageTolerance(token, tolerance);
    }

    function setDefaultDeadlineMins(uint256 minutesValue) external onlyOwner {
        defaultDeadlineMins = minutesValue;
        emit SetDefaultDeadlineMins(minutesValue);
    }

    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }

    // ========= View Functions =========
    function paused() external view returns (bool) {
        return _paused;
    }

    function getSwapQuote(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) public returns (uint256) {
        // Simplified implementation for testing
        return amountIn;
    }

    function getOutboundTxGasAndFees(address _prc20, uint256 gasLimit)
        public
        view
        returns (address gasToken, uint256 gasFee, uint256 protocolFee, uint256 gasPrice, string memory chainNamespace)
    {
        chainNamespace = MockPRC20(_prc20).SOURCE_CHAIN_NAMESPACE();

        gasToken = gasTokenPRC20ByChainNamespace[chainNamespace];
        require(gasToken != address(0), "MockUniversalCore: zero gas token");

        gasPrice = gasPriceByChainNamespace[chainNamespace];
        require(gasPrice != 0, "MockUniversalCore: zero gas price");

        gasFee = gasPrice * gasLimit;
        protocolFee = protocolFeeByToken[_prc20];
    }

    function getRescueFundsGasLimit(address _prc20)
        public
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 rescueGasLimit,
            uint256 gasPrice,
            string memory chainNamespace
        )
    {
        chainNamespace = MockPRC20(_prc20).SOURCE_CHAIN_NAMESPACE();

        rescueGasLimit = rescueFundsGasLimitByChainNamespace[chainNamespace];
        require(rescueGasLimit != 0, "MockUniversalCore: zero rescue gas limit");

        gasToken = gasTokenPRC20ByChainNamespace[chainNamespace];
        require(gasToken != address(0), "MockUniversalCore: zero gas token");

        gasPrice = gasPriceByChainNamespace[chainNamespace];
        require(gasPrice != 0, "MockUniversalCore: zero gas price");

        gasFee = gasPrice * rescueGasLimit;
    }

    /// @notice Update the base gas limit for the cross-chain outbound transactions.
    /// @param  gasLimit New base gas limit
    function updateBaseGasLimit(uint256 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldLimit = BASE_GAS_LIMIT;
        BASE_GAS_LIMIT = gasLimit;
        emit BaseGasLimitUpdated(oldLimit, gasLimit);
    }

    // ========= Swap Functions =========
    function swapAndBurnGas(
        address gasTokenAddr,
        uint24,
        uint256 gasFee,
        uint256,
        address caller
    ) external payable returns (uint256 gasTokenOut, uint256 refund) {
        require(gasFee > 0, "MockUniversalCore: zero total output");

        // Burn gasFee portion (mint then burn to simulate swap+burn)
        MockPRC20(gasTokenAddr).mint(address(this), gasFee);
        MockPRC20(gasTokenAddr).burn(gasFee);

        gasTokenOut = gasFee;

        // Refund unused PC directly to the caller (1:1 ratio for mock simplicity)
        if (msg.value > gasFee) {
            refund = msg.value - gasFee;
            (bool ok,) = caller.call{value: refund}("");
            require(ok, "MockUniversalCore: refund failed");
        }
    }

    receive() external payable {}

    // ========= Test Helper Functions =========
    function setUniversalExecutorModule(address _uem) external {
        // This is just for test compatibility with the old mock
        // In the real contract, UEM is immutable
    }
}
