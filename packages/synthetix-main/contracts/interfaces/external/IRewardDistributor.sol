// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Interface an aggregator needs to adhere.
interface IRewardDistributor {
    /// called by system
    function payout(
        uint fundId,
        address token,
        address to,
        uint amount
    ) external returns (bool);
}