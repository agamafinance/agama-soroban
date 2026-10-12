// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAbfRoles} from "./IAbfRoles.sol";

/// @title Fund administrator NAV oracle, integration surface
/// @notice Copied from the ABF partner's published interface. This is the contract that carries the one number
///         Agama cannot verify from Stellar: what the off-chain book is worth. Everything downstream, including
///         how much agUSD a depositor is owed, is a function of it.
/// @dev Staleness is measured in periods, not seconds. Once a feed has entries it is stale when the current
///      period exceeds the recorded period by more than one, so a feed written late in period N is already
///      one period old and goes stale at the end of N+1. A fixed age check in seconds reads as fresh for most
///      of a period that has already lapsed, which is why `getNonStaleLatestFundNav` exists separately.
interface IAbfOracle is IAbfRoles {
    error ErrWeekAlreadyUpdated();
    error ErrStaleData();
    error ErrEmergency();

    event FundNavUpdated(address indexed masterVault, uint64 week, uint256 nav, uint256 logIndex);

    function updateFundNav(address masterVault, uint256 nav) external;
    function getLatestFundNav(address masterVault) external view returns (uint256 nav);
    function getNonStaleLatestFundNav(address masterVault) external view returns (uint256 nav);
    function logCount(address masterVault) external view returns (uint256 count);
    function weeklyFundNav(address masterVault, uint256 index)
        external
        view
        returns (uint64 week, uint64 timestamp, uint256 fundNav);
    function getCurrentWeek() external view returns (uint64 week);
    function WEEK_DURATION() external view returns (uint256 duration);
    function START_TIME() external view returns (uint256 timestamp);
}
