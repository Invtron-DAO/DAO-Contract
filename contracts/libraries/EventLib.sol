//libraries/EventLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library EventLib {
    event Whitelisted(address indexed user);
    event CeoApplicationCreated(uint256 id, address applicant);
    event FundingRequestCreated(
        uint256 id,
        address proposer,
        string projectName,
        uint256 softCapAmount,
        uint256 hardCapAmount
    );
    event Voted(uint256 id, address voter, bool inFavor, uint256 votingPower);
    event ProposalStatusUpdated(uint256 id, uint8 status);
    event Exchanged(address indexed user, uint256 invUsdAmount, uint256 invAmount);
    event RewardClaimed(address indexed voter, uint256 amount);
    event DailyLimitSet(uint256 indexed requestId, uint256 newLimit);
    event FundingRequestApproved(uint256 indexed id);
    event TotalUnswappedUpdated(uint256 previousAmount, uint256 newAmount);
    event CeoChanged(address indexed previousCeo, address indexed newCeo);
    event PriceFeedUpdated(address indexed newFeed, int256 newPrice);
}
