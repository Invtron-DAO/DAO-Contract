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
        address voter,
        address candidate,
        function(address) view returns (uint256) weightOf,
        mapping(address => uint256) storage supportByCandidate,
        mapping(address => uint256) storage lastVoterWeight
    ) internal returns (uint256 weight) {
        if (!candidates[candidate].registered) revert Errors.CandidateNotRegistered();
        weight = weightOf(voter);
        if (weight == 0) revert Errors.NoVotingPower();

        address prev = votes[voter];
        uint256 prevW = lastVoterWeight[voter];
        if (prev != address(0) && prevW != 0) {
            uint256 prevSupport = supportByCandidate[prev];
            supportByCandidate[prev] = prevSupport >= prevW ? (prevSupport - prevW) : 0;
        }

        votes[voter] = candidate;
        lastVoterWeight[voter] = weight;
        supportByCandidate[candidate] += weight;
    }

    function challengeCandidate(
        mapping(address => EndorserCandidate) storage candidates,
        address[] storage activeList,
        address candidate,
        uint256 maxActive,
        mapping(address => uint256) storage supportByCandidate
    ) internal returns (address replaced) {
        if (!candidates[candidate].registered) revert Errors.CandidateNotRegistered();
        if (candidates[candidate].active) revert Errors.CandidateAlreadyActive();

        if (activeList.length < maxActive) {
            activeList.push(candidate);
            candidates[candidate].active = true;
            emit EndorserChallengeSuccess(candidate, address(0));
            return (address(0));
        }

        address weakest = activeList[0];
        uint256 weakestVotes = supportByCandidate[weakest];
        for (uint256 i = 1; i < activeList.length; i++) {
            address current = activeList[i];
            uint256 votes = supportByCandidate[current];
            if (votes < weakestVotes) {
                weakestVotes = votes;
                weakest = current;
            }
        }
        if (supportByCandidate[candidate] <= supportByCandidate[weakest]) revert Errors.NotEnoughVotes();

        for (uint256 i = 0; i < activeList.length; i++) {
            if (activeList[i] == weakest) {
                activeList[i] = candidate;
                break;
            }
        }
        candidates[weakest].active = false;
        candidates[candidate].active = true;
        emit EndorserChallengeSuccess(candidate, weakest);
        return (weakest);
    }
}
