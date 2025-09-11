// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {IUniversalGateway} from "../../src/interfaces/IUniversalGateway.sol";
import {RevertSettings, UniversalPayload, TX_TYPE, VerificationType} from "../../src/libraries/Types.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockSequencerUptimeFeed} from "../mocks/MockSequencerUptimeFeed.sol";
/**
 * @title GatewayAdminSettersTest
 * @notice Comprehensive test suite for all admin and operational functions in UniversalGateway
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
        vm.expectRevert();
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
        vm.expectRevert();
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
        vm.expectRevert();
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
        vm.expectRevert();
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
        vm.expectRevert();
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
        vm.expectRevert();
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
    //      DEFAULT SWAP DEADLINE TESTS
    // =========================
    function testSetDefaultSwapDeadline() public {
        uint256 newDeadline = 30 minutes;
        vm.prank(admin);
        gateway.setDefaultSwapDeadline(newDeadline);
        assertEq(gateway.defaultSwapDeadlineSec(), newDeadline);
    }

    function testSetDefaultSwapDeadlineOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.setDefaultSwapDeadline(30 minutes);
    }

    function testSetDefaultSwapDeadlineZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.setDefaultSwapDeadline(0);
    }

    function testSetDefaultSwapDeadlineWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        vm.prank(admin);
        vm.expectRevert();
        gateway.setDefaultSwapDeadline(30 minutes);
    }

    // =========================
    //      V3 FEE ORDER TESTS
    // =========================
    function testSetV3FeeOrder() public {
        vm.prank(admin);
        gateway.setV3FeeOrder(10000, 3000, 500);
        assertEq(gateway.v3FeeOrder(0), 10000);
        assertEq(gateway.v3FeeOrder(1), 3000);
        assertEq(gateway.v3FeeOrder(2), 500);
    }

    function testSetV3FeeOrderOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.setV3FeeOrder(10000, 3000, 500);
    }

    function testSetV3FeeOrderWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        vm.prank(admin);
        vm.expectRevert();
        gateway.setV3FeeOrder(10000, 3000, 500);
    }

    // =========================
    //      CHAINLINK FEED TESTS
    // =========================
    function testSetEthUsdFeed() public {
        // Deploy a fresh mock with different decimals to ensure caching works
        MockAggregatorV3 newFeed = new MockAggregatorV3(8);
        newFeed.setAnswer(2_500e8, block.timestamp);

        vm.prank(admin);
        gateway.setEthUsdFeed(address(newFeed));

        assertEq(address(gateway.ethUsdFeed()), address(newFeed));
        assertEq(gateway.chainlinkEthUsdDecimals(), 8);
    }

    function testSetEthUsdFeedOnlyAdmin() public {
        MockAggregatorV3 newFeed = new MockAggregatorV3(8);
        vm.prank(user1);
        vm.expectRevert();
        gateway.setEthUsdFeed(address(newFeed));
    }

    function testSetEthUsdFeedZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setEthUsdFeed(address(0));
    }

    function testSetEthUsdFeedWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        MockAggregatorV3 newFeed = new MockAggregatorV3(8);
        vm.prank(admin);
        vm.expectRevert();
        gateway.setEthUsdFeed(address(newFeed));
    }

    function testSetChainlinkStalePeriod() public {
        vm.prank(admin);
        gateway.setChainlinkStalePeriod(2 hours);
        assertEq(gateway.chainlinkStalePeriod(), 2 hours);
    }

    function testSetChainlinkStalePeriodOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.setChainlinkStalePeriod(2 hours);
    }

    function testSetChainlinkStalePeriodWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        vm.prank(admin);
        vm.expectRevert();
        gateway.setChainlinkStalePeriod(2 hours);
    }

    function testSetL2SequencerFeed() public {
        MockSequencerUptimeFeed seq = new MockSequencerUptimeFeed();
        vm.prank(admin);
        gateway.setL2SequencerFeed(address(seq));
        assertEq(address(gateway.l2SequencerFeed()), address(seq));

        // Clear feed is allowed
        vm.prank(admin);
        gateway.setL2SequencerFeed(address(0));
        assertEq(address(gateway.l2SequencerFeed()), address(0));
    }

    function testSetL2SequencerFeedOnlyAdmin() public {
        MockSequencerUptimeFeed seq = new MockSequencerUptimeFeed();
        vm.prank(user1);
        vm.expectRevert();
        gateway.setL2SequencerFeed(address(seq));
    }

    function testSetL2SequencerFeedWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        MockSequencerUptimeFeed seq = new MockSequencerUptimeFeed();
        vm.prank(admin);
        vm.expectRevert();
        gateway.setL2SequencerFeed(address(seq));
    }

    function testSetL2SequencerGracePeriod() public {
        vm.prank(admin);
        gateway.setL2SequencerGracePeriod(300);
        assertEq(gateway.l2SequencerGracePeriodSec(), 300);
    }

    function testSetL2SequencerGracePeriodOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.setL2SequencerGracePeriod(300);
    }

    function testSetL2SequencerGracePeriodWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();
        vm.prank(admin);
        vm.expectRevert();
        gateway.setL2SequencerGracePeriod(300);
    }

    // =========================
    //      CAPS -> MIN/MAX NATIVE REFLECTION
    // =========================
    function testGetMinMaxValueReflectsNewCaps() public {
        // Price is seeded in BaseTest at $2000 with 8 decimals -> 2000e18 on getEthUsdPrice
        uint256 newMinCap = 2e18;  // $2
        uint256 newMaxCap = 20e18; // $20
        vm.prank(admin);
        gateway.setCapsUSD(newMinCap, newMaxCap);

        (uint256 minValue, uint256 maxValue) = gateway.getMinMaxValueForNative();
        // Expected: ETH = $2000 -> 1 ETH = 2000 USD
        // minValue = (2 * 1e18) / 2000 = 0.001 ETH = 1e15 wei
        // maxValue = (20 * 1e18) / 2000 = 0.01 ETH = 1e16 wei
        assertEq(minValue, 1e15);
        assertEq(maxValue, 1e16);
    }

    // =========================
    //      PAUSE GATING SANITY
    // =========================
    function testPauseBlocksAllStateChangingFunctions() public {
        // Pause first
        vm.prank(pauser);
        gateway.pause();

        // Admin setters should be blocked when paused
        vm.prank(admin);
        vm.expectRevert();
        gateway.setCapsUSD(2e18, 20e18);

        vm.prank(admin);
        vm.expectRevert();
        gateway.setRouters(address(0x1), address(0x2));

        vm.prank(admin);
        vm.expectRevert();
        gateway.setV3FeeOrder(500, 3000, 10000);

        vm.prank(admin);
        vm.expectRevert();
        gateway.setDefaultSwapDeadline(600);

        vm.prank(admin);
        vm.expectRevert();
        gateway.setChainlinkStalePeriod(3600);

        vm.prank(admin);
        vm.expectRevert();
        gateway.setL2SequencerFeed(address(0x1234));

        vm.prank(admin);
        vm.expectRevert();
        gateway.setL2SequencerGracePeriod(300);

        // TSS operations should be blocked
        vm.prank(tss);
        vm.expectRevert();
        gateway.withdrawFunds(user2, address(0), 1);
    }

}