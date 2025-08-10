// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./Errors.sol";

library VotingLib {
    function castVote(
        mapping(address => uint256) storage tokenUnlockTime,
        mapping(address => uint256) storage recentVoteTimestamps,
        function(address) view returns (uint256) getVotesFunc,
        uint256 tokenLockDuration,
        address voter
    ) internal {
        if (getVotesFunc(voter) == 0) revert Errors.NoVotingPower();
        if (block.timestamp < tokenUnlockTime[voter]) revert Errors.TokensLocked();
        tokenUnlockTime[voter] = block.timestamp + tokenLockDuration;
        recentVoteTimestamps[voter] = block.timestamp;
    }

    function getVotingValue(
        function(address) view returns (uint256) balanceOfFunc,
        function() view returns (int) getLatestPriceFunc,
        address voter,
        uint256 fundingAmount
    ) internal view returns (uint256) {
        int price = getLatestPriceFunc();
        uint256 invValue = (balanceOfFunc(voter) * uint256(price)) / 1e18;
        uint256 value = (invValue * 5) / 1000; // 0.5%
        uint256 maxValue = fundingAmount / 100; // 1%
        if (value > maxValue) {
            value = maxValue;
        }
        return value;
    }

    function findLowestActiveEndorser(
        address[] storage activeList,
        function(address) view returns (uint256) getVotesFunc
    ) internal view returns (address lowest) {
        if (activeList.length == 0) {
            return address(0);
        }
        lowest = activeList[0];
        uint256 lowestVotes = getVotesFunc(lowest);
        for (uint256 i = 1; i < activeList.length; i++) {
            address current = activeList[i];
            uint256 votes = getVotesFunc(current);
            if (votes < lowestVotes) {
                lowestVotes = votes;
                lowest = current;
            }
        }
    }

    function prepareDelegatedVote(
        mapping(address => address) storage delegateMap,
        mapping(address => uint256) storage tokenUnlockTime,
        mapping(address => uint256) storage recentVoteTimestamps,
        function(address) view returns (uint256) getVotesFunc,
        uint256 tokenLockDuration,
        address sender,
        address tokenHolder
    ) internal returns (address voter, uint256 power) {
        voter = tokenHolder;
        if (voter != sender) {
            if (delegateMap[voter] != sender) revert Errors.NotAuthorizedDelegate();
        }
        castVote(
            tokenUnlockTime,
            recentVoteTimestamps,
            getVotesFunc,
            tokenLockDuration,
            voter
        );
        power = getVotesFunc(voter);
    }
}
