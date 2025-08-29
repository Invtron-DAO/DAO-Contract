//libraries/EndorserLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VotingLib.sol";
import "./Errors.sol";

library EndorserLib {
    using VotingLib for address[];

    struct PersonalInfo {
        string firstName;
        string lastName;
        string mobile;
        string zipCode;
        string city;
        string state;
        string country;
        string bio;
    }

    struct EndorserCandidate {
        bool registered;
        bool active;
        PersonalInfo info;
    }

    event EndorserCandidateRegistered(address indexed candidate);
    event EndorserVoteChanged(address indexed voter, address indexed candidate, uint256 weight);
    event EndorserChallengeSuccess(address indexed candidate, address indexed replaced);

    function registerCandidate(
        mapping(address => EndorserCandidate) storage candidates,
        address candidateAddr,
        PersonalInfo memory info
    ) internal {
        if (candidates[candidateAddr].registered) revert Errors.AlreadyRegistered();
        EndorserCandidate storage cand = candidates[candidateAddr];
        cand.registered = true;
        cand.info = info;
        emit EndorserCandidateRegistered(candidateAddr);
    }

    function voteForCandidate(
        mapping(address => EndorserCandidate) storage candidates,
        mapping(address => address) storage votes,
        address[] storage activeList,
        address voter,
        address candidate,
        function(address) view returns (uint256) getVotes
    ) internal returns (uint256 weight, address newLowest) {
        if (!candidates[candidate].registered) revert Errors.CandidateNotRegistered();
        weight = getVotes(voter);
        if (weight == 0) revert Errors.NoVotingPower();

        votes[voter] = candidate;
        newLowest = VotingLib.findLowestActiveEndorser(activeList, getVotes);
    }

    function challengeCandidate(
        mapping(address => EndorserCandidate) storage candidates,
        address[] storage activeList,
        address candidate,
        uint256 maxActive,
        function(address) view returns (uint256) getVotes
    ) internal returns (address replaced, address newLowest) {
        if (!candidates[candidate].registered) revert Errors.CandidateNotRegistered();
        if (candidates[candidate].active) revert Errors.CandidateAlreadyActive();

        if (activeList.length < maxActive) {
            activeList.push(candidate);
            candidates[candidate].active = true;
            newLowest = VotingLib.findLowestActiveEndorser(activeList, getVotes);
            emit EndorserChallengeSuccess(candidate, address(0));
            return (address(0), newLowest);
        }

        address weakest = VotingLib.findLowestActiveEndorser(activeList, getVotes);
        if (getVotes(candidate) <= getVotes(weakest)) revert Errors.NotEnoughVotes();

        for (uint256 i = 0; i < activeList.length; i++) {
            if (activeList[i] == weakest) {
                activeList[i] = candidate;
                break;
            }
        }
        candidates[weakest].active = false;
        candidates[candidate].active = true;
        newLowest = VotingLib.findLowestActiveEndorser(activeList, getVotes);
        emit EndorserChallengeSuccess(candidate, weakest);
        return (weakest, newLowest);
    }
}

