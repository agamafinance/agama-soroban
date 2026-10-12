// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfRoles} from "./IAbfRoles.sol";

/// @title Matching Engine integration surface
/// @notice Every struct, enum, error, event and selector here is a verbatim copy of the integration interface the
///         ABF partner publishes for its own Matching Engine. The names are theirs; only the brand is left out,
///         because this repository is public and the partner is referred to by role rather than by name
///         everywhere else in it too.
/// @dev This is the whole point of the replica. Agama's keeper, its Zodiac Roles permission set and its test
///      helpers are written against these signatures, so anything that passes here is calldata the production
///      counterparty would also accept. A replica that drifted from this surface would prove nothing: it would
///      exercise our code against a shape the real engine does not have.
interface IAbfMatchingEngine is IAbfRoles {
    error ErrPaymentTokenNotAccepted();
    error ErrInvalidERC3009Data();
    error ErrOrderAlreadyPosted();
    error ErrInvalidInstrument();
    error ErrInvalidPrice();
    error ErrInvalidSigner();
    error ErrInvalidSignature();
    error ErrExpired();
    error ErrOrderNotPosted();
    error ErrEngineNotInPreWindow();
    error ErrEngineNotInSettling();
    error ErrOrderMismatch();
    error ErrInvalidOrderType();
    error ErrOrderAlreadyFilledOrCancelled();
    error ErrNotWhitelisted();
    error ErrInvalidFillAmount();
    error ErrInvalidOrderSize();
    error ErrNotKYC();
    error ErrEmergency();

    enum EngineState {
        NULL,
        PRE_WINDOW,
        SETTLING
    }

    enum OrderType {
        BID,
        ASK
    }

    enum OrderStatus {
        NULL,
        POSTED,
        FILLED,
        CANCELLED
    }

    struct ERC3009Data {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        bytes signature;
    }

    struct Order {
        OrderType orderType;
        address instrument;
        uint256 trancheId;
        uint256 amount;
        uint256 price;
        address payer;
        address receiver;
        uint256 expiry;
        bytes32 salt;
    }

    struct SignedOrder {
        Order order;
        ERC3009Data erc3009Data;
        address signer;
        bytes signature;
    }

    struct MatchingOrder {
        SignedOrder signedOrder;
        uint256 fillAmount;
    }

    event OrderPosted(address indexed payer, address indexed instrument, bytes32 hash, Order order);
    event OrderCancelled(address indexed payer, address indexed instrument, Order order);
    event OrderFilled(
        address indexed instrument,
        address indexed bidder,
        address indexed asker,
        bytes32 bidHash,
        bytes32 askHash,
        uint256 assets,
        uint256 shares,
        uint256 price
    );
    event TokenWithdrawn(address indexed user, address indexed paymentToken, uint256 amount);
    event UserVersionIncremented(address indexed user);
    event ApprovedSignerSet(address indexed user, address indexed signer, bool approved);
    event EngineStateSet(EngineState engineState);
    event FeesUpdated(uint256 staticFee, uint256 spreadFee);
    event MinOrderSizeSet(address indexed key1, address indexed key2, uint256 minOrderSize);
    event PaymentTokenSet(address indexed paymentToken, bool approved);

    function setEngineState() external;
    function incrementUserVersion() external;
    function setApprovedSigner(address signer, bool approved) external;
    function depositToken(address paymentToken, uint256 amount, ERC3009Data calldata erc3009Data) external;
    function withdrawToken(address paymentToken, uint256 amount) external;
    function postOrder(SignedOrder calldata signedOrder, bool deposit) external returns (bytes32 hash);
    function cancelOrder(SignedOrder calldata signedOrder) external;
    function matchOrders(MatchingOrder calldata bidMatch, MatchingOrder calldata askMatch) external;

    function hashOrder(Order calldata order) external view returns (bytes32 hash);
    function postedOrders(bytes32 hash)
        external
        view
        returns (address poster, uint40 timestamp, OrderStatus status, uint256 remainingAmount);
    function engineState() external view returns (EngineState state);
    function tokenBalances(address user, address token) external view returns (uint256 balance);
    function userVersion(address user) external view returns (uint256 version);
    function approvedSigners(address user, uint256 version, address signer) external view returns (bool approved);
    function minOrderSize(address wantedToken, address offeredToken) external view returns (uint256 amount);
    function isWhitelisted(address user) external view returns (bool approved);
    function paymentTokensAccepted(address token) external view returns (bool accepted);
    function erc3009Support(address token) external view returns (bool supported);
    function staticFee() external view returns (uint256 fee);
    function spreadFee() external view returns (uint256 fee);
    function BIPS_BASE() external view returns (uint256 base);
    function ORDER_TYPEHASH() external view returns (bytes32 typeHash);
    function registry() external view returns (address registryAddress);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}
