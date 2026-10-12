// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfRegistry} from "./IAbfRegistry.sol";
import {IAbfKyc} from "./IAbfKyc.sol";
import {AbfRoles} from "./AbfRoles.sol";

/// @notice Address discovery plus the two global switches every other contract reads before it moves anything.
/// @dev `isKYC` returns a count rather than a bool because the credential is an NFT and an address can hold
///      more than one. Integration code must test `> 0`, never `== 1`.
contract AbfRegistry is IAbfRegistry, AbfRoles {
    mapping(uint8 => address) private _addresses;
    mapping(address => VaultType) public override vaultTypes;
    ProtocolState public override protocolState;

    event ContractAddressSet(uint8 indexed contractType, address indexed contractAddress);
    event VaultTypeSet(address indexed vault, VaultType vaultType);
    event ProtocolStateSet(ProtocolState state);

    constructor(address owner_) AbfRoles(owner_) {}

    function setContractAddress(uint8 contractType, address contractAddress) external onlyOwner {
        _addresses[contractType] = contractAddress;
        emit ContractAddressSet(contractType, contractAddress);
    }

    function setVaultType(address vault, VaultType vaultType) external onlyOwner {
        vaultTypes[vault] = vaultType;
        emit VaultTypeSet(vault, vaultType);
    }

    /// @dev PAUSED stops orders settling; EMERGENCY additionally stops the vault moving assets at all.
    function setProtocolState(ProtocolState state) external onlyRole(STRATEGIC_ROLE) {
        protocolState = state;
        emit ProtocolStateSet(state);
    }

    function getContractAddress(uint8 contractType) external view override returns (address) {
        return _addresses[contractType];
    }

    function isKYC(address account) external view override returns (uint256) {
        address kyc = _addresses[uint8(ContractType.KYC)];
        if (kyc == address(0)) return 0;
        return IAbfKyc(kyc).balanceOf(account);
    }

    function getProtocolState() external view override returns (bool isPaused, bool isEmergency) {
        isPaused = protocolState == ProtocolState.PAUSED;
        isEmergency = protocolState == ProtocolState.EMERGENCY;
    }
}
