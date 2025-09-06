//libraries/VotingLib.sol
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
        if (tokenUnlockTime[voter] > block.timestamp) revert Errors.TokensAlreadyLocked();
        if (getVotesFunc(voter) == 0) revert Errors.NoVotingPower();
        tokenUnlockTime[voter] = block.timestamp + tokenLockDuration;
        recentVoteTimestamps[voter] = block.timestamp;
    }

    /**
     * @notice Convert a voter's snapshot voting power into a USDT (6d) vote value.
     * @dev Uses getPastVotes at block.number - 1 to snapshot at the voting block and
     *      caps the result at 10% of the fundingAmount.
     * @param getPastVotesFunc Function to read past votes (ERC20Votes interface).
     * @param price Latest oracle price with 18 decimals.
     * @param voter Address whose voting power is evaluated.
     * @param fundingAmount Soft cap amount of the funding request in USDT (6d).
     * @return value The clamped voting value in USDT (6d).
     */
    function getVotingValueByVotes(
        function(address, uint256) view returns (uint256) getPastVotesFunc,
        int price,
        address voter,
        uint256 fundingAmount
    ) internal view returns (uint256 value) {
        uint256 vp = getPastVotesFunc(voter, block.number - 1);
        uint256 invValueUsd = (vp * uint256(price)) / 1e30; // USD(6)
        value = (invValueUsd * 5) / 1000; // 0.5% of holdings (USD6)
        uint256 maxValue = fundingAmount / 10; // 10% cap of request.amount (USD6)
        if (value > maxValue) value = maxValue;
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
        if (voter == address(0)) revert Errors.InvalidTokenHolder();
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
