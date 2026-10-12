// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfMatchingEngine} from "./IAbfMatchingEngine.sol";
import {IAbfMasterVault} from "./IAbfMasterVault.sol";
import {IAbfRegistry} from "./IAbfRegistry.sol";
import {IERC20} from "./IERC20.sol";
import {AbfRoles} from "./AbfRoles.sol";

/// @title The only door into and out of the Master Vault
/// @notice Orders are posted by the counterparty in PRE_WINDOW and settled by the partner's operator in
///         SETTLING. Nothing else moves a share.
/// @dev Two consequences Agama's design has to absorb rather than work around.
///
///      First, settlement is not ours to trigger. A BID sits posted until the operator moves the engine into
///      SETTLING and calls `matchOrders`. So capital is in flight for as long as a period lasts, which is why
///      Agama's withdrawal queue burns agUSD at request time and pays from a position in line, instead of
///      promising cash on demand it would have to hold idle to honour.
///
///      Second, `price` is where the money can leave. It is NAV-relative basis points: 10000 is NAV, and a BID
///      above it hands the difference to the partner's treasury for no extra shares. A keeper that may choose
///      the price may give the counterparty a gift. Agama's Zodiac Roles permission set pins it to 10000 on
///      both sides for exactly that reason, and `test_bidAboveNavPaysThePartnerTreasury` measures what the
///      pin is worth rather than asserting it is a good idea.
contract AbfMatchingEngine is IAbfMatchingEngine, AbfRoles {
    struct Posted {
        address poster;
        uint40 timestamp;
        OrderStatus status;
        uint256 remainingAmount;
    }

    uint256 public constant override BIPS_BASE = 10_000;

    /// @dev The exact type string the partner's engine hashes with. Copied character for character: a
    ///      signature over a different type string recovers a different address and is simply invalid, so
    ///      this constant is the whole compatibility story for signed orders.
    bytes32 public constant override ORDER_TYPEHASH = keccak256(
        "Order(uint8 orderType,address instrument,uint256 trancheId,uint256 amount,uint256 price,"
        "address payer,address receiver,uint256 expiry,bytes32 salt)"
    );

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    string private constant _NAME = "ABF Matching Engine";
    string private constant _VERSION = "1";

    address public immutable override registry;

    EngineState public override engineState;
    uint256 public override staticFee;
    uint256 public override spreadFee;

    mapping(bytes32 => Posted) private _postedOrders;
    mapping(address => mapping(address => uint256)) public override tokenBalances;
    mapping(address => uint256) public override userVersion;
    mapping(address => mapping(uint256 => mapping(address => bool))) public override approvedSigners;
    mapping(address => mapping(address => uint256)) public override minOrderSize;
    mapping(address => bool) public override isWhitelisted;
    mapping(address => bool) public override paymentTokensAccepted;
    mapping(address => bool) public override erc3009Support;

    constructor(address owner_, address registry_, uint256 staticFee_, uint256 spreadFee_) AbfRoles(owner_) {
        registry = registry_;
        staticFee = staticFee_;
        spreadFee = spreadFee_;
        engineState = EngineState.PRE_WINDOW;
        emit FeesUpdated(staticFee_, spreadFee_);
    }

    // -------------------------------------------------------------------------------------------------
    // Operator setup
    // -------------------------------------------------------------------------------------------------

    /// @dev A toggle, not a setter, exactly as the partner's is: the operator cannot jump the engine to an
    ///      arbitrary state, and calling it on an engine already settling moves it back out of settlement.
    function setEngineState() external override onlyRole(STRATEGIC_ROLE) {
        engineState = engineState == EngineState.SETTLING ? EngineState.PRE_WINDOW : EngineState.SETTLING;
        emit EngineStateSet(engineState);
    }

    function setPaymentToken(address token, bool approved) external onlyOwner {
        paymentTokensAccepted[token] = approved;
        emit PaymentTokenSet(token, approved);
    }

    function setFees(uint256 staticFee_, uint256 spreadFee_) external onlyOwner {
        staticFee = staticFee_;
        spreadFee = spreadFee_;
        emit FeesUpdated(staticFee_, spreadFee_);
    }

    function setMinOrderSize(address wantedToken, address offeredToken, uint256 amount) external onlyOwner {
        minOrderSize[wantedToken][offeredToken] = amount;
        emit MinOrderSizeSet(wantedToken, offeredToken, amount);
    }

    function setWhitelisted(address account, bool approved) external onlyOwner {
        isWhitelisted[account] = approved;
    }

    // -------------------------------------------------------------------------------------------------
    // Counterparty actions
    // -------------------------------------------------------------------------------------------------

    function incrementUserVersion() external override {
        userVersion[msg.sender] += 1;
        emit UserVersionIncremented(msg.sender);
    }

    function setApprovedSigner(address signer, bool approved) external override {
        approvedSigners[msg.sender][userVersion[msg.sender]][signer] = approved;
        emit ApprovedSignerSet(msg.sender, signer, approved);
    }

    /// @dev The replica funds orders by ERC-20 allowance only. An ERC-3009 payload is refused rather than
    ///      ignored, because silently accepting one and pulling by allowance instead would let an integration
    ///      pass here and fail against production, which is the one outcome a replica must not produce.
    function depositToken(address paymentToken, uint256 amount, ERC3009Data calldata erc3009Data) external override {
        if (!paymentTokensAccepted[paymentToken]) revert ErrPaymentTokenNotAccepted();
        if (erc3009Data.signature.length != 0 || erc3009Data.value != 0 || erc3009Data.from != address(0)) {
            revert ErrInvalidERC3009Data();
        }
        require(IERC20(paymentToken).transferFrom(msg.sender, address(this), amount), "transfer failed");
        tokenBalances[msg.sender][paymentToken] += amount;
    }

    /// @dev Always pays its caller. There is no `to` argument by design, so a permission set that lets a
    ///      keeper call this cannot be used to route funds anywhere but back to the account that owns them.
    function withdrawToken(address paymentToken, uint256 amount) external override {
        uint256 balance = tokenBalances[msg.sender][paymentToken];
        require(balance >= amount, "insufficient engine balance");
        tokenBalances[msg.sender][paymentToken] = balance - amount;
        require(IERC20(paymentToken).transfer(msg.sender, amount), "transfer failed");
        emit TokenWithdrawn(msg.sender, paymentToken, amount);
    }

    function postOrder(SignedOrder calldata signedOrder, bool deposit) external override returns (bytes32 hash) {
        if (engineState != EngineState.PRE_WINDOW) revert ErrEngineNotInPreWindow();
        Order calldata o = signedOrder.order;

        (, bool isEmergency) = IAbfRegistry(registry).getProtocolState();
        if (isEmergency) revert ErrEmergency();

        if (IAbfRegistry(registry).vaultTypes(o.instrument) != IAbfRegistry.VaultType.MASTER_VAULT) {
            revert ErrInvalidInstrument();
        }
        if (o.price == 0) revert ErrInvalidPrice();
        if (o.expiry < block.timestamp) revert ErrExpired();
        // Both sides of the order must be diligenced, not just whoever pays. A payer that could name any
        // receiver would make the credential meaningless.
        if (IAbfRegistry(registry).isKYC(o.payer) == 0 || IAbfRegistry(registry).isKYC(o.receiver) == 0) {
            revert ErrNotKYC();
        }

        address paymentToken = IAbfMasterVault(o.instrument).asset();
        address wanted = o.orderType == OrderType.BID ? o.instrument : paymentToken;
        address offered = o.orderType == OrderType.BID ? paymentToken : o.instrument;
        if (o.amount == 0 || o.amount < minOrderSize[wanted][offered]) revert ErrInvalidOrderSize();

        hash = hashOrder(o);
        if (_postedOrders[hash].status != OrderStatus.NULL) revert ErrOrderAlreadyPosted();
        _authorize(signedOrder, hash);

        if (deposit) {
            if (o.orderType == OrderType.BID) {
                if (!paymentTokensAccepted[paymentToken]) revert ErrPaymentTokenNotAccepted();
                require(IERC20(paymentToken).transferFrom(o.payer, address(this), o.amount), "funding failed");
                tokenBalances[o.payer][paymentToken] += o.amount;
            } else {
                require(IERC20(o.instrument).transferFrom(o.payer, address(this), o.amount), "funding failed");
                tokenBalances[o.payer][o.instrument] += o.amount;
            }
        } else {
            // Already funded through depositToken. Checked here so an unfundable order is refused at post
            // time rather than at settlement, when the operator is the one holding the failure.
            require(tokenBalances[o.payer][offered] >= o.amount, "order is not funded");
        }

        _postedOrders[hash] =
            Posted({poster: o.payer, timestamp: uint40(block.timestamp), status: OrderStatus.POSTED, remainingAmount: o.amount});
        emit OrderPosted(o.payer, o.instrument, hash, o);
    }

    /// @dev Cancelling leaves the escrow credited in `tokenBalances` rather than pushing it back. The owner
    ///      takes it out with `withdrawToken`, which pays its caller, so a cancellation can never be the step
    ///      that sends funds somewhere unexpected.
    function cancelOrder(SignedOrder calldata signedOrder) external override {
        Order calldata o = signedOrder.order;
        bytes32 hash = hashOrder(o);
        Posted storage p = _postedOrders[hash];
        if (p.status == OrderStatus.NULL) revert ErrOrderNotPosted();
        if (p.status != OrderStatus.POSTED) revert ErrOrderAlreadyFilledOrCancelled();
        if (msg.sender != p.poster && !_isApproved(p.poster, msg.sender)) revert ErrInvalidSigner();
        p.status = OrderStatus.CANCELLED;
        emit OrderCancelled(o.payer, o.instrument, o);
    }

    // -------------------------------------------------------------------------------------------------
    // Operator execution
    // -------------------------------------------------------------------------------------------------

    /// @notice Settle one bid, one ask, or one of each. An empty side is a zero `fillAmount`.
    /// @dev Primary issuance and redemption against the vault, which is the only path Agama uses. The two
    ///      sides are settled independently against NAV rather than crossed against each other, so
    ///      `staticFee` and `spreadFee` are carried and reported but charged on nothing: at a NAV price
    ///      there is no spread to take a cut of. That matches what the partner's staging deployment actually
    ///      did when measured, where a filled bid at 10000 moved no value to their treasury at all.
    function matchOrders(MatchingOrder calldata bidMatch, MatchingOrder calldata askMatch)
        external
        override
        onlyRole(OPERATOR_ROLE)
    {
        if (engineState != EngineState.SETTLING) revert ErrEngineNotInSettling();
        (, bool isEmergency) = IAbfRegistry(registry).getProtocolState();
        if (isEmergency) revert ErrEmergency();

        if (bidMatch.fillAmount > 0) _fillBid(bidMatch);
        if (askMatch.fillAmount > 0) _fillAsk(askMatch);
    }

    function _fillBid(MatchingOrder calldata m) private {
        Order calldata o = m.signedOrder.order;
        if (o.orderType != OrderType.BID) revert ErrInvalidOrderType();
        bytes32 hash = hashOrder(o);
        Posted storage p = _postedOrders[hash];
        if (p.status == OrderStatus.NULL) revert ErrOrderNotPosted();
        if (p.status != OrderStatus.POSTED) revert ErrOrderAlreadyFilledOrCancelled();
        if (o.expiry < block.timestamp) revert ErrExpired();

        // `fillAmount` is the net the operator puts to work at NAV; `amount` was the gross committed. The
        // gross consumed is therefore net scaled by the price, and anything above net is a premium the
        // counterparty paid for no extra shares.
        uint256 net = m.fillAmount;
        if (net > o.amount) revert ErrInvalidFillAmount();
        uint256 gross = (net * o.price) / BIPS_BASE;
        if (gross == 0 || gross > p.remainingAmount) revert ErrInvalidFillAmount();

        address paymentToken = IAbfMasterVault(o.instrument).asset();
        uint256 escrow = tokenBalances[o.payer][paymentToken];
        require(escrow >= gross, "escrow short");
        tokenBalances[o.payer][paymentToken] = escrow - gross;

        require(IERC20(paymentToken).approve(o.instrument, net), "approve failed");
        uint256 shares = IAbfMasterVault(o.instrument).deposit(net, o.receiver);

        uint256 premium = gross - net;
        if (premium > 0) {
            require(IERC20(paymentToken).transfer(_treasury(), premium), "premium transfer failed");
        }

        p.remainingAmount -= gross;
        if (p.remainingAmount == 0) p.status = OrderStatus.FILLED;

        emit OrderFilled(o.instrument, o.payer, address(0), hash, bytes32(0), net, shares, o.price);
    }

    function _fillAsk(MatchingOrder calldata m) private {
        Order calldata o = m.signedOrder.order;
        if (o.orderType != OrderType.ASK) revert ErrInvalidOrderType();
        bytes32 hash = hashOrder(o);
        Posted storage p = _postedOrders[hash];
        if (p.status == OrderStatus.NULL) revert ErrOrderNotPosted();
        if (p.status != OrderStatus.POSTED) revert ErrOrderAlreadyFilledOrCancelled();
        if (o.expiry < block.timestamp) revert ErrExpired();

        uint256 shares = m.fillAmount;
        if (shares == 0 || shares > p.remainingAmount) revert ErrInvalidFillAmount();

        uint256 escrow = tokenBalances[o.payer][o.instrument];
        require(escrow >= shares, "escrow short");
        tokenBalances[o.payer][o.instrument] = escrow - shares;

        address paymentToken = IAbfMasterVault(o.instrument).asset();
        uint256 assets = IAbfMasterVault(o.instrument).redeem(shares, address(this), address(this));

        // Symmetric with the bid: a price below NAV is a discount the seller accepted, and the difference
        // goes the same way a premium does.
        uint256 proceeds = (assets * o.price) / BIPS_BASE;
        if (proceeds > assets) proceeds = assets;
        require(IERC20(paymentToken).transfer(o.receiver, proceeds), "proceeds transfer failed");
        if (assets > proceeds) {
            require(IERC20(paymentToken).transfer(_treasury(), assets - proceeds), "discount transfer failed");
        }

        p.remainingAmount -= shares;
        if (p.remainingAmount == 0) p.status = OrderStatus.FILLED;

        emit OrderFilled(o.instrument, address(0), o.payer, bytes32(0), hash, proceeds, shares, o.price);
    }

    // -------------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------------

    function hashOrder(Order calldata order) public view override returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                uint8(order.orderType),
                order.instrument,
                order.trancheId,
                order.amount,
                order.price,
                order.payer,
                order.receiver,
                order.expiry,
                order.salt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function postedOrders(bytes32 hash)
        external
        view
        override
        returns (address poster, uint40 timestamp, OrderStatus status, uint256 remainingAmount)
    {
        Posted storage p = _postedOrders[hash];
        return (p.poster, p.timestamp, p.status, p.remainingAmount);
    }

    function eip712Domain()
        external
        view
        override
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", _NAME, _VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    // -------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------

    /// @dev The payer, or a signer the payer approved, may post without an off-chain order signature: being
    ///      the caller is the authorisation. Anyone else must present a signature over the order hash by such
    ///      an account. Both paths are the partner's; the first is the one Agama's Safe uses, which is why
    ///      the keeper never needs a signing key for order entry.
    function _authorize(SignedOrder calldata signedOrder, bytes32 hash) private view {
        Order calldata o = signedOrder.order;
        if (msg.sender == o.payer || _isApproved(o.payer, msg.sender)) return;

        address signer = signedOrder.signer;
        if (signer != o.payer && !_isApproved(o.payer, signer)) revert ErrInvalidSigner();
        if (signedOrder.signature.length != 65) revert ErrInvalidSignature();

        bytes memory sig = signedOrder.signature;
        bytes32 r;
        bytes32 s;
        uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (ecrecover(hash, v, r, s) != signer) revert ErrInvalidSignature();
    }

    function _isApproved(address user, address signer) private view returns (bool) {
        return approvedSigners[user][userVersion[user]][signer];
    }

    function _treasury() private view returns (address) {
        address treasury =
            IAbfRegistry(registry).getContractAddress(uint8(IAbfRegistry.ContractType.TREASURY));
        require(treasury != address(0), "no treasury configured");
        return treasury;
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH, keccak256(bytes(_NAME)), keccak256(bytes(_VERSION)), block.chainid, address(this)
            )
        );
    }
}
