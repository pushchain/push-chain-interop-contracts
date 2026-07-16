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
import {UniversalTxRequest} from "../../src/libraries/TypesUG.sol";
import {TX_TYPE, PC_20_SELECTOR} from "../../src/libraries/Types.sol";
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

    address constant PUSH_RECIPIENT = address(0xBEEF);

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

        // Deploy a wrapper via Vault's unified finalizeUniversalTx (PC20 path)
        // Tokens are minted to CEA; transfer to users afterwards
        bytes memory pc20Data1 = abi.encodePacked(
            bytes4(0x50433230),
            abi.encode("Push Token", "pTKN", uint8(18), bytes(""))
        );
        vm.prank(tss);
        vaultContract.finalizeUniversalTx(
            bytes32(uint256(9999)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            user1,
            sourceAsset,
            10_000e18,
            pc20Data1
        );

        bytes memory pc20Data2 = abi.encodePacked(
            bytes4(0x50433230),
            abi.encode("Push Token", "pTKN", uint8(18), bytes(""))
        );
        vm.prank(tss);
        vaultContract.finalizeUniversalTx(
            bytes32(uint256(9998)),
            bytes32(uint256(8888)),
            makeAddr("pushAccount"),
            user2,
            sourceAsset,
            5_000e18,
            pc20Data2
        );

        wrapper = PC20Wrapper(pc20Factory.getWrapper(sourceAsset));

        // Transfer tokens from CEA to users
        (address cea,) = ceaFactory.getCEAForPushAccount(
            makeAddr("pushAccount")
        );
        vm.startPrank(cea);
        wrapper.transfer(user1, 10_000e18);
        wrapper.transfer(user2, 5_000e18);
        vm.stopPrank();
    }

    // =========================================================
    //  Helpers
    // =========================================================

    function _buildPC20Req(
        address _wrapper,
        uint256 _amount,
        address _recipient,
        bytes memory _payload,
        address _revertRecipient
    ) internal pure returns (UniversalTxRequest memory) {
        return UniversalTxRequest({
            recipient: _recipient,
            token: _wrapper,
            amount: _amount,
            payload: _payload,
            revertRecipient: _revertRecipient,
            signatureData: bytes("")
        });
    }

    function _defaultPC20Req(
        uint256 _amount
    ) internal view returns (UniversalTxRequest memory) {
        return _buildPC20Req(
            address(wrapper),
            _amount,
            PUSH_RECIPIENT,
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

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(wrapper.balanceOf(user1), balBefore - 100e18);
        assertEq(wrapper.totalSupply(), supplyBefore - 100e18);
    }

    function test_EventEmitted() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            PUSH_RECIPIENT,
            address(wrapper),
            100e18,
            abi.encodePacked(PC_20_SELECTOR),
            user1,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_SourceAssetResolved() public {
        UniversalTxRequest memory req = _defaultPC20Req(50e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(wrapper.SOURCE_ASSET(), sourceAsset);
    }

    function test_MultipleBurnsSameUser() public {
        vm.prank(user1);
        gateway.sendUniversalTx(_defaultPC20Req(100e18));

        vm.prank(user1);
        gateway.sendUniversalTx(_defaultPC20Req(200e18));

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 300e18
        );
    }

    function test_DifferentUsersBurnSameWrapper() public {
        vm.prank(user1);
        gateway.sendUniversalTx(_defaultPC20Req(100e18));

        UniversalTxRequest memory req2 = _defaultPC20Req(200e18);
        vm.prank(user2);
        gateway.sendUniversalTx(req2);

        assertEq(wrapper.balanceOf(user1), 10_000e18 - 100e18);
        assertEq(wrapper.balanceOf(user2), 5_000e18 - 200e18);
    }

    function test_BurnWithPayload() public {
        bytes memory payload = abi.encodeWithSignature(
            "doSomething(uint256)", 42
        );
        UniversalTxRequest memory req = _buildPC20Req(
            address(wrapper),
            100e18,
            PUSH_RECIPIENT,
            payload,
            user1
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            PUSH_RECIPIENT,
            address(wrapper),
            100e18,
            abi.encodePacked(PC_20_SELECTOR, payload),
            user1,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_BurnWithEmptyPayload() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            PUSH_RECIPIENT,
            address(wrapper),
            100e18,
            abi.encodePacked(PC_20_SELECTOR),
            user1,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_InboundFeeCollected() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 feesBefore = gateway.totalProtocolFeesCollected();

        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        gateway.sendUniversalTx{value: fee}(req);

        assertEq(
            gateway.totalProtocolFeesCollected(),
            feesBefore + fee
        );
    }

    function test_InboundFeeZero() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            PUSH_RECIPIENT,
            address(wrapper),
            100e18,
            abi.encodePacked(PC_20_SELECTOR),
            user1,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_BurnEntireBalance() public {
        uint256 bal = wrapper.balanceOf(user1);
        UniversalTxRequest memory req = _defaultPC20Req(bal);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(wrapper.balanceOf(user1), 0);
    }

    // =========================================================
    //  11.2 Validation Reverts
    // =========================================================

    function test_Reverts_WrapperZeroAddress() public {
        // token=address(0) falls through to PRC20 path — _consumeRateLimit reverts
        UniversalTxRequest memory req = _buildPC20Req(
            address(0),
            100e18,
            PUSH_RECIPIENT,
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_AmountZero() public {
        // amount=0, empty payload, no msg.value → _fetchTxType reverts InvalidInput
        UniversalTxRequest memory req = _defaultPC20Req(0);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_RevertRecipientZero() public {
        UniversalTxRequest memory req = _buildPC20Req(
            address(wrapper),
            100e18,
            PUSH_RECIPIENT,
            bytes(""),
            address(0)
        );

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_NonFactoryWrapper() public {
        // Falls through to PRC20 path → _consumeRateLimit reverts NotSupported
        UniversalTxRequest memory req = _buildPC20Req(
            makeAddr("fakeWrapper"),
            100e18,
            PUSH_RECIPIENT,
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_InsufficientInboundFee() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        vm.expectRevert(Errors.InsufficientProtocolFee.selector);
        gateway.sendUniversalTx{value: fee / 2}(req);
    }

    function test_Reverts_AmountExceedsBalance() public {
        uint256 bal = wrapper.balanceOf(user1);
        UniversalTxRequest memory req = _defaultPC20Req(bal + 1);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_WhenGatewayPaused() public {
        vm.prank(pauser);
        gateway.pause();

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    function test_Reverts_WhenFactoryPaused() public {
        vm.prank(pauser);
        pc20Factory.pause();

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    // =========================================================
    //  11.3 No Approval Required
    // =========================================================

    function test_BurnWithoutApproval() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    function test_BurnWithZeroApprovalStillWorks() public {
        vm.prank(user1);
        wrapper.approve(address(gateway), 0);

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    // =========================================================
    //  11.4 No Rate Limiting
    // =========================================================

    function test_NoBlockRateLimit() public {
        UniversalTxRequest memory req = _defaultPC20Req(5_000e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        UniversalTxRequest memory req2 = _defaultPC20Req(5_000e18);
        vm.prank(user1);
        gateway.sendUniversalTx(req2);

        assertEq(wrapper.balanceOf(user1), 0);
    }

    function test_NoEpochRateLimit() public {
        for (uint256 i = 0; i < 10; i++) {
            UniversalTxRequest memory req = _defaultPC20Req(100e18);
            vm.prank(user1);
            gateway.sendUniversalTx(req);
        }

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 1_000e18
        );
    }

    function test_BurnDoesNotAffectRateLimitCounters() public {
        (uint256 usedBefore,) = gateway.currentTokenUsage(address(0));

        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        (uint256 usedAfter,) = gateway.currentTokenUsage(address(0));
        assertEq(usedAfter, usedBefore);
    }

    // =========================================================
    //  11.5 PC20-specific event semantics
    // =========================================================

    function test_PC20_PayloadPrefixedWithSelector() public {
        bytes memory userPayload = hex"deadbeef";
        UniversalTxRequest memory req = _buildPC20Req(
            address(wrapper), 100e18, PUSH_RECIPIENT, userPayload, user1
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, PUSH_RECIPIENT, address(wrapper), 100e18,
            abi.encodePacked(PC_20_SELECTOR, userPayload),
            user1, TX_TYPE.FUNDS_AND_PAYLOAD, bytes(""), false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_PC20_EmptyPayloadStillGetsSelectorPrefix() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, PUSH_RECIPIENT, address(wrapper), 100e18,
            abi.encodePacked(PC_20_SELECTOR),
            user1, TX_TYPE.FUNDS_AND_PAYLOAD, bytes(""), false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_PC20_TxTypeAlwaysFundsAndPayload() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, PUSH_RECIPIENT, address(wrapper), 100e18,
            abi.encodePacked(PC_20_SELECTOR),
            user1, TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""), false
        );

        vm.prank(user1);
        gateway.sendUniversalTx(req);
    }

    function test_PC20_DoesNotConsumeRateLimit() public {
        (uint256 usedBefore,) = gateway.currentTokenUsage(address(wrapper));

        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        (uint256 usedAfter,) = gateway.currentTokenUsage(address(wrapper));
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

        // Old wrapper should no longer be recognized — falls through to PRC20
        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    // =========================================================
    //  11.7 Wrapper Authenticity
    // =========================================================

    function test_FactoryDeployedWrapperPasses() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(
            wrapper.balanceOf(user1),
            10_000e18 - 100e18
        );
    }

    function test_NonFactoryERC20Fails() public {
        UniversalTxRequest memory req = _buildPC20Req(
            address(tokenA),
            100e18,
            PUSH_RECIPIENT,
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
    }

    function test_MaliciousContractMimickingSourceAssetFails() public {
        // Deploy a wrapper-like contract not via factory
        PC20Wrapper fake = new PC20Wrapper(
            "Fake", "FAKE", 18, sourceAsset, address(this)
        );

        UniversalTxRequest memory req = _buildPC20Req(
            address(fake),
            100e18,
            PUSH_RECIPIENT,
            bytes(""),
            user1
        );

        vm.prank(user1);
        vm.expectRevert();
        gateway.sendUniversalTx(req);
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
        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        gateway.sendUniversalTx{value: fee}(req);

        uint256 feesAfterBurn = gateway.totalProtocolFeesCollected();
        assertEq(feesAfterBurn, feesBefore + fee);
    }

    // =========================================================
    //  11.9 Access Control
    // =========================================================

    function test_SendPC20IsPermissionless() public {
        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx(req);
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
        UniversalTxRequest memory req = _defaultPC20Req(1);

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        assertEq(wrapper.balanceOf(user1), 10_000e18 - 1);
    }

    function test_InboundFeeWithExcessValue() public {
        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 tssBefore = tss.balance;

        UniversalTxRequest memory req = _defaultPC20Req(100e18);
        vm.prank(user1);
        gateway.sendUniversalTx{value: fee + 1 ether}(req);

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

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        vm.expectRevert();
        freshGw.sendUniversalTx(req);
    }

    function test_ConcurrentBurns() public {
        uint256 supplyBefore = wrapper.totalSupply();

        vm.prank(user1);
        gateway.sendUniversalTx(_defaultPC20Req(100e18));

        UniversalTxRequest memory req2 = _buildPC20Req(
            address(wrapper),
            200e18,
            PUSH_RECIPIENT,
            bytes(""),
            user2
        );
        vm.prank(user2);
        gateway.sendUniversalTx(req2);

        assertEq(wrapper.totalSupply(), supplyBefore - 300e18);
    }

    // =========================================================
    //  11.11 CEA Fee Skip
    // =========================================================

    function _deployCEAAndFund()
        internal
        returns (address cea)
    {
        vm.prank(admin);
        gateway.updateCEAFactory(address(ceaFactory));

        // Deploy a CEA via the factory (must call as vault)
        vm.prank(address(vaultContract));
        cea = ceaFactory.deployCEA(makeAddr("ceaOwner"));

        // Transfer wrapper tokens to the CEA
        vm.prank(user1);
        wrapper.transfer(cea, 500e18);
    }

    function test_CEA_SkipsInboundFee() public {
        address cea = _deployCEAAndFund();

        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 feesBefore = gateway.totalProtocolFeesCollected();

        UniversalTxRequest memory req = _buildPC20Req(
            address(wrapper),
            100e18,
            makeAddr("ceaOwner"),  // must match CEA's mapped UEA
            bytes(""),
            makeAddr("ceaOwner")
        );

        vm.prank(cea);
        gateway.sendUniversalTxFromCEA(req);

        assertEq(
            gateway.totalProtocolFeesCollected(),
            feesBefore,
            "Fee should not increase for CEA caller"
        );
    }

    function test_CEA_NoFeeRequiredWhenFeeSet() public {
        address cea = _deployCEAAndFund();

        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        UniversalTxRequest memory req = _buildPC20Req(
            address(wrapper),
            100e18,
            makeAddr("ceaOwner"),
            bytes(""),
            makeAddr("ceaOwner")
        );

        // Should NOT revert with InsufficientProtocolFee
        vm.prank(cea);
        gateway.sendUniversalTxFromCEA(req);
    }

    function test_NonCEA_StillChargesInboundFee() public {
        _deployCEAAndFund();

        uint256 fee = 0.01 ether;
        vm.prank(admin);
        gateway.setInboundFee(fee);

        uint256 feesBefore = gateway.totalProtocolFeesCollected();

        UniversalTxRequest memory req = _defaultPC20Req(100e18);

        vm.prank(user1);
        gateway.sendUniversalTx{value: fee}(req);

        assertEq(
            gateway.totalProtocolFeesCollected(),
            feesBefore + fee,
            "Fee should still be charged for non-CEA caller"
        );
    }

    // =========================================================
    //  11.12 PRC20 unaffected by PC20 changes
    // =========================================================

    function test_PRC20_NotAffectedByPC20Changes() public {
        // tokenA is a regular ERC20 from BaseTest
        // Set up rate limit threshold for tokenA
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Mint and approve
        tokenA.mint(user1, 1000e18);
        vm.prank(user1);
        tokenA.approve(address(gateway), 1000e18);

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: PUSH_RECIPIENT,
            token: address(tokenA),
            amount: 100e18,
            payload: bytes(""),
            revertRecipient: user1,
            signatureData: bytes("")
        });

        vm.prank(user1);
        gateway.sendUniversalTx(req);

        // Token should be locked in gateway's vault (BaseTest uses address(this)), not burned
        assertEq(tokenA.balanceOf(address(this)), 100e18);
    }

    // =========================================================
    //  Event declarations
    // =========================================================

    event PC20FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );
}
