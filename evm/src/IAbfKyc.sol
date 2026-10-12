// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfRoles} from "./IAbfRoles.sol";

/// @title KYC credential, integration surface
/// @notice Copied from the ABF partner's published interface. A non transferable credential minted by the
///         partner's own operator to an address they have diligenced. This is the whitelisting step: Agama's
///         Safe holds the credential, the depositor on Stellar never does and never needs to.
interface IAbfKyc is IAbfRoles {
    error ErrAlreadyMinted();
    error ErrFrozen(uint256 tokenId);

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Frozen(uint256 indexed tokenId);
    event Unfrozen(uint256 indexed tokenId, address indexed newUser);

    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function freeze(uint256 tokenId) external;
    function unfreeze(uint256 tokenId, address newUser) external;
    function balanceOf(address account) external view returns (uint256 balance);
    function ownerOf(uint256 tokenId) external view returns (address account);
    function frozen(uint256 tokenId) external view returns (address account);
}
