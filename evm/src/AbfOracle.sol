// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfOracle} from "./IAbfOracle.sol";
import {IAbfRegistry} from "./IAbfRegistry.sol";
import {AbfRoles} from "./AbfRoles.sol";

/// @notice The fund administrator's NAV, on chain, one entry per period.
/// @dev This contract carries the one number Agama cannot check from Stellar: what the off-chain book is
///      worth. It is reported, not computed, and it is reported by the partner's own operator. Agama's side
///      answers that with a 2-of-N quorum on its own oracle before the figure is allowed to move agUSD, which
///      is the only honest response to a feed you do not control.
///
///      Staleness is counted in periods, not seconds. A feed written late in period N is already one period
///      old, so it expires at the end of N+1. An age check in seconds would read as fresh for most of a
///      period that has already lapsed, which is why `getLatestFundNav` and `getNonStaleLatestFundNav` are
///      two different functions rather than one with a tolerance.
contract AbfOracle is IAbfOracle, AbfRoles {
    struct Entry {
        uint64 week;
        uint64 timestamp;
        uint256 fundNav;
    }

    uint256 public immutable override WEEK_DURATION;
    uint256 public immutable override START_TIME;
    address public immutable registry;

    mapping(address => Entry[]) private _fundNav;

    constructor(address owner_, address registry_, uint256 weekDuration, uint256 startTime) AbfRoles(owner_) {
        require(weekDuration > 0, "period must be nonzero");
        registry = registry_;
        WEEK_DURATION = weekDuration;
        START_TIME = startTime;
    }

    function updateFundNav(address masterVault, uint256 nav) external override onlyRole(OPERATOR_ROLE) {
        (, bool isEmergency) = IAbfRegistry(registry).getProtocolState();
        if (isEmergency) revert ErrEmergency();

        Entry[] storage log = _fundNav[masterVault];
        uint64 week = _currentWeek();
        // One update per feed per period. Two valuations inside one period would make the second silently
        // authoritative with nothing recording that the first existed, so the second is refused instead.
        if (log.length > 0 && log[log.length - 1].week == week) revert ErrWeekAlreadyUpdated();

        log.push(Entry({week: week, timestamp: uint64(block.timestamp), fundNav: nav}));
        emit FundNavUpdated(masterVault, week, nav, log.length - 1);
    }

    function getLatestFundNav(address masterVault) external view override returns (uint256) {
        Entry[] storage log = _fundNav[masterVault];
        // A vault with no entries reads as zero rather than reverting. That is the partner's behaviour and it
        // matters: a cash-only vault that has never been valued is worth exactly its cash, not undefined.
        if (log.length == 0) return 0;
        return log[log.length - 1].fundNav;
    }

    function getNonStaleLatestFundNav(address masterVault) external view override returns (uint256) {
        Entry[] storage log = _fundNav[masterVault];
        if (log.length == 0) return 0;
        Entry storage last = log[log.length - 1];
        if (_currentWeek() > last.week + 1) revert ErrStaleData();
        return last.fundNav;
    }

    function logCount(address masterVault) external view override returns (uint256) {
        return _fundNav[masterVault].length;
    }

    function weeklyFundNav(address masterVault, uint256 index)
        external
        view
        override
        returns (uint64 week, uint64 timestamp, uint256 fundNav)
    {
        Entry storage e = _fundNav[masterVault][index];
        return (e.week, e.timestamp, e.fundNav);
    }

    function getCurrentWeek() external view override returns (uint64) {
        return _currentWeek();
    }

    function _currentWeek() private view returns (uint64) {
        if (block.timestamp < START_TIME) return 0;
        return uint64((block.timestamp - START_TIME) / WEEK_DURATION);
    }
}
