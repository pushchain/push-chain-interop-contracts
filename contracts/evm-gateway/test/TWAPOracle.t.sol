// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

// Adjust the path to where your contract actually lives
import {UniversalGatewayV1} from "../src/UniversalGatewayV1.sol";

// Uniswap V3 pool interface for optional sanity (not required, but handy)
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniversalGatewayV1_PriceFork_Test is Test {
    // === Mainnet constants ===
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // WETH/USDC 0.05%

    UniversalGatewayV1 ug;

    // dummy addresses for roles
    address admin = address(0xA11CE);
    address pauser = address(0xB11B0);
    address tss = address(0xC11C0);

    function setUp() public {
        string memory rpc = vm.envString("ETH_MAINNET_RPC_URL");
        vm.createSelectFork(rpc);

        // 2) Deploy implementation directly (no proxy) and call initialize.
        //    We don't need V2 factory/router for this test, pass address(0) for both.
        ug = new UniversalGatewayV1();
        ug.initialize({
            admin: admin,
            pauser: pauser,
            tss: tss,
            minCapUsd: 0,
            maxCapUsd: type(uint256).max,
            factory: address(0),
            router: address(0),
            _wethAddress: WETH
        });
    }

    function test_PrintEthUsdPrice1e18() public {
        // Read ETH/USD @ 1e18 from Uniswap V3 TWAP
        uint256 px = ug.ethUsdPrice1e18();

        console2.log("ETH/USD (1e18):", px);
        // Sanity band: $3900 .. $4900
        assertGt(px, 3900e18);
        assertLt(px, 4900e18);
    }

    function test_Quote_PointOneEth_InUsd1e18() public {
        uint256 usd = ug.quoteEthAmountInUsd1e18(0.1 ether);
        console2.log("USD value of 0.1 ETH (1e18):", usd);
    }
}
