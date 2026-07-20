// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { UniversalGateway } from "../src/UniversalGateway.sol";
import { IUniversalGateway } from "../src/interfaces/IUniversalGateway.sol";
import { TX_TYPE, RevertInstructions, VerificationType, PRC_20_SELECTOR } from "../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../src/libraries/TypesUG.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MockAggregatorV3 } from "./mocks/MockAggregatorV3.sol";
import { MockSequencerUptimeFeed } from "./mocks/MockSequencerUptimeFeed.sol";

// TetherToken interface for USDT
interface TetherToken {
    function transfer(address to, uint256 amount) external;

    function approve(address spender, uint256 amount) external;
}

/**
 * @title BaseTest
 * @notice Abstract base test contract for UniversalGateway
 * @dev Provides complete setup, mocks, and helper functions for all gateway tests
 *      Inherit from this contract to avoid redundant setup code
 */
abstract contract BaseTest is Test {
    // =========================
    //           ACTORS
    // =========================
    address public governance;
    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public user3;
    address public user4;
    address public attacker;
    address public recipient;

    address public roleManager;
    address public ugAdmin;
    address public operator;

    // =========================
    //        CONTRACTS
    // =========================
    UniversalGateway public gateway;
    TransparentUpgradeableProxy public gatewayProxy;
    ProxyAdmin public proxyAdmin;

    // =========================
    //          MOCKS
    // =========================
    MockERC20 public tokenA;
    MockERC20 public usdc;
    MockWETH public weth;
    // Chainlink mocks
    MockAggregatorV3 public ethUsdFeedMock;
    MockSequencerUptimeFeed public sequencerMock;

    // =========================
    //      UNISWAP PLACEHOLDERS
    // =========================
    address public uniV3Factory;
    address public uniV3Router;

    // =========================
    //      DEFAULT CONFIG and Constants
    // =========================
    uint256 public constant MIN_CAP_USD = 1e18; // $1 (1e18 = $1)
    uint256 public constant MAX_CAP_USD = 10e18; // $10 (1e18 = $1)

    // Chainlink defaults (matches gateway expectations)
    uint8 public constant CHAINLINK_DECIMALS = 8;
    int256 public constant DEFAULT_ETH_USD_1e8 = 2_000e8; // $2,000 with 8 decimals

    // =========================
    //      TEST CONSTANTS
    // =========================
    uint256 public constant LARGE_AMOUNT = 1_000_000 * 1e18;
    uint256 public constant LARGE_AMOUNT_USDC = 1_000_000 * 1e6;
    uint256 public constant LARGE_AMOUNT_WETH = 1_000 ether;

    // =========================
    //         SETUP
    // =========================
    function setUp() public virtual {
        _createActors();
        _fundActors();
        _deployMocks();
        _deployUniswapPlaceholders();
        _deployGateway();
        _initializeGateway();
        _deployOracles();
        _wireOraclesToGateway();
        _setupNativeTokenSupport();
        _mintAndApproveTokens();
    }

    // =========================
    //      ACTOR CREATION
    // =========================
    function _createActors() internal {
        governance = address(0x1);
        admin = governance; // Same as governance for clarity
        pauser = address(0x2);
        tss = address(0x3);
        user1 = address(0x4);
        user2 = address(0x5);
        user3 = address(0x6);
        user4 = address(0x7);
        attacker = address(0x8);
        recipient = address(0x9);

        vm.label(governance, "governance");
        vm.label(admin, "admin");
        vm.label(pauser, "pauser");
        vm.label(tss, "tss");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(user3, "user3");
        vm.label(user4, "user4");
        vm.label(attacker, "attacker");
        vm.label(recipient, "recipient");

        roleManager = admin;
        ugAdmin = admin;
        operator = admin;
    }

    function _fundActors() internal {
        vm.deal(admin, 100 ether);
        vm.deal(tss, 1 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);
        vm.deal(user4, 1000 ether);
        vm.deal(attacker, 1000 ether);
        // recipient intentionally has 0 ether
    }

    // =========================
    //      MOCKS
    // =========================
    function _deployMocks() internal {
        weth = new MockWETH("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC", 6, 0);
        tokenA = new MockERC20("TokenA", "TKA", 18, 0);

        vm.label(address(weth), "WETH");
        vm.label(address(usdc), "USDC");
        vm.label(address(tokenA), "TokenA");
    }

    // =========================
    //      UNISWAP PLACEHOLDERS
    // =========================
    function _deployUniswapPlaceholders() internal {
        // No Uniswap integration by default - pass zero addresses
        // Tests can override this if they need real Uniswap functionality
        uniV3Factory = address(0);
        uniV3Router = address(0);
    }

    // =========================
    //      GATEWAY DEPLOYMENT
    // =========================
    function _deployGateway() internal {
        // Deploy implementation
        UniversalGateway implementation = new UniversalGateway();

        // Deploy proxy admin
        proxyAdmin = new ProxyAdmin(admin);

        // Deploy transparent upgradeable proxy
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            pauser,
            tss,
            address(this), // vault address
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            address(weth)
        );

        gatewayProxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        // Cast proxy to gateway interface
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        vm.label(address(gateway), "UniversalGateway");
        vm.label(address(gatewayProxy), "GatewayProxy");
        vm.label(address(proxyAdmin), "ProxyAdmin");
    }

    function _initializeGateway() internal {
        // Gateway is already initialized via proxy constructor
        // Verify initialization
        assertEq(gateway.tssAddress(), tss);
        assertEq(gateway.minCapUniversalTxUsd(), MIN_CAP_USD);
        assertEq(gateway.maxCapUniversalTxUsd(), MAX_CAP_USD);
        assertEq(gateway.weth(), address(weth));
    }

    // =========================
    //      ORACLE (CHAINLINK) MOCKS & WIRING
    // =========================
    function _deployOracles() internal {
        ethUsdFeedMock = new MockAggregatorV3(CHAINLINK_DECIMALS);
        // seed with a sane, fresh price
        ethUsdFeedMock.setAnswer(DEFAULT_ETH_USD_1e8, block.timestamp);

        // Sequencer feed is optional; default to a deployed mock but not wired.
        sequencerMock = new MockSequencerUptimeFeed();
        // default status: UP (0)
        sequencerMock.setStatus(false, block.timestamp);
    }

    function _wireOraclesToGateway() internal {
        // Set ETH/USD feed on the gateway (required for any cap checks)
        vm.prank(admin);
        gateway.setEthUsdFeed(address(ethUsdFeedMock));
        // chainlinkStalePeriod already set by initialize(); leave as-is unless tests override
    }

    function _setupNativeTokenSupport() internal {
        // Set up native token (address(0)) support for sendFunds
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(0); // Native token
        thresholds[0] = 1000000 ether; // Large threshold for native token

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    // === Convenience setters for tests ===
    function setEthUsdPrice1e8(int256 price1e8) internal {
        ethUsdFeedMock.setAnswer(price1e8, block.timestamp);
    }

    function setChainlinkStalePeriod(uint256 staleSec) internal {
        vm.prank(admin);
        gateway.setChainlinkStalePeriod(staleSec);
    }

    function enableSequencerFeed(bool enable) internal {
        vm.prank(admin);
        gateway.setL2SequencerFeed(enable ? address(sequencerMock) : address(0));
    }

    function setSequencerStatusDown(bool isDown) internal {
        sequencerMock.setStatus(isDown, block.timestamp);
    }

    function setSequencerGracePeriod(uint256 graceSec) internal {
        vm.prank(admin);
        gateway.setL2SequencerGracePeriod(graceSec);
    }

    // =========================
    //      TOKEN MINTING & APPROVALS
    // =========================
    function _mintAndApproveTokens() internal {
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = attacker;

        // Mint and approve tokenA
        for (uint256 i = 0; i < users.length; i++) {
            mintAndApprove(IERC20(address(tokenA)), users[i], address(gateway), LARGE_AMOUNT);
        }

        // Mint and approve USDC
        for (uint256 i = 0; i < users.length; i++) {
            mintAndApprove(IERC20(address(usdc)), users[i], address(gateway), LARGE_AMOUNT_USDC);
        }

        // Mint and approve WETH
        for (uint256 i = 0; i < users.length; i++) {
            mintWETH(users[i], LARGE_AMOUNT_WETH);
            vm.prank(users[i]);
            weth.approve(address(gateway), type(uint256).max);
        }
    }

    // =========================
    //      PAYLOAD and REVERT BUILDERS Helpers
    // =========================
    function buildMinimalPayload(address to, bytes memory data)
        internal
        view
        returns (UniversalPayload memory p, bytes32 h)
    {
        p = UniversalPayload({
            to: to,
            value: 0,
            data: data,
            gasLimit: 500_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: block.number,
            deadline: block.timestamp + 1 days,
            vType: VerificationType.signedVerification
        });
        h = keccak256(abi.encode(p));
    }

    function buildValuePayload(address to, bytes memory data, uint256 value)
        internal
        view
        returns (UniversalPayload memory p, bytes32 h)
    {
        p = UniversalPayload({
            to: to,
            value: value,
            data: data,
            gasLimit: 500_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: block.number,
            deadline: block.timestamp + 1 days,
            vType: VerificationType.signedVerification
        });
        h = keccak256(abi.encode(p));
    }

    function revertCfg(address revertRecipient_) internal pure returns (RevertInstructions memory) {
        return RevertInstructions({ revertRecipient: revertRecipient_, revertMsg: bytes("") });
    }

    /// @notice Build a default payload for testing (commonly used across test files)
    /// @dev Returns a simple payload with default values
    function buildDefaultPayload() internal view returns (UniversalPayload memory) {
        return UniversalPayload({
            to: address(0x123),
            value: 0,
            data: bytes(""),
            gasLimit: 100000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 0,
            deadline: 0,
            vType: VerificationType.signedVerification
        });
    }

    /// @notice Build default revert instructions for testing (commonly used across test files)
    /// @dev Returns revert instructions with a default recipient
    function buildDefaultRevertInstructions() internal pure returns (RevertInstructions memory) {
        return RevertInstructions({ revertRecipient: address(0x456), revertMsg: bytes("") });
    }

    // =========================
    //      UNIVERSAL TX REQUEST BUILDERS
    // =========================

    /// @notice Build a UniversalTxRequest for GAS_AND_PAYLOAD transactions
    /// @dev Creates a request that routes to TX_TYPE.GAS_AND_PAYLOAD
    ///      Requirements: recipient=address(0), token=address(0), amount=0, non-empty payload, msg.value>0
    /// @return UniversalTxRequest struct configured for GAS_AND_PAYLOAD route
    function _buildGasTxRequest() internal view virtual returns (UniversalTxRequest memory) {
        UniversalPayload memory payload = buildDefaultPayload();
        return UniversalTxRequest({
            recipient: address(0), // GAS routes always use address(0) for UEA credit
            token: address(0), // Native token
            amount: 0, // No funds (amount = 0) for GAS/GAS_AND_PAYLOAD routes
            payload: abi.encode(payload), // Non-empty payload routes to GAS_AND_PAYLOAD
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    /// @notice Build a UniversalTxRequest for FUNDS transactions
    /// @param token Token address (address(0) for native, or ERC20 token address)
    /// @param amount Amount of tokens to send
    /// @return UniversalTxRequest struct configured for FUNDS route
    function _buildFundsTxRequest(address token, uint256 amount)
        internal
        pure
        virtual
        returns (UniversalTxRequest memory)
    {
        return _buildFundsTxRequest(token, amount, address(0x456));
    }

    /// @notice Build a UniversalTxRequest for FUNDS transactions with custom fund recipient
    /// @param token Token address (address(0) for native, or ERC20 token address)
    /// @param amount Amount of tokens to send
    /// @param revertRecipient Address to receive funds in case of revert
    /// @return UniversalTxRequest struct configured for FUNDS route
    function _buildFundsTxRequest(address token, uint256 amount, address revertRecipient)
        internal
        pure
        virtual
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: address(0), // FUNDS requires recipient == address(0) for UEA credit
            token: token,
            amount: amount,
            payload: bytes(""), // Empty payload for FUNDS route
            revertRecipient: revertRecipient,
            signatureData: bytes("")
        });
    }

    /// @notice Build a UniversalTxRequest for FUNDS_AND_PAYLOAD transactions
    /// @dev Creates a request that routes to TX_TYPE.FUNDS_AND_PAYLOAD
    ///      Requirements: recipient=address(0), non-zero amount, non-empty payload
    /// @param token Token address (address(0) for native, or ERC20 token address)
    /// @param amount Amount of tokens to send
    /// @param payload UniversalPayload to encode in the request
    /// @return UniversalTxRequest struct configured for FUNDS_AND_PAYLOAD route
    function _buildFundsAndPayloadTxRequest(address token, uint256 amount, UniversalPayload memory payload)
        internal
        pure
        virtual
        returns (UniversalTxRequest memory)
    {
        return UniversalTxRequest({
            recipient: address(0), // FUNDS_AND_PAYLOAD requires recipient == address(0) for UEA credit
            token: token,
            amount: amount,
            payload: abi.encode(payload), // Non-empty payload required for FUNDS_AND_PAYLOAD
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    // =========================
    //      MINT & APPROVE HELPERS
    // =========================
    function mintAndApprove(IERC20 token, address owner, address spender, uint256 amt) internal {
        // Mint tokens to owner
        if (address(token) == address(tokenA)) {
            tokenA.mint(owner, amt);
        } else if (address(token) == address(usdc)) {
            usdc.mint(owner, amt);
        } else {
            revert("Unsupported token");
        }

        // Approve spender
        vm.prank(owner);
        token.approve(spender, amt);
    }

    function mintWETH(address to, uint256 amtWei) internal {
        vm.deal(address(this), amtWei);
        weth.deposit{ value: amtWei }();
        weth.transfer(to, amtWei);
    }

    // =========================
    //      ADMIN CONFIG SETTERS (Gateway)
    // =========================

    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) internal {
        vm.prank(admin);
        gateway.setV3FeeOrder(a, b, c);
    }

    function setUniswapV3Config(address factory, address router) internal {
        vm.prank(admin);
        gateway.updateUniswapV3Config(factory, router);
    }

    function setCaps(uint256 minUsd1e18, uint256 maxUsd1e18) internal {
        vm.prank(admin);
        gateway.setCapsUSD(minUsd1e18, maxUsd1e18);
    }

    function toggleSupport(address token, bool supported) internal {
        address[] memory tokens = new address[](1);
        bool[] memory supportFlags = new bool[](1);
        tokens[0] = token;
        supportFlags[0] = supported;

        vm.prank(admin);
        // Set threshold to a large value to enable support (0 means unsupported)
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = supported ? 1000000 ether : 0;
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    // =========================
    //      EVENT ORDERING UTILITIES
    // =========================
    function recordAndGetLogs() internal returns (Vm.Log[] memory) {
        vm.recordLogs();
        return vm.getRecordedLogs();
    }

    function assertDualEmitOrder(bytes32 firstTopic0, bytes32 secondTopic0, Vm.Log[] memory logs) internal {
        bool firstFound = false;
        bool secondFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == firstTopic0) {
                firstFound = true;
            }
            if (logs[i].topics[0] == secondTopic0) {
                secondFound = true;
                require(firstFound, "First event not found before second event");
            }
        }

        require(firstFound && secondFound, "Both events not found");
    }

    // =========================
    //      RECEIVE FALLBACK
    // =========================
    receive() external payable { }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Prefix a payload with PRC_20_SELECTOR to match _routeUniversalTx processing
    /// @dev PRC20 payloads are prefixed with PRC_20_SELECTOR in _routeUniversalTx
    function _pp(bytes memory p) internal pure returns (bytes memory) {
        return abi.encodePacked(PRC_20_SELECTOR, p);
    }

    /// @notice Build a UniversalPayload for testing
    /// @param to Target address
    /// @param data Calldata
    /// @param value ETH value
    /// @return payload UniversalPayload struct
    /// @return revertCfg RevertInstructions struct
    function buildERC20Payload(address to, bytes memory data, uint256 value)
        internal
        pure
        virtual
        returns (UniversalPayload memory, RevertInstructions memory)
    {
        UniversalPayload memory payload = UniversalPayload({
            to: to,
            value: value,
            data: data,
            gasLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 0,
            deadline: 0,
            vType: VerificationType(0)
        });

        RevertInstructions memory revertCfg_ = RevertInstructions({ revertRecipient: to, revertMsg: bytes("") });

        return (payload, revertCfg_);
    }

    /// @notice Fund user with mainnet tokens by impersonating whales
    /// @param user User address to fund
    /// @param token Token address to transfer
    /// @param amount Amount to transfer
    function fundUserWithMainnetTokens(address user, address token, uint256 amount) internal virtual {
        // Find a whale address that has the token
        address whale;
        if (token == 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) {
            // WETH
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else if (token == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) {
            // USDC
            whale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; // SKY
        } else if (token == 0xdAC17F958D2ee523a2206206994597C13D831ec7) {
            // USDT
            whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC; // Binance 20
        } else if (token == 0x6B175474E89094C44Da98b954EedeAC495271d0F) {
            // DAI
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else if (token == 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599) {
            // WBTC
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else if (token == 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984) {
            // UNI
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else {
            revert("Unknown token");
        }

        // Check if whale has enough tokens
        uint256 whaleBalance = IERC20(token).balanceOf(whale);
        require(whaleBalance >= amount, "Whale doesn't have enough tokens");

        // Impersonate whale and transfer tokens
        vm.startPrank(whale);
        if (token == 0xdAC17F958D2ee523a2206206994597C13D831ec7) {
            // USDT transfer returns void, not bool
            TetherToken(token).transfer(user, amount);
        } else {
            IERC20(token).transfer(user, amount);
        }
        vm.stopPrank();
    }
}
