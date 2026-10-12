// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfMasterVault} from "./IAbfMasterVault.sol";
import {IAbfRegistry} from "./IAbfRegistry.sol";
import {IAbfOracle} from "./IAbfOracle.sol";
import {IERC20} from "./IERC20.sol";
import {AbfRoles} from "./AbfRoles.sol";

/// @title The share token Agama holds against its off-chain book
/// @notice Accepts USDC, issues shares, and reports a value per share that rises as the fund administrator
///         reports a higher NAV. The partner's production vault takes Agora AUSD; this one takes real Sepolia
///         USDC, which is the single intentional divergence and it removes a hop rather than adding one:
///         CCTP delivers USDC, so with USDC as the asset the bridged amount is depositable as it arrives,
///         with nothing in between that has to be priced.
/// @dev Four entry points are closed and that is the entire architecture. `mint` and `withdraw` always revert.
///      `deposit` and `redeem` are callable by the Matching Engine alone. So no amount of share allowance or
///      asset approval lets anybody enter or leave except through an order the partner's operator settled,
///      which is what makes a share a claim on a diligenced book rather than on a pool.
contract AbfMasterVault is IAbfMasterVault, AbfRoles {
    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    address public immutable override asset;
    address public immutable override registry;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    uint256 public override cap;
    uint256 public override ratio;
    mapping(address => bool) public override isBlacklisted;

    uint256 public constant override RATIO_PRECISION = 10_000;

    constructor(
        address owner_,
        address registry_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        uint256 ratio_
    ) AbfRoles(owner_) {
        registry = registry_;
        asset = asset_;
        name = name_;
        symbol = symbol_;
        // Share precision follows the asset with no offset, as the partner's does. Reading it rather than
        // assuming six is the difference between a correct integration and one that is wrong by 10^n.
        decimals = IERC20(asset_).decimals();
        cap = cap_;
        ratio = ratio_;
    }

    // -------------------------------------------------------------------------------------------------
    // The closed entry points
    // -------------------------------------------------------------------------------------------------

    function mint(uint256, address) external pure override returns (uint256) {
        revert ErrNotPermitted();
    }

    function withdraw(uint256, address, address) external pure override returns (uint256) {
        revert ErrNotPermitted();
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        if (msg.sender != _engine()) revert ErrNotAllowedToDeposit();
        _requireOperational();
        uint256 max = _maxDeposit();
        if (assets > max) revert ERC4626ExceededMaxDeposit(receiver, assets, max);

        // Shares are priced off the valuation as it stands before the assets arrive. Pulling first would
        // count the incoming assets in the denominator and mint the depositor fewer shares than they paid
        // for, with the difference accruing to the holders already in the vault.
        shares = _convertToShares(assets);
        require(IERC20(asset).transferFrom(msg.sender, address(this), assets), "asset transfer failed");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external override returns (uint256 assets) {
        if (msg.sender != _engine()) revert ErrNotAllowedToRedeem();
        _requireOperational();
        uint256 max = balanceOf[owner_];
        if (shares > max) revert ERC4626ExceededMaxRedeem(owner_, shares, max);

        assets = _convertToAssets(shares);
        // Honest failure rather than a partial payout. The vault can owe more than it holds whenever capital
        // is out with the fund administrator, and the fix for that is `returnFromFund`, not shortchanging
        // the redeemer.
        require(IERC20(asset).balanceOf(address(this)) >= assets, "not enough liquid assets");
        _burn(owner_, shares);
        require(IERC20(asset).transfer(receiver, assets), "asset transfer failed");
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // -------------------------------------------------------------------------------------------------
    // Fund administrator movements
    // -------------------------------------------------------------------------------------------------

    /// @notice Send cash out to the fund administrator's receiver, which is where the yield is actually earned.
    /// @dev Note what this does to `totalAssets` on its own: cash leaves and nothing replaces it, so the
    ///      valuation drops until the oracle is told the book now holds the money. The two steps being
    ///      separate is the real behaviour, not a simplification, and it is why a NAV feed going stale is a
    ///      solvency question and not a cosmetic one.
    function allocateToFund(uint256 amount) external onlyRole(STRATEGIC_ROLE) {
        _requireOperational();
        uint256 projected = futureRatio(amount);
        require(projected <= ratio, "allocation would exceed the off-chain ratio");
        address receiver = IAbfRegistry(registry).getContractAddress(
            uint8(IAbfRegistry.ContractType.VAULT_FUND_RECEIVERS)
        );
        require(receiver != address(0), "no fund receiver configured");
        require(IERC20(asset).transfer(receiver, amount), "asset transfer failed");
        emit MasterVaultFundsAllocated(address(this), asset, amount);
    }

    /// @notice Pull cash back in from the fund administrator's receiver, which is how yield becomes payable.
    /// @dev A NAV the oracle has raised is a claim; this is the step that makes it money a redeemer can be
    ///      paid in. The receiver must have approved this vault.
    function returnFromFund(uint256 amount) external onlyRole(STRATEGIC_ROLE) {
        address receiver = IAbfRegistry(registry).getContractAddress(
            uint8(IAbfRegistry.ContractType.VAULT_FUND_RECEIVERS)
        );
        require(receiver != address(0), "no fund receiver configured");
        require(IERC20(asset).transferFrom(receiver, address(this), amount), "asset transfer failed");
        emit MasterVaultFundsWithdrawn(address(this), asset, amount);
    }

    function setCap(uint256 cap_) external onlyRole(STRATEGIC_ROLE) {
        cap = cap_;
        emit CapSet(cap_);
    }

    function setRatio(uint256 ratio_) external onlyRole(STRATEGIC_ROLE) {
        require(ratio_ <= RATIO_PRECISION, "ratio above precision");
        ratio = ratio_;
        emit RatioSet(ratio_);
    }

    function blacklist(address account) external onlyRole(OPERATOR_ROLE) {
        isBlacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyRole(OPERATOR_ROLE) {
        isBlacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // -------------------------------------------------------------------------------------------------
    // Valuation
    // -------------------------------------------------------------------------------------------------

    /// @dev Cash on the vault plus the administrator's reported NAV. `getFundAdminNav` is already counted
    ///      here, so adding it again downstream double counts the off-chain book.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + getFundAdminNav();
    }

    function getAvailableAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function getDisposableAssets() external view override returns (uint256) {
        // No money market sleeve in the replica, so this is cash. Kept as its own function because the
        // partner's accounting distinguishes it and integration code reads it.
        return getAvailableAssets();
    }

    function getFundAdminNav() public view override returns (uint256) {
        address oracle = IAbfRegistry(registry).getContractAddress(uint8(IAbfRegistry.ContractType.ORACLE));
        if (oracle == address(0)) return 0;
        return IAbfOracle(oracle).getLatestFundNav(address(this));
    }

    function getPrincipalHolding() external pure override returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets);
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares);
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares);
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return _mulDivUp(shares, totalAssets(), totalSupply);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return _mulDivUp(assets, totalSupply, totalAssets());
    }

    function maxDeposit(address) external view override returns (uint256) {
        return _maxDeposit();
    }

    function maxMint(address) external view override returns (uint256) {
        return _convertToShares(_maxDeposit());
    }

    function maxWithdraw(address owner_) external view override returns (uint256) {
        return _convertToAssets(balanceOf[owner_]);
    }

    function maxRedeem(address owner_) external view override returns (uint256) {
        return balanceOf[owner_];
    }

    function currentRatio() external view override returns (uint256) {
        uint256 ta = totalAssets();
        if (ta == 0) return 0;
        return (getFundAdminNav() * RATIO_PRECISION) / ta;
    }

    function futureRatio(uint256 amount) public view override returns (uint256) {
        uint256 ta = totalAssets();
        if (ta == 0) return 0;
        return ((getFundAdminNav() + amount) * RATIO_PRECISION) / ta;
    }

    // -------------------------------------------------------------------------------------------------
    // ERC-20
    // -------------------------------------------------------------------------------------------------

    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "insufficient allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    // -------------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------------

    function _engine() private view returns (address) {
        return IAbfRegistry(registry).getContractAddress(uint8(IAbfRegistry.ContractType.MATCHING_ENGINE));
    }

    function _requireOperational() private view {
        (bool isPaused, bool isEmergency) = IAbfRegistry(registry).getProtocolState();
        if (isEmergency) revert ErrEmergency();
        if (isPaused) revert ErrPaused();
    }

    function _maxDeposit() private view returns (uint256) {
        uint256 ta = totalAssets();
        return cap > ta ? cap - ta : 0;
    }

    /// @dev First deposit is one share per asset unit. Afterwards shares track the valuation, rounding down,
    ///      so rounding dust is left to the vault and never minted to the depositor.
    function _convertToShares(uint256 assets) private view returns (uint256) {
        uint256 ts = totalSupply;
        if (ts == 0) return assets;
        uint256 ta = totalAssets();
        if (ta == 0) return 0;
        return (assets * ts) / ta;
    }

    function _convertToAssets(uint256 shares) private view returns (uint256) {
        uint256 ts = totalSupply;
        if (ts == 0) return shares;
        return (shares * totalAssets()) / ts;
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        if (d == 0) return a;
        return (a * b + d - 1) / d;
    }

    function _mint(address to, uint256 value) private {
        _requireNotBlacklisted(to);
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        _requireNotBlacklisted(from);
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) private {
        _requireNotBlacklisted(from);
        _requireNotBlacklisted(to);
        require(balanceOf[from] >= value, "insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _requireNotBlacklisted(address account) private view {
        if (isBlacklisted[account]) revert ErrBlacklisted(account);
    }
}
