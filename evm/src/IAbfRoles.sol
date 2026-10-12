// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Role surface shared by the Matching Engine, the oracle and the KYC credential
/// @notice `operators(account, role)` rather than ownership is what grants the right to act. The partner's
///         integration notes are explicit that ownership alone grants nothing, because their deployer's
///         temporary roles were revoked after setup. Checking `owner()` and concluding you may call something
///         is the mistake this separation exists to prevent.
interface IAbfRoles {
    error ErrNotWithRole(bytes32 role);

    event OperatorSet(address indexed account, bytes32 indexed role, bool authorized);

    function OPERATOR_ROLE() external view returns (bytes32 role);
    function STRATEGIC_ROLE() external view returns (bytes32 role);
    function owner() external view returns (address account);
    function operators(address account, bytes32 role) external view returns (bool authorized);
}
