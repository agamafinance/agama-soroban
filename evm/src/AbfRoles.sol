// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfRoles} from "./IAbfRoles.sol";

/// @notice Role storage shared by the engine, the oracle, the KYC credential and the vault.
/// @dev Deliberately not "the owner can do everything". `owner` may hand out and take back roles and nothing
///      else, which reproduces the one property of the partner's deployment that integration code gets wrong
///      most often: their deployer still shows up as `owner()` but had every operator role revoked after
///      setup, so a fork test that impersonates the owner and expects to be able to settle an order fails.
abstract contract AbfRoles is IAbfRoles {
    bytes32 public constant override OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant override STRATEGIC_ROLE = keccak256("STRATEGIC_ROLE");

    address public override owner;
    mapping(address => mapping(bytes32 => bool)) public override operators;

    error ErrNotOwner();

    modifier onlyRole(bytes32 role) {
        if (!operators[msg.sender][role]) revert ErrNotWithRole(role);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrNotOwner();
        _;
    }

    constructor(address owner_) {
        owner = owner_;
    }

    function setOperator(address account, bytes32 role, bool authorized) external onlyOwner {
        operators[account][role] = authorized;
        emit OperatorSet(account, role, authorized);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
