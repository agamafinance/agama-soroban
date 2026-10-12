// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Protocol registry, integration surface
/// @notice Copied from the ABF partner's published interface. Address discovery plus the two global switches
///         (paused, emergency) that every other contract reads before it moves anything.
interface IAbfRegistry {
    enum ContractType {
        DEAL_VAULT_FACTORY,
        FUNDING_VAULT_FACTORY,
        KYC,
        TREASURY,
        MASTER_VAULT_REGISTRY,
        STATE_MODULE,
        VAULT_FUND_RECEIVERS,
        ORACLE,
        DEAL_VAULT_BOOKBUILD,
        MATCHING_ENGINE,
        RECOVERY
    }

    enum VaultType {
        NONE,
        DEAL_VAULT,
        FUNDING_VAULT,
        MASTER_VAULT
    }

    enum ProtocolState {
        NORMAL,
        PAUSED,
        EMERGENCY
    }

    function getContractAddress(uint8 contractType) external view returns (address contractAddress);
    function isKYC(address account) external view returns (uint256 count);
    function vaultTypes(address vault) external view returns (VaultType vaultType);
    function protocolState() external view returns (ProtocolState state);
    function getProtocolState() external view returns (bool isPaused, bool isEmergency);
}
