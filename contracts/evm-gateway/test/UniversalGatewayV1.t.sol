// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {UniversalGatewayV1} from "../src/UniversalGatewayV1.sol";
import {IUniversalGateway} from "../src/interfaces/IUniversalGateway.sol";
import {RevertSettings, UniversalPayload, PoolCfg, TX_TYPE, VerificationType} from "../src/libraries/Types.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniversalGatewayV1Test is Test {
    address public admin;
    address public pauser;
    address public tss;
    address public user;

    ERC20Mock public mockToken;
    ERC20Mock public mockUSDC;
    ERC20Mock public mockWETH;

    UniversalGatewayV1 public gateway;
    UniversalGatewayV1 public implementation;
    ProxyAdmin public proxyAdmin;

    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;
    uint256 public constant MIN_CAP_USD = 1 ether;
    uint256 public constant MAX_CAP_USD = 10 ether;

    function setUp() public virtual {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        user = makeAddr("user");

        mockToken = new ERC20Mock();
        mockUSDC = new ERC20Mock();
        mockWETH = new ERC20Mock();

        implementation = new UniversalGatewayV1();
        proxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayV1.initialize.selector,
            admin,
            pauser,
            tss,
            MIN_CAP_USD,
            MAX_CAP_USD,
            address(0), // factory
            address(0), // router
            address(mockWETH) // _wethAddress
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );

        gateway = UniversalGatewayV1(payable(address(proxy)));

        mockToken.mint(user, INITIAL_BALANCE);
        mockUSDC.mint(user, INITIAL_BALANCE);
        mockWETH.mint(user, INITIAL_BALANCE);
    }

    // =========================
    //      INITIALIZATION TESTS
    // =========================

    function testInitialization() public {
        assertEq(gateway.tssAddress(), tss);
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), MIN_CAP_USD);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), MAX_CAP_USD);
        assertEq(gateway.WETH(), address(mockWETH));
        assertTrue(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gateway.hasRole(gateway.PAUSER_ROLE(), pauser));
        assertTrue(gateway.hasRole(gateway.TSS_ROLE(), tss));
        assertFalse(gateway.paused());
    }

    // =========================
    //      SETTER FUNCTION TESTS
    // =========================

    function testSetTSSAddress() public {
        address newTSS = makeAddr("newTSS");

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.TSSAddressUpdated(tss, newTSS);

        vm.prank(admin);
        gateway.setTSSAddress(newTSS);

        assertEq(gateway.tssAddress(), newTSS);
        assertTrue(gateway.hasRole(gateway.TSS_ROLE(), newTSS));
        assertFalse(gateway.hasRole(gateway.TSS_ROLE(), tss));
    }

    function testSetTSSAddressOnlyAdmin() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(user);
        vm.expectRevert();
        gateway.setTSSAddress(newTSS);

        vm.prank(pauser);
        vm.expectRevert();
        gateway.setTSSAddress(newTSS);

        vm.prank(tss);
        vm.expectRevert();
        gateway.setTSSAddress(newTSS);
    }

    function testSetTSSAddressZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setTSSAddress(address(0));
    }

    function testSetCapsUSD() public {
        uint256 newMinCap = 2 ether;
        uint256 newMaxCap = 20 ether;

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.CapsUpdated(newMinCap, newMaxCap);

        vm.prank(admin);
        gateway.setCapsUSD(newMinCap, newMaxCap);

        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), newMinCap);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), newMaxCap);
    }

    function testSetCapsUSDOnlyAdmin() public {
        uint256 newMinCap = 2 ether;
        uint256 newMaxCap = 20 ether;

        vm.prank(user);
        vm.expectRevert();
        gateway.setCapsUSD(newMinCap, newMaxCap);

        vm.prank(pauser);
        vm.expectRevert();
        gateway.setCapsUSD(newMinCap, newMaxCap);

        vm.prank(tss);
        vm.expectRevert();
        gateway.setCapsUSD(newMinCap, newMaxCap);
    }

    function testSetCapsUSDInvalidRange() public {
        uint256 newMinCap = 20 ether;
        uint256 newMaxCap = 10 ether;

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidCapRange.selector);
        gateway.setCapsUSD(newMinCap, newMaxCap);
    }

    function testSetRouters() public {
        address newFactory = address(0xA);
        address newRouter = address(0xB);

        vm.prank(admin);
        gateway.setRouters(newFactory, newRouter);

        assertEq(address(gateway.uniV3Factory()), newFactory);
        assertEq(address(gateway.uniV3Router()), newRouter);
    }

    function testSetRoutersOnlyAdmin() public {
        address newFactory = address(0xA);
        address newRouter = address(0xB);

        vm.prank(user);
        vm.expectRevert();
        gateway.setRouters(newFactory, newRouter);
    }

    function testSetRoutersZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setRouters(address(0), address(0xB));

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setRouters(address(0xA), address(0));
    }

    function testModifySupportForToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(mockToken);
        tokens[1] = address(mockUSDC);

        bool[] memory isSupported = new bool[](2);
        isSupported[0] = true;
        isSupported[1] = false;

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.TokenSupportModified(address(mockToken), true);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.TokenSupportModified(address(mockUSDC), false);

        vm.prank(admin);
        gateway.modifySupportForToken(tokens, isSupported);

        assertTrue(gateway.isSupportedToken(address(mockToken)));
        assertFalse(gateway.isSupportedToken(address(mockUSDC)));
    }

    function testModifySupportForTokenOnlyAdmin() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockToken);

        bool[] memory isSupported = new bool[](1);
        isSupported[0] = true;

        vm.prank(user);
        vm.expectRevert();
        gateway.modifySupportForToken(tokens, isSupported);
    }

    function testModifySupportForTokenInvalidInput() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(mockToken);
        tokens[1] = address(mockUSDC);

        bool[] memory isSupported = new bool[](1);
        isSupported[0] = true;

        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.modifySupportForToken(tokens, isSupported);
    }

    function testSetV3FeeOrder() public {
        uint24 fee1 = 500;
        uint24 fee2 = 1000;
        uint24 fee3 = 3000;

        vm.prank(admin);
        gateway.setV3FeeOrder(fee1, fee2, fee3);

        assertEq(gateway.v3FeeOrder(0), fee1);
        assertEq(gateway.v3FeeOrder(1), fee2);
        assertEq(gateway.v3FeeOrder(2), fee3);
    }

    function testSetV3FeeOrderOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setV3FeeOrder(500, 1000, 3000);
    }

    function testSetTwapWindow() public {
        uint32 newWindow = 3600; // 1 hour

        vm.prank(admin);
        gateway.setTwapWindow(newWindow);

        assertEq(gateway.twapWindowSec(), newWindow);
    }

    function testSetTwapWindowOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setTwapWindow(3600);
    }

    function testSetTwapWindowTooShort() public {
        vm.prank(admin);
        vm.expectRevert(Errors.TwapWindowTooShort.selector);
        gateway.setTwapWindow(299); // Less than 300 seconds
    }

    function testSetMinObsCardinality() public {
        uint16 newCardinality = 32;

        vm.prank(admin);
        gateway.setMinObsCardinality(newCardinality);

        assertEq(gateway.minObsCardinality(), newCardinality);
    }

    function testSetMinObsCardinalityOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setMinObsCardinality(32);
    }

    function testSetPoolConfig() public {
        address pool = makeAddr("pool");
        address usdc = makeAddr("usdc");
        uint8 decimals = 6;

        vm.prank(admin);
        gateway.setPoolConfig(pool, usdc, decimals);

        (IUniswapV3Pool poolContract, address stableToken, uint8 stableTokenDecimals, bool enabled) = gateway.poolUSDC();
        assertEq(address(poolContract), pool);
        assertEq(stableToken, usdc);
        assertEq(stableTokenDecimals, decimals);
        assertTrue(enabled);
    }

    function testSetPoolConfigOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setPoolConfig(makeAddr("pool"), makeAddr("usdc"), 6);
    }

    function testSetPoolConfigZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPoolConfig(address(0), makeAddr("usdc"), 6);

        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPoolConfig(makeAddr("pool"), address(0), 6);
    }

    function testSetPoolEnabled() public {
        vm.prank(admin);
        gateway.setPoolEnabled(false);

        (,,, bool enabled) = gateway.poolUSDC();
        assertFalse(enabled);

        vm.prank(admin);
        gateway.setPoolEnabled(true);

        (,,, enabled) = gateway.poolUSDC();
        assertTrue(enabled);
    }

    function testSetPoolEnabledOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.setPoolEnabled(false);
    }

    // =========================
    //      PAUSE/UNPAUSE TESTS
    // =========================

    function testPauseUnpause() public {
        assertFalse(gateway.paused());

        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        vm.prank(pauser);
        gateway.unpause();
        assertFalse(gateway.paused());
    }

    function testPauseOnlyPauser() public {
        vm.prank(admin);
        vm.expectRevert();
        gateway.pause();

        vm.prank(user);
        vm.expectRevert();
        gateway.pause();
    }

    function testUnpauseOnlyPauser() public {
        vm.prank(pauser);
        gateway.pause();

        vm.prank(admin);
        vm.expectRevert();
        gateway.unpause();

        vm.prank(user);
        vm.expectRevert();
        gateway.unpause();
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    function createRevertSettings(address recipient) internal pure returns (RevertSettings memory) {
        return RevertSettings({
            fundRecipient: recipient,
            revertMsg: "Test revert message"
        });
    }

    function createUniversalPayload() internal view returns (UniversalPayload memory) {
        return UniversalPayload({
            to: address(0x123),
            value: 1 ether,
            data: abi.encodeWithSignature("test()"),
            gasLimit: 100000,
            maxFeePerGas: 20 gwei,
            maxPriorityFeePerGas: 2 gwei,
            nonce: 1,
            deadline: block.timestamp + 3600,
            vType: VerificationType.signedVerification
        });
    }
}
