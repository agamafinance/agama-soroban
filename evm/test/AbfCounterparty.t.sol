// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {AbfRegistry} from "../src/AbfRegistry.sol";
import {AbfKyc} from "../src/AbfKyc.sol";
import {AbfOracle} from "../src/AbfOracle.sol";
import {AbfMasterVault} from "../src/AbfMasterVault.sol";
import {AbfMatchingEngine} from "../src/AbfMatchingEngine.sol";
import {IAbfMasterVault} from "../src/IAbfMasterVault.sol";
import {IAbfMatchingEngine} from "../src/IAbfMatchingEngine.sol";
import {IAbfOracle} from "../src/IAbfOracle.sol";
import {IAbfRegistry} from "../src/IAbfRegistry.sol";
import {IAbfRoles} from "../src/IAbfRoles.sol";

/// @title The counterparty replica, held to the partner's measured behaviour
/// @notice Compiling against the partner's signatures proves nothing on its own. What has to hold is that
///         the same calldata produces the same outcome, including the outcomes nobody wants: a premium
///         leaving for their treasury, a redemption refusing to pay because the yield is still off chain,
///         and a NAV going stale one period after it stopped being written.
contract AbfCounterpartyTest is Test {
    uint256 internal constant PERIOD = 300;
    uint256 internal constant CAP = 10_000_000e6;
    uint256 internal constant RATIO = 9_000;
    uint256 internal constant NAV_PRICE = 10_000;
    uint256 internal constant AMOUNT = 1_000_000e6;
    uint256 internal constant SAFE_USDC = 5_000_000e6;
    /// @dev The most that may sit with the fund administrator against a 90% ratio, which is where yield is
    ///      earned. The 10% that stays is the only cash a redemption can be paid from until it comes back.
    uint256 internal constant ALLOCATED = (AMOUNT * RATIO) / NAV_PRICE;
    uint256 internal constant KYC_TOKEN_ID = 1;

    MockUSDC internal usdc;
    AbfRegistry internal registry;
    AbfKyc internal kyc;
    AbfOracle internal oracle;
    AbfMasterVault internal vault;
    AbfMatchingEngine internal engine;

    address internal operator = makeAddr("partner operator");
    address internal strategic = makeAddr("partner strategic operator");
    address internal treasury = makeAddr("partner treasury");
    address internal fundReceiver = makeAddr("partner fund receiver");
    /// @dev Agama's side. In production this is the Safe that holds the KYC credential; the depositor on
    ///      Stellar never appears on this chain at all.
    address internal safe = makeAddr("agama safe");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AbfRegistry(address(this));
        kyc = new AbfKyc(address(this));
        oracle = new AbfOracle(address(this), address(registry), PERIOD, block.timestamp);
        vault = new AbfMasterVault(
            address(this), address(registry), address(usdc), "ABF USD Sepolia", "abfUSD-SEP", CAP, RATIO
        );
        engine = new AbfMatchingEngine(address(this), address(registry), 10, 1_000);

        registry.setContractAddress(uint8(IAbfRegistry.ContractType.KYC), address(kyc));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.ORACLE), address(oracle));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.MATCHING_ENGINE), address(engine));
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.TREASURY), treasury);
        registry.setContractAddress(uint8(IAbfRegistry.ContractType.VAULT_FUND_RECEIVERS), fundReceiver);
        registry.setVaultType(address(vault), IAbfRegistry.VaultType.MASTER_VAULT);

        // Roles, not ownership. The deployer below keeps `owner()` on every contract and still cannot settle
        // an order or write a NAV, which is the partner's own arrangement after their setup roles were revoked.
        kyc.setOperator(operator, kyc.OPERATOR_ROLE(), true);
        oracle.setOperator(operator, oracle.OPERATOR_ROLE(), true);
        engine.setOperator(operator, engine.OPERATOR_ROLE(), true);
        engine.setOperator(strategic, engine.STRATEGIC_ROLE(), true);
        vault.setOperator(strategic, vault.STRATEGIC_ROLE(), true);
        vault.setOperator(operator, vault.OPERATOR_ROLE(), true);
        registry.setOperator(strategic, registry.STRATEGIC_ROLE(), true);

        engine.setPaymentToken(address(usdc), true);
        vm.prank(operator);
        kyc.mint(safe, KYC_TOKEN_ID);

        usdc.mint(safe, SAFE_USDC);
        usdc.mint(fundReceiver, 1_000_000e6);
        vm.prank(fundReceiver);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Fixture
    // ---------------------------------------------------------------------------------------------

    function test_deploymentWiring() public view {
        assertEq(vault.asset(), address(usdc), "USDC is the payment asset, not a mock stablecoin of our own");
        assertEq(vault.symbol(), "abfUSD-SEP");
        assertEq(vault.decimals(), 6, "share precision follows the asset with no offset");
        assertEq(vault.registry(), address(registry));
        assertEq(engine.registry(), address(registry));
        assertEq(uint8(registry.vaultTypes(address(vault))), uint8(IAbfRegistry.VaultType.MASTER_VAULT));
        assertEq(uint8(registry.protocolState()), uint8(IAbfRegistry.ProtocolState.NORMAL));
        assertTrue(engine.paymentTokensAccepted(address(usdc)));
        assertEq(engine.BIPS_BASE(), NAV_PRICE);
        assertEq(oracle.WEEK_DURATION(), PERIOD);
        assertGt(registry.isKYC(safe), 0, "the Safe holds the credential");
        assertEq(registry.isKYC(address(this)), 0, "nobody else does");
    }

    /// @dev Character for character the partner's type string. A signature over any other string recovers a
    ///      different address, so this single constant is the whole compatibility story for signed orders.
    function test_orderTypehashMatchesThePartners() public view {
        assertEq(
            engine.ORDER_TYPEHASH(),
            keccak256(
                "Order(uint8 orderType,address instrument,uint256 trancheId,uint256 amount,uint256 price,"
                "address payer,address receiver,uint256 expiry,bytes32 salt)"
            )
        );
    }

    function test_eip712DomainIsThisEngineOnThisChain() public view {
        (,,, uint256 chainId, address verifyingContract,,) = engine.eip712Domain();
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(engine));
    }

    // ---------------------------------------------------------------------------------------------
    // The closed doors, which are the whole architecture
    // ---------------------------------------------------------------------------------------------

    function test_directVaultEntryAndExitAreDisabled() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(IAbfMasterVault.ErrNotPermitted.selector);
        vault.mint(1, stranger);
        vm.expectRevert(IAbfMasterVault.ErrNotPermitted.selector);
        vault.withdraw(1, stranger, stranger);
        vm.expectRevert(IAbfMasterVault.ErrNotAllowedToDeposit.selector);
        vault.deposit(1, stranger);
        vm.expectRevert(IAbfMasterVault.ErrNotAllowedToRedeem.selector);
        vault.redeem(1, stranger, stranger);
        vm.stopPrank();
    }

    function test_revert_postOrderWithoutTheCredential() public {
        address unknown = makeAddr("un-diligenced counterparty");
        usdc.mint(unknown, AMOUNT);
        vm.startPrank(unknown);
        usdc.approve(address(engine), AMOUNT);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.BID, AMOUNT);
        o.payer = unknown;
        o.receiver = unknown;
        vm.expectRevert(IAbfMatchingEngine.ErrNotKYC.selector);
        engine.postOrder(_signed(o), true);
        vm.stopPrank();
    }

    function test_revert_postOrderOutsidePreWindow() public {
        _enterSettling();
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.BID, AMOUNT);
        vm.prank(safe);
        vm.expectRevert(IAbfMatchingEngine.ErrEngineNotInPreWindow.selector);
        engine.postOrder(_signed(o), true);
    }

    function test_revert_matchOrdersOutsideSettling() public {
        IAbfMatchingEngine.Order memory o = _post(AMOUNT);
        vm.prank(operator);
        vm.expectRevert(IAbfMatchingEngine.ErrEngineNotInSettling.selector);
        engine.matchOrders(_fill(o, AMOUNT), _noOrder());
    }

    /// @dev The trap in the partner's integration notes, as a test. `owner()` is this contract on every
    ///      deployment above and it can still settle nothing: a fork test that impersonates the owner and
    ///      expects to match an order fails, and the reason is never in the error message.
    function test_revert_ownerAloneCannotSettleOrWriteNav() public {
        IAbfMatchingEngine.Order memory o = _post(AMOUNT);
        _enterSettling();
        assertEq(engine.owner(), address(this));
        vm.expectRevert(abi.encodeWithSelector(IAbfRoles.ErrNotWithRole.selector, engine.OPERATOR_ROLE()));
        engine.matchOrders(_fill(o, AMOUNT), _noOrder());
        vm.expectRevert(abi.encodeWithSelector(IAbfRoles.ErrNotWithRole.selector, oracle.OPERATOR_ROLE()));
        oracle.updateFundNav(address(vault), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Entry and exit
    // ---------------------------------------------------------------------------------------------

    function test_entryBidMintsSharesToTheSafe() public {
        IAbfMatchingEngine.Order memory o = _post(AMOUNT);

        assertEq(usdc.balanceOf(safe), SAFE_USDC - AMOUNT, "funded at post time, not at settlement");
        assertEq(engine.tokenBalances(safe, address(usdc)), AMOUNT);
        (address poster,, IAbfMatchingEngine.OrderStatus status, uint256 remaining) =
            engine.postedOrders(engine.hashOrder(o));
        assertEq(poster, safe, "the payer is the poster");
        assertEq(uint8(status), uint8(IAbfMatchingEngine.OrderStatus.POSTED));
        assertEq(remaining, AMOUNT);

        _enterSettling();
        uint256 expectedShares = vault.previewDeposit(AMOUNT);
        vm.prank(operator);
        engine.matchOrders(_fill(o, AMOUNT), _noOrder());

        assertEq(vault.balanceOf(safe), expectedShares);
        assertEq(engine.tokenBalances(safe, address(usdc)), 0, "the bid consumed its escrow");
        (,, status,) = engine.postedOrders(engine.hashOrder(o));
        assertEq(uint8(status), uint8(IAbfMatchingEngine.OrderStatus.FILLED));
    }

    function test_exitAskReturnsAssetsToTheSafe() public {
        uint256 shares = _enterWithBid(AMOUNT);
        uint256 before = usdc.balanceOf(safe);
        uint256 expectedAssets = vault.previewRedeem(shares);

        _enterPreWindow();
        vm.startPrank(safe);
        vault.approve(address(engine), shares);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.ASK, shares);
        engine.postOrder(_signed(o), true);
        vm.stopPrank();
        assertEq(vault.balanceOf(safe), 0, "the shares are escrowed in the engine");
        assertEq(engine.tokenBalances(safe, address(vault)), shares);

        _enterSettling();
        vm.prank(operator);
        engine.matchOrders(_noOrder(), _fill(o, shares));

        assertEq(usdc.balanceOf(safe) - before, expectedAssets);
        assertEq(vault.balanceOf(safe), 0);
        assertEq(engine.tokenBalances(safe, address(vault)), 0);
    }

    function test_roundTripIsValueNeutralAtNav() public {
        uint256 shares = _enterWithBid(AMOUNT);
        _exitWithAsk(shares);
        assertEq(usdc.balanceOf(safe), SAFE_USDC, "no premium, no discount and no fee at price 10000");
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// @notice Why the keeper's permissions pin `price` to NAV, measured rather than asserted. The figure
    ///         below is the one the partner's own staging deployment produced for the same inputs.
    function test_bidAboveNavPaysThePremiumToThePartnerTreasury() public {
        uint256 gross = AMOUNT; // committed
        uint256 net = 900_000e6; // actually deposited at NAV
        uint256 price = 11_111; // gross over net in bps, an 11.11% premium

        vm.startPrank(safe);
        usdc.approve(address(engine), gross);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.BID, gross);
        o.price = price;
        engine.postOrder(_signed(o), true);
        vm.stopPrank();

        _enterSettling();
        vm.prank(operator);
        engine.matchOrders(_fill(o, net), _noOrder());

        assertEq(vault.balanceOf(safe), net, "shares for the net amount only");
        assertEq(usdc.balanceOf(safe), SAFE_USDC - gross);
        assertEq(usdc.balanceOf(treasury), 99_990e6, "the premium left Agama and bought nothing");
    }

    function test_askBelowNavGivesUpTheDiscount() public {
        uint256 shares = _enterWithBid(AMOUNT);
        uint256 before = usdc.balanceOf(safe);

        _enterPreWindow();
        vm.startPrank(safe);
        vault.approve(address(engine), shares);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.ASK, shares);
        o.price = 9_000;
        engine.postOrder(_signed(o), true);
        vm.stopPrank();

        _enterSettling();
        vm.prank(operator);
        engine.matchOrders(_noOrder(), _fill(o, shares));

        assertEq(usdc.balanceOf(safe) - before, (AMOUNT * 9_000) / NAV_PRICE, "ninety cents on the dollar");
        assertEq(usdc.balanceOf(treasury), AMOUNT / 10, "and the other ten went to them");
    }

    function test_cancelLeavesTheEscrowWithdrawableByItsOwner() public {
        IAbfMatchingEngine.Order memory o = _post(AMOUNT);
        vm.startPrank(safe);
        engine.cancelOrder(_signed(o));
        (,, IAbfMatchingEngine.OrderStatus status,) = engine.postedOrders(engine.hashOrder(o));
        assertEq(uint8(status), uint8(IAbfMatchingEngine.OrderStatus.CANCELLED));
        assertEq(engine.tokenBalances(safe, address(usdc)), AMOUNT, "still escrowed, not pushed back");
        engine.withdrawToken(address(usdc), AMOUNT);
        vm.stopPrank();
        assertEq(usdc.balanceOf(safe), SAFE_USDC, "withdrawToken pays its caller and nobody else");
    }

    // ---------------------------------------------------------------------------------------------
    // Where the yield comes from, and what it costs to make it payable
    // ---------------------------------------------------------------------------------------------

    function test_navIncreaseRaisesTheValuePerShare() public {
        uint256 shares = _enterWithBid(AMOUNT);
        assertEq(vault.convertToAssets(shares), AMOUNT, "one for one on entry");

        vm.prank(strategic);
        vault.allocateToFund(ALLOCATED);
        assertEq(vault.totalAssets(), AMOUNT - ALLOCATED, "cash left and nothing has replaced it yet");
        vm.prank(operator);
        oracle.updateFundNav(address(vault), ALLOCATED);
        assertEq(vault.totalAssets(), AMOUNT, "and now the reported book replaces it exactly");

        skip(PERIOD);
        vm.prank(operator);
        oracle.updateFundNav(address(vault), ALLOCATED + 50_000e6);
        assertEq(vault.convertToAssets(shares), AMOUNT + 50_000e6, "5% of yield, reported not computed");
    }

    /// @dev The honest failure. A NAV the administrator raised is a claim, not cash, and this vault refuses
    ///      to pay a redemption it cannot fund rather than paying part of it.
    function test_revert_redeemBeforeTheYieldIsFunded() public {
        uint256 shares = _enterWithBid(AMOUNT);
        vm.prank(strategic);
        vault.allocateToFund(ALLOCATED);
        vm.prank(operator);
        oracle.updateFundNav(address(vault), ALLOCATED + 50_000e6);
        assertEq(vault.convertToAssets(shares), AMOUNT + 50_000e6, "owed");
        assertEq(vault.getAvailableAssets(), AMOUNT - ALLOCATED, "held");

        _enterPreWindow();
        vm.startPrank(safe);
        vault.approve(address(engine), shares);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.ASK, shares);
        engine.postOrder(_signed(o), true);
        vm.stopPrank();
        _enterSettling();

        vm.prank(operator);
        vm.expectRevert("not enough liquid assets");
        engine.matchOrders(_noOrder(), _fill(o, shares));
    }

    function test_returnFromFundMakesTheYieldPayable() public {
        uint256 shares = _enterWithBid(AMOUNT);
        vm.prank(strategic);
        vault.allocateToFund(ALLOCATED);
        vm.prank(operator);
        oracle.updateFundNav(address(vault), ALLOCATED + 50_000e6);

        // Cash back in and the book written down in the same breath. Doing one without the other is the
        // operational hazard this pair of calls exists to make visible: in between, the vault counts the
        // same money twice, and anything depositing in that window mints against an inflated valuation.
        skip(PERIOD);
        vm.prank(strategic);
        vault.returnFromFund(ALLOCATED + 50_000e6);
        assertEq(vault.totalAssets(), AMOUNT + ALLOCATED + 100_000e6, "double counted until the NAV is written down");
        vm.prank(operator);
        oracle.updateFundNav(address(vault), 0);
        assertEq(vault.totalAssets(), AMOUNT + 50_000e6, "and correct once it is");

        _exitWithAsk(shares);
        assertEq(usdc.balanceOf(safe), SAFE_USDC + 50_000e6, "the yield arrived as cash");
    }

    function test_allocateToFundRespectsTheRatio() public {
        _enterWithBid(AMOUNT);
        vm.prank(strategic);
        vm.expectRevert("allocation would exceed the off-chain ratio");
        vault.allocateToFund(AMOUNT); // 100% off chain against a 90% ratio
        vm.prank(strategic);
        vault.allocateToFund((AMOUNT * RATIO) / NAV_PRICE);
    }

    // ---------------------------------------------------------------------------------------------
    // The oracle, whose staleness is counted in periods and not in seconds
    // ---------------------------------------------------------------------------------------------

    function test_revert_twoNavUpdatesInOnePeriod() public {
        vm.startPrank(operator);
        oracle.updateFundNav(address(vault), 1_000e6);
        vm.expectRevert(IAbfOracle.ErrWeekAlreadyUpdated.selector);
        oracle.updateFundNav(address(vault), 2_000e6);
        vm.stopPrank();
    }

    function test_navGoesStaleAfterMoreThanOnePeriod() public {
        vm.prank(operator);
        oracle.updateFundNav(address(vault), 1_000e6);
        assertEq(oracle.getNonStaleLatestFundNav(address(vault)), 1_000e6);

        skip(PERIOD); // one period old, still served
        assertEq(oracle.getNonStaleLatestFundNav(address(vault)), 1_000e6);

        skip(PERIOD); // two periods old
        vm.expectRevert(IAbfOracle.ErrStaleData.selector);
        oracle.getNonStaleLatestFundNav(address(vault));

        // And the reason there are two functions: the unchecked one keeps answering, so anything that cares
        // about freshness has to ask for it by name.
        assertEq(oracle.getLatestFundNav(address(vault)), 1_000e6);
    }

    function test_anUnvaluedVaultIsWorthItsCash() public {
        assertEq(oracle.logCount(address(vault)), 0);
        assertEq(vault.getFundAdminNav(), 0, "no entries reads as zero, not as undefined");
        _enterWithBid(AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_capLimitsDeposits() public {
        vm.prank(strategic);
        vault.setCap(AMOUNT / 2);
        IAbfMatchingEngine.Order memory o = _post(AMOUNT);
        _enterSettling();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAbfMasterVault.ERC4626ExceededMaxDeposit.selector, safe, AMOUNT, AMOUNT / 2
            )
        );
        engine.matchOrders(_fill(o, AMOUNT), _noOrder());
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _newOrder(IAbfMatchingEngine.OrderType t, uint256 amount)
        internal
        view
        returns (IAbfMatchingEngine.Order memory)
    {
        return IAbfMatchingEngine.Order({
            orderType: t,
            instrument: address(vault),
            trancheId: 0,
            amount: amount,
            price: NAV_PRICE,
            payer: safe,
            receiver: safe,
            expiry: block.timestamp + 1 days,
            salt: keccak256(abi.encode(t, amount, vm.getBlockTimestamp(), vault.totalSupply()))
        });
    }

    /// @dev The signature is empty throughout. The payer posting its own order is authorisation enough, which
    ///      is why Agama's keeper needs no signing key for order entry: it calls as the Safe through Roles.
    function _signed(IAbfMatchingEngine.Order memory o)
        internal
        pure
        returns (IAbfMatchingEngine.SignedOrder memory)
    {
        return IAbfMatchingEngine.SignedOrder({
            order: o,
            erc3009Data: IAbfMatchingEngine.ERC3009Data({
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(0),
                signature: ""
            }),
            signer: address(0),
            signature: ""
        });
    }

    function _fill(IAbfMatchingEngine.Order memory o, uint256 fillAmount)
        internal
        pure
        returns (IAbfMatchingEngine.MatchingOrder memory)
    {
        return IAbfMatchingEngine.MatchingOrder({signedOrder: _signed(o), fillAmount: fillAmount});
    }

    function _noOrder() internal pure returns (IAbfMatchingEngine.MatchingOrder memory m) {
        m.fillAmount = 0;
    }

    function _post(uint256 amount) internal returns (IAbfMatchingEngine.Order memory o) {
        _enterPreWindow();
        o = _newOrder(IAbfMatchingEngine.OrderType.BID, amount);
        vm.startPrank(safe);
        usdc.approve(address(engine), amount);
        engine.postOrder(_signed(o), true);
        vm.stopPrank();
    }

    function _enterWithBid(uint256 amount) internal returns (uint256 shares) {
        IAbfMatchingEngine.Order memory o = _post(amount);
        _enterSettling();
        uint256 before = vault.balanceOf(safe);
        vm.prank(operator);
        engine.matchOrders(_fill(o, amount), _noOrder());
        shares = vault.balanceOf(safe) - before;
    }

    function _exitWithAsk(uint256 shares) internal {
        _enterPreWindow();
        vm.startPrank(safe);
        vault.approve(address(engine), shares);
        IAbfMatchingEngine.Order memory o = _newOrder(IAbfMatchingEngine.OrderType.ASK, shares);
        engine.postOrder(_signed(o), true);
        vm.stopPrank();
        _enterSettling();
        vm.prank(operator);
        engine.matchOrders(_noOrder(), _fill(o, shares));
    }

    function _enterSettling() internal {
        if (engine.engineState() != IAbfMatchingEngine.EngineState.SETTLING) {
            vm.prank(strategic);
            engine.setEngineState();
        }
    }

    function _enterPreWindow() internal {
        if (engine.engineState() != IAbfMatchingEngine.EngineState.PRE_WINDOW) {
            vm.prank(strategic);
            engine.setEngineState();
        }
    }
}
