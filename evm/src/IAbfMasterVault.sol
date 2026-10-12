// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Master Vault integration surface
/// @notice Copied from the ABF partner's published integration interface, same reasoning as
///         IAbfMatchingEngine: the error selectors are part of the contract. A caller that catches
///         ErrNotAllowedToDeposit against the replica catches the same four bytes against production.
/// @dev The four disabled entry points are the reason the Matching Engine detour exists at all.
///      `mint` and `withdraw` always revert; `deposit` and `redeem` are callable by the engine only.
///      Nothing can enter or leave this vault without an order the partner's operator settled.
interface IAbfMasterVault {
    error ErrNotAllowedToDeposit();
    error ErrNotAllowedToRedeem();
    error ErrNotPermitted();
    error ErrBlacklisted(address account);
    error ErrEmergency();
    error ErrPaused();
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event CapSet(uint256 cap);
    event RatioSet(uint256 ratio);
    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event MasterVaultFundsAllocated(address indexed vault, address indexed token, uint256 amount);
    event MasterVaultFundsWithdrawn(address indexed vault, address indexed token, uint256 amount);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    function transfer(address to, uint256 value) external returns (bool success);
    function approve(address spender, uint256 value) external returns (bool success);
    function transferFrom(address from, address to, uint256 value) external returns (bool success);

    function name() external view returns (string memory tokenName);
    function symbol() external view returns (string memory tokenSymbol);
    function decimals() external view returns (uint8 shareDecimals);
    function totalSupply() external view returns (uint256 supply);
    function balanceOf(address account) external view returns (uint256 balance);
    function allowance(address owner, address spender) external view returns (uint256 remaining);

    function asset() external view returns (address token);
    function totalAssets() external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 assets);
    function maxMint(address receiver) external view returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256 assets);
    function maxRedeem(address owner) external view returns (uint256 shares);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    function getAvailableAssets() external view returns (uint256 assets);
    function getDisposableAssets() external view returns (uint256 assets);
    function getFundAdminNav() external view returns (uint256 nav);
    function getPrincipalHolding() external view returns (uint256 holding, uint256 totalSent, uint256 totalReceived);
    function cap() external view returns (uint256 assets);
    function ratio() external view returns (uint256 bps);
    function currentRatio() external view returns (uint256 bps);
    function futureRatio(uint256 amount) external view returns (uint256 bps);
    function RATIO_PRECISION() external view returns (uint256 precision);
    function isBlacklisted(address account) external view returns (bool blacklisted);
    function registry() external view returns (address registryAddress);
}
