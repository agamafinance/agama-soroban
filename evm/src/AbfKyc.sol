// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfKyc} from "./IAbfKyc.sol";
import {AbfRoles} from "./AbfRoles.sol";

/// @notice The whitelisting step, as a non transferable credential the partner's operator mints to an address
///         it has diligenced.
/// @dev No `transfer` and no `approve`: there is deliberately no holder-initiated way to move a credential,
///      because the whole value of it is that it names one diligenced counterparty. Only the operator can
///      move one, through freeze and unfreeze, which is the recovery path for a lost key.
contract AbfKyc is IAbfKyc, AbfRoles {
    string public name = "ABF KYC Credential";
    string public symbol = "ABF-KYC";

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) public override balanceOf;
    mapping(uint256 => address) public override frozen;

    constructor(address owner_) AbfRoles(owner_) {}

    function mint(address to, uint256 tokenId) external override onlyRole(OPERATOR_ROLE) {
        if (_owners[tokenId] != address(0) || frozen[tokenId] != address(0)) revert ErrAlreadyMinted();
        _owners[tokenId] = to;
        balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function burn(uint256 tokenId) external override onlyRole(OPERATOR_ROLE) {
        address holder = _owners[tokenId];
        require(holder != address(0), "no such credential");
        _owners[tokenId] = address(0);
        balanceOf[holder] -= 1;
        emit Transfer(holder, address(0), tokenId);
    }

    /// @dev Freezing takes the credential out of circulation without destroying the diligence behind it: the
    ///      holder stops counting as KYC immediately, and `unfreeze` reissues to a new address.
    function freeze(uint256 tokenId) external override onlyRole(OPERATOR_ROLE) {
        address holder = _owners[tokenId];
        require(holder != address(0), "no such credential");
        _owners[tokenId] = address(0);
        balanceOf[holder] -= 1;
        frozen[tokenId] = holder;
        emit Frozen(tokenId);
    }

    function unfreeze(uint256 tokenId, address newUser) external override onlyRole(OPERATOR_ROLE) {
        if (frozen[tokenId] == address(0)) revert ErrFrozen(tokenId);
        frozen[tokenId] = address(0);
        _owners[tokenId] = newUser;
        balanceOf[newUser] += 1;
        emit Unfrozen(tokenId, newUser);
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        return _owners[tokenId];
    }
}
