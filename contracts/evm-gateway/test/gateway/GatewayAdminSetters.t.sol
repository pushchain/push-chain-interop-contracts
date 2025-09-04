// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IUniversalGateway} from "../../src/interfaces/IUniversalGateway.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title GatewayAdminSettersTest
 * @notice Comprehensive test suite for all admin and operational functions in UniversalGatewayV1
 * @dev Tests all admin setters, role-based access control, pause functionality, and operational functions
 */
contract GatewayAdminSettersTest is BaseTest {


    // =========================
    //      SETUP
    // =========================
    function setUp() public override {
        super.setUp();
    }
    function testPauseOnlyPauser() public {
        // Non-pauser should not be able to pause
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.PAUSER_ROLE()
            )
        );
        gateway.pause();
        
        // Pauser should be able to pause
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());
    }

    function testUnpauseOnlyPauser() public {
        // First pause the contract
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        // Non-pauser should not be able to unpause
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.PAUSER_ROLE()
            )
        );
        gateway.unpause();

        // Pauser should be able to unpause
        vm.prank(pauser);
        gateway.unpause();
        assertFalse(gateway.paused());
    }

    function testPauseUnpause() public {
        assertFalse(gateway.paused());

        // Pause
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        // Unpause
        vm.prank(pauser);
        gateway.unpause();
        assertFalse(gateway.paused());
    }

    // =========================
    //      TSS ADDRESS TESTS //Note: COULD Change based on ESDCA vs BLS sign schemes.
    // =========================

    function testSetTSSAddress() public {
        address newTSS = address(0x123);
        
        vm.prank(admin);
        gateway.setTSSAddress(newTSS);
        
        assertEq(gateway.tssAddress(), newTSS);
        assertTrue(gateway.hasRole(gateway.TSS_ROLE(), newTSS));
        assertFalse(gateway.hasRole(gateway.TSS_ROLE(), tss));
    }

    function testSetTSSAddressOnlyAdmin() public {
        address newTSS = address(0x123);
        
        // Non-admin should not be able to set TSS
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setTSSAddress(newTSS);
        
        // Admin should be able to set TSS
        vm.prank(admin);
        gateway.setTSSAddress(newTSS);
        assertEq(gateway.tssAddress(), newTSS);
    }

    function testSetTSSAddressZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setTSSAddress(address(0));
    }

    function testSetTSSAddressWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set TSS when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setTSSAddress(address(0x123));
    }

    function testSetCapsUSD() public {
        uint256 newMinCap = 2e18; // 2 USD
        uint256 newMaxCap = 20e18; // 20 USD
        
        vm.prank(admin);
        gateway.setCapsUSD(newMinCap, newMaxCap);
        
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), newMinCap);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), newMaxCap);
    }

    function testSetCapsUSDOnlyAdmin() public {
        uint256 newMinCap = 2e18;
        uint256 newMaxCap = 20e18;
        
        // Non-admin should not be able to set caps
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setCapsUSD(newMinCap, newMaxCap);
        
        // Admin should be able to set caps
        vm.prank(admin);
        gateway.setCapsUSD(newMinCap, newMaxCap);
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), newMinCap);
    }

    function testSetCapsUSDInvalidRange() public {
        uint256 minCap = 20e18;
        uint256 maxCap = 2e18; // max < min
        
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidCapRange.selector);
        gateway.setCapsUSD(minCap, maxCap);
    }

    function testSetCapsUSDWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set caps when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setCapsUSD(2e18, 20e18);
    }

    // =========================
    //      ROUTERS TESTS
    // =========================

    function testSetRouters() public {
        address newFactory = address(0x456);
        address newRouter = address(0x789);
        
        vm.prank(admin);
        gateway.setRouters(newFactory, newRouter);
        
        assertEq(address(gateway.uniV3Factory()), newFactory);
        assertEq(address(gateway.uniV3Router()), newRouter);
    }

    function testSetRoutersOnlyAdmin() public {
        address newFactory = address(0x456);
        address newRouter = address(0x789);
        
        // Non-admin should not be able to set routers
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setRouters(newFactory, newRouter);
        
        // Admin should be able to set routers
        vm.prank(admin);
        gateway.setRouters(newFactory, newRouter);
        assertEq(address(gateway.uniV3Factory()), newFactory);
    }

    function testSetRoutersZeroAddress() public {
        // Zero factory
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setRouters(address(0), address(0x789));
        
        // Zero router
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setRouters(address(0x456), address(0));
    }

    function testSetRoutersWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set routers when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setRouters(address(0x456), address(0x789));
    }

    // =========================
    //      TOKEN SUPPORT TESTS
    // =========================

    function testModifySupportForToken() public {
        address[] memory tokens = new address[](2);
        bool[] memory supportFlags = new bool[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(usdc);
        supportFlags[0] = true;
        supportFlags[1] = false;
        
        vm.prank(admin);
        gateway.modifySupportForToken(tokens, supportFlags);
        
        assertTrue(gateway.isSupportedToken(address(tokenA)));
        assertFalse(gateway.isSupportedToken(address(usdc)));
    }

    function testModifySupportForTokenOnlyAdmin() public {
        address[] memory tokens = new address[](1);
        bool[] memory supportFlags = new bool[](1);
        tokens[0] = address(tokenA);
        supportFlags[0] = true;
        
        // Non-admin should not be able to modify support
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.modifySupportForToken(tokens, supportFlags);
        
        // Admin should be able to modify support
        vm.prank(admin);
        gateway.modifySupportForToken(tokens, supportFlags);
        assertTrue(gateway.isSupportedToken(address(tokenA)));
    }

    function testModifySupportForTokenInvalidInput() public {
        address[] memory tokens = new address[](2);
        bool[] memory supportFlags = new bool[](1); // Length mismatch
        
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.modifySupportForToken(tokens, supportFlags);
    }

    function testModifySupportForTokenWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        address[] memory tokens = new address[](1);
        bool[] memory supportFlags = new bool[](1);
        tokens[0] = address(tokenA);
        supportFlags[0] = true;
        
        // Should not be able to modify support when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.modifySupportForToken(tokens, supportFlags);
    }

    // =========================
    //      POOL CONFIG TESTS
    // =========================

    function testSetPoolConfig() public {
        address pool = address(0xABC);
        address usdcToken = address(usdc);
        uint8 usdcDecimals = 6;
        
        vm.prank(admin);
        gateway.setPoolConfig(pool, usdcToken, usdcDecimals);
        
        // Check pool config was set correctly
        (IUniswapV3Pool poolContract, address stableToken, uint8 decimals, bool enabled) = gateway.poolUSDC();
        assertEq(address(poolContract), pool);
        assertEq(stableToken, usdcToken);
        assertEq(decimals, usdcDecimals);
        assertTrue(enabled); // Should be enabled by default
    }

    function testSetPoolConfigOnlyAdmin() public {
        address pool = address(0xABC);
        address usdcToken = address(usdc);
        uint8 usdcDecimals = 6;
        
        // Non-admin should not be able to set pool config
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setPoolConfig(pool, usdcToken, usdcDecimals);
        
        // Admin should be able to set pool config
        vm.prank(admin);
        gateway.setPoolConfig(pool, usdcToken, usdcDecimals);
        
        (IUniswapV3Pool poolContract, , , ) = gateway.poolUSDC();
        assertEq(address(poolContract), pool);
    }

    function testSetPoolConfigZeroAddress() public {
        address pool = address(0xABC);
        address usdcToken = address(usdc);
        uint8 usdcDecimals = 6;
        
        // Zero pool address
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPoolConfig(address(0), usdcToken, usdcDecimals);
        
        // Zero USDC address
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPoolConfig(pool, address(0), usdcDecimals);
    }

    function testSetPoolConfigWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set pool config when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setPoolConfig(address(0xABC), address(usdc), 6);
    }

    // =========================
    //      TWAP WINDOW and AMM SETTING TESTS
    // =========================

    function testSetTwapWindow() public {
        uint32 newWindow = 3600; // 1 hour
        
        vm.prank(admin);
        gateway.setTwapWindow(newWindow);
        
        assertEq(gateway.twapWindowSec(), newWindow);
    }

    function testSetTwapWindowOnlyAdmin() public {
        uint32 newWindow = 3600;
        
        // Non-admin should not be able to set TWAP window
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setTwapWindow(newWindow);
        
        // Admin should be able to set TWAP window
        vm.prank(admin);
        gateway.setTwapWindow(newWindow);
        assertEq(gateway.twapWindowSec(), newWindow);
    }

    function testSetTwapWindowTooShort() public {
        uint32 shortWindow = 299; // Less than 300 seconds
        
        vm.prank(admin);
        vm.expectRevert(Errors.TwapWindowTooShort.selector);
        gateway.setTwapWindow(shortWindow);
    }

    function testSetTwapWindowWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set TWAP window when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setTwapWindow(3600);
    }

    function testSetMinObsCardinality() public {
        uint16 newCardinality = 32;
        
        vm.prank(admin);
        gateway.setMinObsCardinality(newCardinality);
        
        assertEq(gateway.minObsCardinality(), newCardinality);
    }

    function testSetMinObsCardinalityOnlyAdmin() public {
        uint16 newCardinality = 32;
        
        // Non-admin should not be able to set cardinality
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setMinObsCardinality(newCardinality);
        
        // Admin should be able to set cardinality
        vm.prank(admin);
        gateway.setMinObsCardinality(newCardinality);
        assertEq(gateway.minObsCardinality(), newCardinality);
    }

    function testSetMinObsCardinalityZero() public {
        // Zero should be allowed (disables check)
        vm.prank(admin);
        gateway.setMinObsCardinality(0);
        
        assertEq(gateway.minObsCardinality(), 0);
    }

    function testSetMinObsCardinalityWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to set cardinality when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setMinObsCardinality(32);
    }

    function testSetPoolEnabled() public {
        // First set up a pool config
        vm.prank(admin);
        gateway.setPoolConfig(address(0xABC), address(usdc), 6);
        
        // Disable pool
        vm.prank(admin);
        gateway.setPoolEnabled(false);
        
        (IUniswapV3Pool poolContract, address stableToken, uint8 decimals, bool enabled) = gateway.poolUSDC();
        assertFalse(enabled);
        
        // Enable pool
        vm.prank(admin);
        gateway.setPoolEnabled(true);
        
        (, , , enabled) = gateway.poolUSDC();
        assertTrue(enabled);
    }

    function testSetPoolEnabledOnlyAdmin() public {
        // Non-admin should not be able to enable/disable pool
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496),
                gateway.DEFAULT_ADMIN_ROLE()
            )
        );
        gateway.setPoolEnabled(false);
        
        // Admin should be able to enable/disable pool
        vm.prank(admin);
        gateway.setPoolEnabled(false);
        
        (, , , bool enabled) = gateway.poolUSDC();
        assertFalse(enabled);
    }

    function testSetPoolEnabledWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Should not be able to enable/disable pool when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setPoolEnabled(false);
    }

    // =========================
    //      Additional Config Tests
    // =========================

    function testMultipleTokenSupportModification() public {
        address[] memory tokens = new address[](3);
        bool[] memory supportFlags = new bool[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(usdc);
        tokens[2] = address(weth);
        supportFlags[0] = true;
        supportFlags[1] = false;
        supportFlags[2] = true;
        
        vm.prank(admin);
        gateway.modifySupportForToken(tokens, supportFlags);
        
        assertTrue(gateway.isSupportedToken(address(tokenA)));
        assertFalse(gateway.isSupportedToken(address(usdc)));
        assertTrue(gateway.isSupportedToken(address(weth)));
    }

    function testCapRangeBoundaryValues() public {
        // Test equal min and max caps (boundary case)
        uint256 cap = 5e18;
        
        vm.prank(admin);
        gateway.setCapsUSD(cap, cap);
        
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), cap);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), cap);
    }

    function testV3FeeOrderBoundaryValues() public {
        // Test with zero fees (boundary case)
        vm.prank(admin);
        gateway.setV3FeeOrder(0, 0, 0);
        
        assertEq(gateway.v3FeeOrder(0), 0);
        assertEq(gateway.v3FeeOrder(1), 0);
        assertEq(gateway.v3FeeOrder(2), 0);
    }

    function testTwapWindowBoundaryValues() public {
        // Test minimum allowed window (300 seconds)
        vm.prank(admin);
        gateway.setTwapWindow(300);
        assertEq(gateway.twapWindowSec(), 300);
        
        // Test large window
        vm.prank(admin);
        gateway.setTwapWindow(86400); // 24 hours
        assertEq(gateway.twapWindowSec(), 86400);
    }

    function testMinObsCardinalityBoundaryValues() public {
        // Test zero cardinality (disables check)
        vm.prank(admin);
        gateway.setMinObsCardinality(0);
        assertEq(gateway.minObsCardinality(), 0);
        
        // Test large cardinality
        vm.prank(admin);
        gateway.setMinObsCardinality(65535); // Max uint16
        assertEq(gateway.minObsCardinality(), 65535);
    }

    // =========================
    //      INITIALIZATION VERIFICATION
    // =========================

    function testInitialState() public {
        // Verify initial state after setup
        assertEq(gateway.tssAddress(), tss);
        assertEq(gateway.MIN_CAP_UNIVERSAL_TX_USD(), MIN_CAP_USD);
        assertEq(gateway.MAX_CAP_UNIVERSAL_TX_USD(), MAX_CAP_USD);
        assertEq(gateway.WETH(), address(weth));
        assertEq(gateway.twapWindowSec(), 1800);
        assertEq(gateway.minObsCardinality(), 16);
        assertFalse(gateway.paused());
        
        // Verify roles
        assertTrue(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gateway.hasRole(gateway.PAUSER_ROLE(), pauser));
        assertTrue(gateway.hasRole(gateway.TSS_ROLE(), tss));
    }
}