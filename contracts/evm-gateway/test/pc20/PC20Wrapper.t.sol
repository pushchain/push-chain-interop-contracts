// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";

contract PC20WrapperTest is Test {
    PC20Wrapper public wrapper;

    address public factoryAddr;
    address public sourceAsset;
    address public userA;
    address public userB;
    address public newFactory;
    address public thirdFactory;

    function setUp() public {
        factoryAddr = makeAddr("factory");
        sourceAsset = makeAddr("sourceAsset");
        userA = makeAddr("userA");
        userB = makeAddr("userB");
        newFactory = makeAddr("newFactory");
        thirdFactory = makeAddr("thirdFactory");

        wrapper = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.prank(factoryAddr);
        wrapper.initialize("Push Token", "pTKN", 18);
    }

    // =========================================================
    //  11.1 Constructor
    // =========================================================

    function test_Constructor_NameSymbolDecimalsSet() public view {
        assertEq(wrapper.name(), "Push Token");
        assertEq(wrapper.symbol(), "pTKN");
        assertEq(wrapper.decimals(), 18);
    }

    function test_Constructor_Decimals6() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.prank(factoryAddr);
        w.initialize("Push USDC", "pUSDC", 6);
        assertEq(w.decimals(), 6);
    }

    function test_Constructor_Decimals0() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.prank(factoryAddr);
        w.initialize("Push NFT", "pNFT", 0);
        assertEq(w.decimals(), 0);
    }

    function test_Constructor_SourceAssetImmutable() public view {
        assertEq(wrapper.SOURCE_ASSET(), sourceAsset);
    }

    function test_Constructor_FactorySetCorrectly() public view {
        assertEq(wrapper.factory(), factoryAddr);
    }

    function test_Constructor_PendingFactoryStartsZero() public view {
        assertEq(wrapper.pendingFactory(), address(0));
    }

    function test_Constructor_TotalSupplyStartsZero() public view {
        assertEq(wrapper.totalSupply(), 0);
    }

    function test_Constructor_RevertsOnZeroSourceAsset() public {
        vm.expectRevert(PC20Wrapper.ZeroAddress.selector);
        new PC20Wrapper(address(0), factoryAddr);
    }

    function test_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert(PC20Wrapper.ZeroAddress.selector);
        new PC20Wrapper(sourceAsset, address(0));
    }

    // =========================================================
    //  11.1b initialize
    // =========================================================

    function test_Initialize_SetsMetadata() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.prank(factoryAddr);
        w.initialize("Test Token", "TST", 8);
        assertEq(w.name(), "Test Token");
        assertEq(w.symbol(), "TST");
        assertEq(w.decimals(), 8);
    }

    function test_Initialize_DefaultsBeforeInit() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        assertEq(w.name(), "");
        assertEq(w.symbol(), "");
        assertEq(w.decimals(), 0);
    }

    function test_Initialize_RevertsIfCalledTwice() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.startPrank(factoryAddr);
        w.initialize("A", "B", 18);
        vm.expectRevert(PC20Wrapper.AlreadyInitialized.selector);
        w.initialize("C", "D", 6);
        vm.stopPrank();
    }

    function test_Initialize_RevertsFromNonFactory() public {
        PC20Wrapper w = new PC20Wrapper(sourceAsset, factoryAddr);
        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        w.initialize("A", "B", 18);
    }

    // =========================================================
    //  11.2 mint — Happy Path
    // =========================================================

    function test_Mint_FactoryMintsToUser() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 1000e18);
        assertEq(wrapper.balanceOf(userA), 1000e18);
        assertEq(wrapper.totalSupply(), 1000e18);
    }

    function test_Mint_MultipleMintsAccumulate() public {
        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 100e18);
        wrapper.mint(userA, 200e18);
        wrapper.mint(userA, 300e18);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(userA), 600e18);
        assertEq(wrapper.totalSupply(), 600e18);
    }

    function test_Mint_DifferentUsers() public {
        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 100e18);
        wrapper.mint(userB, 200e18);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(userA), 100e18);
        assertEq(wrapper.balanceOf(userB), 200e18);
        assertEq(wrapper.totalSupply(), 300e18);
    }

    function test_Mint_EmitsTransferEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), userA, 500e18);
        vm.prank(factoryAddr);
        wrapper.mint(userA, 500e18);
    }

    function test_Mint_ZeroAmount() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), userA, 0);
        vm.prank(factoryAddr);
        wrapper.mint(userA, 0);
        assertEq(wrapper.balanceOf(userA), 0);
    }

    // =========================================================
    //  11.3 mint — Reverts
    // =========================================================

    function test_Mint_RevertsFromNonFactory() public {
        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.mint(userA, 100e18);
    }

    function test_Mint_RevertsFromPendingFactory() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);

        vm.prank(newFactory);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.mint(userA, 100e18);
    }

    function test_Mint_RevertsToAddressZero() public {
        vm.prank(factoryAddr);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InvalidReceiver(address)",
                address(0)
            )
        );
        wrapper.mint(address(0), 100e18);
    }

    // =========================================================
    //  11.4 burn — Happy Path
    // =========================================================

    function test_Burn_FactoryBurnsFromUser() public {
        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 1000e18);
        wrapper.burn(userA, 400e18);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(userA), 600e18);
        assertEq(wrapper.totalSupply(), 600e18);
    }

    function test_Burn_AllTokens() public {
        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 1000e18);
        wrapper.burn(userA, 1000e18);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(userA), 0);
        assertEq(wrapper.totalSupply(), 0);
    }

    function test_Burn_EmitsTransferEvent() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 1000e18);

        vm.expectEmit(true, true, false, true);
        emit Transfer(userA, address(0), 300e18);
        vm.prank(factoryAddr);
        wrapper.burn(userA, 300e18);
    }

    function test_Burn_ZeroAmount() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 100e18);

        vm.prank(factoryAddr);
        wrapper.burn(userA, 0);
        assertEq(wrapper.balanceOf(userA), 100e18);
    }

    // =========================================================
    //  11.5 burn — Reverts
    // =========================================================

    function test_Burn_RevertsFromNonFactory() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 100e18);

        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.burn(userA, 50e18);
    }

    function test_Burn_RevertsExceedsBalance() public {
        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 100e18);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                userA,
                100e18,
                200e18
            )
        );
        wrapper.burn(userA, 200e18);
        vm.stopPrank();
    }

    function test_Burn_RevertsFromZeroBalanceAddress() public {
        vm.prank(factoryAddr);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                userA,
                0,
                1
            )
        );
        wrapper.burn(userA, 1);
    }

    // =========================================================
    //  11.6 transferFactory — Happy Path
    // =========================================================

    function test_TransferFactory_StagesNewFactory() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        assertEq(wrapper.pendingFactory(), newFactory);
    }

    function test_TransferFactory_OverwritesPrevious() public {
        vm.startPrank(factoryAddr);
        wrapper.transferFactory(newFactory);
        wrapper.transferFactory(thirdFactory);
        vm.stopPrank();
        assertEq(wrapper.pendingFactory(), thirdFactory);
    }

    function test_TransferFactory_ZeroCancelsPending() public {
        vm.startPrank(factoryAddr);
        wrapper.transferFactory(newFactory);
        wrapper.transferFactory(address(0));
        vm.stopPrank();
        assertEq(wrapper.pendingFactory(), address(0));
    }

    function test_TransferFactory_DoesNotChangeFactory() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        assertEq(wrapper.factory(), factoryAddr);
    }

    // =========================================================
    //  11.7 transferFactory — Reverts
    // =========================================================

    function test_TransferFactory_RevertsFromNonFactory() public {
        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.transferFactory(newFactory);
    }

    function test_TransferFactory_RevertsFromPendingFactory() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);

        vm.prank(newFactory);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.transferFactory(thirdFactory);
    }

    // =========================================================
    //  11.8 acceptFactory — Happy Path
    // =========================================================

    function test_AcceptFactory_PendingAccepts() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);

        vm.prank(newFactory);
        wrapper.acceptFactory();

        assertEq(wrapper.factory(), newFactory);
        assertEq(wrapper.pendingFactory(), address(0));
    }

    function test_AcceptFactory_NewFactoryCanMint() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(newFactory);
        wrapper.mint(userA, 100e18);
        assertEq(wrapper.balanceOf(userA), 100e18);
    }

    function test_AcceptFactory_NewFactoryCanBurn() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 500e18);

        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(newFactory);
        wrapper.burn(userA, 200e18);
        assertEq(wrapper.balanceOf(userA), 300e18);
    }

    function test_AcceptFactory_OldFactoryCannotMint() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(factoryAddr);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.mint(userA, 100e18);
    }

    function test_AcceptFactory_OldFactoryCannotBurn() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 500e18);
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(factoryAddr);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.burn(userA, 100e18);
    }

    function test_AcceptFactory_OldFactoryCannotTransfer() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(factoryAddr);
        vm.expectRevert(PC20Wrapper.OnlyFactory.selector);
        wrapper.transferFactory(thirdFactory);
    }

    function test_AcceptFactory_NewFactoryCanStageAnother() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);
        vm.prank(newFactory);
        wrapper.acceptFactory();

        vm.prank(newFactory);
        wrapper.transferFactory(thirdFactory);
        assertEq(wrapper.pendingFactory(), thirdFactory);
    }

    // =========================================================
    //  11.9 acceptFactory — Reverts
    // =========================================================

    function test_AcceptFactory_RevertsFromNonPending() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);

        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyPendingFactory.selector);
        wrapper.acceptFactory();
    }

    function test_AcceptFactory_RevertsFromCurrentFactory() public {
        vm.prank(factoryAddr);
        wrapper.transferFactory(newFactory);

        vm.prank(factoryAddr);
        vm.expectRevert(PC20Wrapper.OnlyPendingFactory.selector);
        wrapper.acceptFactory();
    }

    function test_AcceptFactory_RevertsWhenNoPending() public {
        vm.prank(userA);
        vm.expectRevert(PC20Wrapper.OnlyPendingFactory.selector);
        wrapper.acceptFactory();
    }

    // =========================================================
    //  11.10 Standard ERC-20 Operations
    // =========================================================

    function test_ERC20_Transfer() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 1000e18);

        vm.prank(userA);
        wrapper.transfer(userB, 300e18);
        assertEq(wrapper.balanceOf(userA), 700e18);
        assertEq(wrapper.balanceOf(userB), 300e18);
    }

    function test_ERC20_ApproveAndTransferFrom() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 1000e18);

        vm.prank(userA);
        wrapper.approve(userB, 500e18);
        assertEq(wrapper.allowance(userA, userB), 500e18);

        vm.prank(userB);
        wrapper.transferFrom(userA, userB, 400e18);
        assertEq(wrapper.balanceOf(userA), 600e18);
        assertEq(wrapper.balanceOf(userB), 400e18);
        assertEq(wrapper.allowance(userA, userB), 100e18);
    }

    function test_ERC20_TransferToAddressZeroReverts() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 100e18);

        vm.prank(userA);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InvalidReceiver(address)",
                address(0)
            )
        );
        wrapper.transfer(address(0), 50e18);
    }

    function test_ERC20_TransferFromExceedingAllowanceReverts() public {
        vm.prank(factoryAddr);
        wrapper.mint(userA, 1000e18);

        vm.prank(userA);
        wrapper.approve(userB, 100e18);

        vm.prank(userB);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                userB,
                100e18,
                200e18
            )
        );
        wrapper.transferFrom(userA, userB, 200e18);
    }

    // =========================================================
    //  11.11 Integration Semantics
    // =========================================================

    function test_MultipleWrappersIndependent() public {
        address source2 = makeAddr("sourceAsset2");
        PC20Wrapper wrapper2 = new PC20Wrapper(source2, factoryAddr);
        vm.prank(factoryAddr);
        wrapper2.initialize("Push USDC", "pUSDC", 6);

        vm.startPrank(factoryAddr);
        wrapper.mint(userA, 1000e18);
        wrapper2.mint(userA, 500e6);
        wrapper.burn(userA, 200e18);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(userA), 800e18);
        assertEq(wrapper2.balanceOf(userA), 500e6);
        assertEq(wrapper.totalSupply(), 800e18);
        assertEq(wrapper2.totalSupply(), 500e6);
    }

    // =========================================================
    //  OZ ERC-20 Transfer event declaration (needed for expectEmit)
    // =========================================================

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );
}
