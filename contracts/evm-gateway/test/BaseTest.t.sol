// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {UniversalGateway} from "../src/UniversalGateway.sol";
import {IUniversalGateway} from "../src/interfaces/IUniversalGateway.sol";
import {TX_TYPE, RevertSettings, UniversalPayload, VerificationType } from "../src/libraries/Types.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSequencerUptimeFeed} from "./mocks/MockSequencerUptimeFeed.sol";

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
    uint256 public constant MIN_CAP_USD = 1e18;  // $1 (1e18 = $1)
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
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            address(weth)
        );

        gatewayProxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );

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
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), MIN_CAP_USD);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), MAX_CAP_USD);
        assertEq(gateway.WETH(), address(weth));
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

    function revertCfg(address fundRecipient_) internal pure returns (RevertSettings memory) {
        return RevertSettings({
            fundRecipient: fundRecipient_,
            revertMsg: ""
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
        weth.deposit{value: amtWei}();
        weth.transfer(to, amtWei);
    }

    // =========================
    //      ADMIN CONFIG SETTERS (Gateway)
    // =========================

    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) internal {
        vm.prank(admin);
        gateway.setV3FeeOrder(a, b, c);
    }

    function setRouters(address factory, address router) internal {
        vm.prank(admin);
        gateway.setRouters(factory, router);
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
        gateway.modifySupportForToken(tokens, supportFlags);
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
    receive() external payable {}
}