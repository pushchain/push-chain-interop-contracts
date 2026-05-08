// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.t.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {PC20Factory} from "../../src/PC20Factory.sol";
import {PC20Wrapper} from "../../src/PC20Wrapper.sol";
import {IPC20Factory} from "../../src/interfaces/IPC20Factory.sol";
import {IUniversalGateway} from "../../src/interfaces/IUniversalGateway.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {PC20BurnRequest} from "../../src/libraries/TypesUG.sol";
import {Vault} from "../../src/Vault.sol";
import {ERC1967Proxy} from
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockCEAFactory} from "../mocks/MockCEAFactory.sol";

contract SendPC20UniversalTxTest is BaseTest {
    PC20Factory public pc20Factory;
    address public sourceAsset;
    PC20Wrapper public wrapper;
    Vault public vaultContract;
    MockCEAFactory public ceaFactory;

    function setUp() public override {
        super.setUp();

        sourceAsset = makeAddr("sourceAsset");

        // Deploy CEAFactory mock
        ceaFactory = new MockCEAFactory();

        // Deploy Vault (needed for PC20Factory VAULT_ROLE)
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                Vault.initialize,
                (
                    admin, pauser, tss,
                    address(gateway),
                    address(ceaFactory)
                )
            )
        );
        vaultContract = Vault(payable(address(vaultProxy)));
        ceaFactory.setVault(address(vaultContract));

        // Deploy PC20Factory via TransparentUpgradeableProxy
        PC20Factory factoryImpl = new PC20Factory();
        TransparentUpgradeableProxy factoryProxy =
            new TransparentUpgradeableProxy(
                address(factoryImpl),
                makeAddr("factoryProxyAdmin"),
                abi.encodeCall(
                    PC20Factory.initialize,
                    (
                        admin,
                        pauser,
                        address(vaultContract),
                        address(gateway)
                    )
                )
            );
        pc20Factory = PC20Factory(address(factoryProxy));

        // Wire pc20Factory into Vault
        vm.prank(admin);
        vaultContract.updatePC20Factory(address(pc20Factory));

        // Wire pc20Factory into Gateway
        vm.prank(admin);
        gateway.updatePC20Factory(address(pc20Factory));

        // Deploy a wrapper via Vault (which has VAULT_ROLE)
        // Use finalizePC20Export to trigger wrapper deployment + mint
        vm.prank(tss);
        vaultContract.finalizePC20Export(
            bytes32(uint256(9999)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            user1,
            sourceAsset,
            10_000e18,
            "Push Token",
            "pTKN",
            18,
            ""
        );

        // Mint additional tokens to user2
        vm.prank(tss);
        vaultContract.finalizePC20Export(
            bytes32(uint256(9998)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            user2,
            sourceAsset,
            5_000e18,
            "Push Token",
            "pTKN",
            18,
            ""
        );

        wrapper = PC20Wrapper(pc20Factory.getWrapper(sourceAsset));
    }

    // =========================================================
    //  Helpers
    // =========================================================

    function _buildBurnReq(
        address _wrapper,
        uint256 _amount,
        bytes memory _recipient,
        bytes memory _payload,
        address _revertRecipient
    ) internal pure returns (PC20BurnRequest memory) {
        return PC20BurnRequest({
            wrapper: _wrapper,
            amount: _amount,
            recipient: _recipient,
            payload: _payload,
            revertRecipient: _revertRecipient
        });
    }

    address constant PUSH_RECIPIENT = address(0xBEEF);

    function _defaultBurnReq(
        uint256 _amount
    ) internal view returns (PC20BurnRequest memory) {
        return _buildBurnReq(
            address(wrapper),
            _amount,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user1
        );
    }

    // =========================================================
    //  11.1 Happy Path
    // =========================================================

    function test_SuccessfulBurn() public {
        uint256 balBefore = wrapper.balanceOf(user1);
        uint256 supplyBefore = wrapper.totalSupply();

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(wrapper.balanceOf(user1), balBefore - 100e18);
        assertEq(wrapper.totalSupply(), supplyBefore - 100e18);
    }

    function test_EventEmitted() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.expectEmit(true, true, true, true);
        emit PC20UniversalTx(
            user1,
            sourceAsset,
            address(wrapper),
            100e18,
            req.recipient,
            bytes(""),
            user1,
            0
        );

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);
    }

    function test_SourceAssetResolved() public {
        PC20BurnRequest memory req = _defaultBurnReq(50e18);

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(wrapper.SOURCE_ASSET(), sourceAsset);
    }

    function test_MultipleBurnsSameUser() public {
        vm.prank(user1);
        gateway.sendPC20UniversalTx(_defaultBurnReq(100e18));

        vm.prank(user1);
        gateway.sendPC20UniversalTx(_defaultBurnReq(200e18));

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 300e18
        );
    }

    function test_DifferentUsersBurnSameWrapper() public {
        vm.prank(user1);
        gateway.sendPC20UniversalTx(_defaultBurnReq(100e18));

        PC20BurnRequest memory req2 = _defaultBurnReq(200e18);
        vm.prank(user2);
        gateway.sendPC20UniversalTx(req2);

        assertEq(wrapper.balanceOf(user1), 10_000e18 - 100e18);
        assertEq(wrapper.balanceOf(user2), 5_000e18 - 200e18);
    }

    function test_BurnWithPayload() public {
        bytes memory payload = abi.encodeWithSignature(
            "doSomething(uint256)", 42
        );
        PC20BurnRequest memory req = _buildBurnReq(
            address(wrapper),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            payload,
            user1
        );

        vm.expectEmit(true, true, true, true);
        emit PC20UniversalTx(
            user1,
            sourceAsset,
            address(wrapper),
            100e18,
            req.recipient,
            payload,
            user1,
            0
        );

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);
    }

    function test_BurnWithEmptyPayload() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.expectEmit(true, true, true, true);
        emit PC20UniversalTx(
            user1,
            sourceAsset,
            address(wrapper),
            100e18,
            req.recipient,
            bytes(""),
            user1,
            0
        );

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);
    }

    function test_InboundFeeCollected() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 feesBefore = gateway.totalProtocolFeesCollected();

        PC20BurnRequest memory req = _defaultBurnReq(100e18);
        vm.prank(user1);
        gateway.sendPC20UniversalTx{value: fee}(req);

        assertEq(
            gateway.totalProtocolFeesCollected(),
            feesBefore + fee
        );
    }

    function test_InboundFeeZero() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.expectEmit(true, true, true, true);
        emit PC20UniversalTx(
            user1,
            sourceAsset,
            address(wrapper),
            100e18,
            req.recipient,
            bytes(""),
            user1,
            0
        );

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);
    }

    function test_BurnEntireBalance() public {
        uint256 bal = wrapper.balanceOf(user1);
        PC20BurnRequest memory req = _defaultBurnReq(bal);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(wrapper.balanceOf(user1), 0);
    }

    // =========================================================
    //  11.2 Validation Reverts
    // =========================================================

    function test_Reverts_WrapperZeroAddress() public {
        PC20BurnRequest memory req = _buildBurnReq(
            address(0),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_AmountZero() public {
        PC20BurnRequest memory req = _defaultBurnReq(0);

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_EmptyRecipient() public {
        PC20BurnRequest memory req = _buildBurnReq(
            address(wrapper),
            100e18,
            bytes(""),
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_RevertRecipientZero() public {
        PC20BurnRequest memory req = _buildBurnReq(
            address(wrapper),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            address(0)
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_NonFactoryWrapper() public {
        PC20BurnRequest memory req = _buildBurnReq(
            makeAddr("fakeWrapper"),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_InsufficientInboundFee() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        gateway.sendPC20UniversalTx{value: fee / 2}(req);
    }

    function test_Reverts_AmountExceedsBalance() public {
        uint256 bal = wrapper.balanceOf(user1);
        PC20BurnRequest memory req = _defaultBurnReq(bal + 1);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_WhenGatewayPaused() public {
        vm.prank(pauser);
        gateway.pause();

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendPC20UniversalTx(req);
    }

    function test_Reverts_WhenFactoryPaused() public {
        vm.prank(pauser);
        pc20Factory.pause();

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendPC20UniversalTx(req);
    }

    // =========================================================
    //  11.3 No Approval Required
    // =========================================================

    function test_BurnWithoutApproval() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    function test_BurnWithZeroApprovalStillWorks() public {
        vm.prank(user1);
        wrapper.approve(address(gateway), 0);

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    // =========================================================
    //  11.4 No Rate Limiting
    // =========================================================

    function test_NoBlockRateLimit() public {
        PC20BurnRequest memory req = _defaultBurnReq(5_000e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        PC20BurnRequest memory req2 = _defaultBurnReq(5_000e18);
        vm.prank(user1);
        gateway.sendPC20UniversalTx(req2);

        assertEq(wrapper.balanceOf(user1), 0);
    }

    function test_NoEpochRateLimit() public {
        for (uint256 i = 0; i < 10; i++) {
            PC20BurnRequest memory req = _defaultBurnReq(100e18);
            vm.prank(user1);
            gateway.sendPC20UniversalTx(req);
        }

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 1_000e18
        );
    }

    function test_BurnDoesNotAffectRateLimitCounters() public {
        (uint256 usedBefore,) = gateway.currentTokenUsage(address(0));

        PC20BurnRequest memory req = _defaultBurnReq(100e18);
        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        (uint256 usedAfter,) = gateway.currentTokenUsage(address(0));
        assertEq(usedAfter, usedBefore);
    }

    // =========================================================
    //  11.6 updatePC20Factory
    // =========================================================

    function test_UpdateFactory_Success() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(admin);
        gateway.updatePC20Factory(newFactory);

        assertEq(
            address(gateway.pc20Factory()),
            newFactory
        );
    }

    function test_UpdateFactory_EmitsEvent() public {
        address newFactory = makeAddr("newFactory");

        vm.expectEmit(true, true, false, false);
        emit PC20FactoryUpdated(
            address(pc20Factory),
            newFactory
        );

        vm.prank(admin);
        gateway.updatePC20Factory(newFactory);
    }

    function test_UpdateFactory_RevertsZero() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.updatePC20Factory(address(0));
    }

    function test_UpdateFactory_RevertsNonOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.updatePC20Factory(makeAddr("f"));
    }

    function test_UpdateFactory_RevertsPauser() public {
        vm.prank(pauser);
        vm.expectRevert();
        gateway.updatePC20Factory(makeAddr("f"));
    }

    function test_UpdateFactory_NewFactoryUsedForBurns() public {
        // Deploy a second factory
        PC20Factory factoryImpl2 = new PC20Factory();
        TransparentUpgradeableProxy factoryProxy2 =
            new TransparentUpgradeableProxy(
                address(factoryImpl2),
                makeAddr("factoryProxyAdmin2"),
                abi.encodeCall(
                    PC20Factory.initialize,
                    (
                        admin,
                        pauser,
                        address(vaultContract),
                        address(gateway)
                    )
                )
            );
        PC20Factory newFactory = PC20Factory(address(factoryProxy2));

        // Update gateway to use new factory
        vm.prank(admin);
        gateway.updatePC20Factory(address(newFactory));

        // Old wrapper should no longer be recognized
        PC20BurnRequest memory req = _defaultBurnReq(100e18);
        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendPC20UniversalTx(req);
    }

    // =========================================================
    //  11.7 Wrapper Authenticity
    // =========================================================

    function test_FactoryDeployedWrapperPasses() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    function test_NonFactoryERC20Fails() public {
        PC20BurnRequest memory req = _buildBurnReq(
            address(tokenA),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendPC20UniversalTx(req);
    }

    function test_MaliciousContractMimickingSourceAssetFails() public {
        // Deploy a wrapper-like contract not via factory
        PC20Wrapper fake = new PC20Wrapper(
            "Fake", "FAKE", 18, sourceAsset, address(this)
        );

        PC20BurnRequest memory req = _buildBurnReq(
            address(fake),
            100e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendPC20UniversalTx(req);
    }

    // =========================================================
    //  11.8 Integration with Existing Gateway
    // =========================================================

    function test_FeeAccumulatesFromBothPaths() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 feesBefore = gateway.totalProtocolFeesCollected();

        // PC20 burn with fee
        PC20BurnRequest memory req = _defaultBurnReq(100e18);
        vm.prank(user1);
        gateway.sendPC20UniversalTx{value: fee}(req);

        uint256 feesAfterBurn = gateway.totalProtocolFeesCollected();
        assertEq(feesAfterBurn, feesBefore + fee);
    }

    // =========================================================
    //  11.9 Access Control
    // =========================================================

    function test_SendPC20IsPermissionless() public {
        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);
    }

    function test_UpdateFactoryRequiresOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.updatePC20Factory(makeAddr("f"));
    }

    // =========================================================
    //  11.10 Edge Cases
    // =========================================================

    function test_BurnSmallAmount() public {
        PC20BurnRequest memory req = _defaultBurnReq(1);

        vm.prank(user1);
        gateway.sendPC20UniversalTx(req);

        assertEq(wrapper.balanceOf(user1), 10_000e18 - 1);
    }

    function test_InboundFeeWithExcessValue() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 tssBefore = tss.balance;

        PC20BurnRequest memory req = _defaultBurnReq(100e18);
        vm.prank(user1);
        gateway.sendPC20UniversalTx{value: fee + 1 ether}(req);

        assertEq(tss.balance, tssBefore + fee);
        assertEq(gateway.totalProtocolFeesCollected(), fee);
    }

    function test_PC20FactoryNotSetReverts() public {
        // Deploy a fresh gateway without pc20Factory set
        UniversalGateway gwImpl = new UniversalGateway();
        ERC1967Proxy gwProxy = new ERC1967Proxy(
            address(gwImpl),
            abi.encodeCall(
                UniversalGateway.initialize,
                (
                    admin, pauser, tss,
                    address(this),
                    1e18, 10e18,
                    address(0), address(0),
                    address(weth)
                )
            )
        );
        UniversalGateway freshGw =
            UniversalGateway(payable(address(gwProxy)));

        PC20BurnRequest memory req = _defaultBurnReq(100e18);

        vm.prank(user1);
        vm.expectRevert();
        freshGw.sendPC20UniversalTx(req);
    }

    function test_ConcurrentBurns() public {
        uint256 supplyBefore = wrapper.totalSupply();

        vm.prank(user1);
        gateway.sendPC20UniversalTx(_defaultBurnReq(100e18));

        PC20BurnRequest memory req2 = _buildBurnReq(
            address(wrapper),
            200e18,
            abi.encodePacked(PUSH_RECIPIENT),
            bytes(""),
            user2
        );
        vm.prank(user2);
        gateway.sendPC20UniversalTx(req2);

        assertEq(wrapper.totalSupply(), supplyBefore - 300e18);
    }

    // =========================================================
    //  Event declarations
    // =========================================================

    event PC20UniversalTx(
        address indexed sender,
        address indexed sourceAsset,
        address indexed wrapper,
        uint256 amount,
        bytes recipient,
        bytes payload,
        address revertRecipient,
        uint256 feeCollected
    );

    event PC20FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );
}
