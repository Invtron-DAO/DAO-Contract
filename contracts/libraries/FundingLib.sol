//libraries/FundingLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ProposalLib.sol";
import "./EventLib.sol";
import "./Errors.sol";
import "../InvUsdToken.sol";

library FundingLib {
    using ProposalLib for ProposalLib.ProposalStatus;

    struct FundingDetails {
        string projectName;
        uint256 softCapAmount;
        uint256 hardCapAmount;
        uint256 valuation;
        string country;
        string websiteUrl;
        string ceoLinkedInUrl;
        string shortDescription;
        string companyRegistrationUrl;
    }

    struct FundingRequest {
        address proposer;
        FundingDetails details;
        uint256 amount;
        uint256 deadline;
        ProposalLib.ProposalStatus status;
        uint256 endorserVotes;
        uint256 userVotesFor;
        uint256 userVotesAgainst;
        bool ceoApproved;
    }

    struct State {
        uint256 nextFundingRequestId;
        mapping(uint256 => FundingRequest) fundingRequests;
    }

    function createFundingRequest(
        State storage state,
        address proposer,
        FundingDetails calldata details,
        uint256 votingPeriod
    ) internal returns (uint256 id) {
        id = state.nextFundingRequestId++;
        FundingRequest storage req = state.fundingRequests[id];
        req.proposer = proposer;
        req.details = details;
        req.amount = details.softCapAmount;
        req.deadline = block.timestamp + votingPeriod;
        req.status = ProposalLib.ProposalStatus.Pending;
        emit EventLib.FundingRequestCreated(
            id,
            proposer,
            details.projectName,
            details.softCapAmount,
            details.hardCapAmount
        );
    }

    function releaseFundingRequest(State storage state, uint256 id) internal {
        FundingRequest storage req = state.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActive();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        if (req.userVotesFor <= req.userVotesAgainst) revert Errors.FundingProposalFailed();
        if (req.ceoApproved) revert Errors.FundingRequestAlreadyApproved();
        req.ceoApproved = true;
        emit EventLib.FundingRequestApproved(id);
        emit EventLib.ProposalStatusUpdated(id, uint8(req.status));
    }

    function mintTokensForFundingRequest(
        State storage state,
        InvUsdToken token,
        mapping(uint256 => uint256) storage remainingToExchange,
        uint256 id
    ) internal returns (uint256 mintAmount) {
        FundingRequest storage req = state.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActiveExecution();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActiveExecution();
        if (req.userVotesFor <= req.userVotesAgainst) revert Errors.FundingProposalFailed();
        if (!req.ceoApproved) revert Errors.FundingRequestNotApproved();
        req.status = ProposalLib.ProposalStatus.Executed;
        mintAmount = req.amount * 1e12;
        token.mint(req.proposer, mintAmount);
        remainingToExchange[id] = mintAmount;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Executed));
    }
}
