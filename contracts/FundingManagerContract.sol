// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/ProposalLib.sol";
import "./libraries/EventLib.sol";
import "./libraries/Errors.sol";
import "./libraries/FundingLib.sol";
import "./WhitelistManager.sol";
import "./interfaces/IInvtronDao.sol";

/**
 * @title FundingManagerContract
 * @notice Standalone manager for funding requests, connected to INVTRON_DAO similar to WhitelistManager.
 * @dev Holds funding state and voting-specific storage; calls back into DAO for locks, pricing and mints.
 */
contract FundingManagerContract {
    using FundingLib for FundingLib.State;

    // --- DAO wiring ---
    address public dao;

    // --- Config ---
    uint256 public constant VOTING_PERIOD = 72 hours;
    uint256 public constant ENDORSER_VOTES_FOR_FUNDING_PASS = 3; // adjust on mainnet if needed

    // --- Core State ---
    FundingLib.State internal _fundingState;

    // --- Vote tracking state (funding-specific) ---
    mapping(uint256 => mapping(address => bool)) public fundingEndorsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUserVoteChoice;
    mapping(uint256 => mapping(address => uint256)) public votingPowerAtVote;     // USD(6) base portion
    mapping(uint256 => mapping(address => uint256)) public delegateePowerAtVote;  // USD(6) delegated portion
    mapping(uint256 => mapping(address => address)) public delegateAtVote;
    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    // --- One-time DAO setter ---
    function setDao(address _dao) external {
        if (dao != address(0)) revert Errors.DaoAlreadySet();
        if (_dao == address(0)) revert Errors.DaoAddressZero();
        dao = _dao;
    }

    // --- Internal guards ---
    function _onlyCeo() internal view {
        IInvtronDao d = IInvtronDao(dao);
        if (!d.hasRole(d.CEO_ROLE(), msg.sender)) revert Errors.OnlyCeo();
    }

    function _onlyEndorser() internal view {
        IInvtronDao d = IInvtronDao(dao);
        if (!d.hasRole(d.ENDORSER_ROLE(), msg.sender)) revert Errors.OnlyEndorser();
    }

    function _onlyWhitelisted(address user) internal view {
        address wl = IInvtronDao(dao).whitelistManager();
        if (!WhitelistManager(wl).isWhitelisted(user)) revert Errors.NotWhitelisted();
    }

    // --- Views ---
    function nextFundingRequestId() external view returns (uint256) {
        return _fundingState.nextFundingRequestId;
    }

    function fundingRequests(uint256 id)
        external
        view
        returns (FundingLib.FundingRequest memory)
    {
        return _fundingState.fundingRequests[id];
    }

    function fundingStatus(uint256 id) external view returns (uint8) {
        return uint8(_fundingState.fundingRequests[id].status);
    }

    function fundingAmount(uint256 id) external view returns (uint256) {
        return _fundingState.fundingRequests[id].amount;
    }

    function proposerOf(uint256 id) external view returns (address) {
        return _fundingState.fundingRequests[id].proposer;
    }

    // --- Funding lifecycle ---

    /// @notice Propose a new funding request with caps expressed in USDT(6d).
    function createFundingRequest(FundingLib.FundingDetails calldata details) external {
        _onlyWhitelisted(msg.sender);
        if (
            details.softCapAmount == 0 ||
            details.hardCapAmount == 0 ||
            details.softCapAmount > details.hardCapAmount
        ) {
            revert Errors.InvalidFundingCaps();
        }
        if (details.valuation == 0) revert Errors.InvalidValuation();

        // Collect funding request fee in INV (uses DAO to pull allowance and transfer to treasury)
        int p = IInvtronDao(dao).getLatestUsdPrice();
        if (p <= 0) revert Errors.OraclePriceInvalid();
        uint256 price = uint256(p);
        uint256 feeInInv = (100 * 1e18 * 1e18) / uint256(price); // FUNDING_REQUEST_FEE = $100
        // Caller must approve DAO; manager instructs DAO to collect
        // Use a dedicated fee-collector hook to avoid exposing ERC20 internals; implemented in DAO
        IInvtronDao(dao).collectInvFee(msg.sender, feeInInv);

        FundingLib.createFundingRequest(
            _fundingState,
            msg.sender,
            details,
            VOTING_PERIOD
        );
    }

    // fee collection helper removed (using typed interface)

    /// @notice Endorsers vote on a funding request before it is opened to all users.
    function voteOnFundingByEndorser(uint256 id) external {
        _onlyEndorser();
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Pending) revert Errors.FundingProposalNotPending();
        if (block.timestamp >= req.deadline) {
            req.status = ProposalLib.ProposalStatus.Defeated;
            emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
            revert Errors.FundingVotingEnded();
        }
        if (fundingEndorsersVoted[id][msg.sender]) revert Errors.FundingEndorserAlreadyVoted();
        fundingEndorsersVoted[id][msg.sender] = true;
        req.endorserVotes++;
        if (req.endorserVotes >= ENDORSER_VOTES_FOR_FUNDING_PASS) {
            req.status = ProposalLib.ProposalStatus.Active;
            req.deadline = block.timestamp + VOTING_PERIOD;
            emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Active));
        }
    }

    /// @notice Expire a pending funding request if deadline passed without enough endorser votes.
    function expireFundingRequest(uint256 id) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Pending) revert Errors.FundingProposalNotPending();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        req.status = ProposalLib.ProposalStatus.Defeated;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
    }

    /// @notice Users vote on a funding request using their delegated voting power.
    function voteOnFundingByUser(uint256 id, bool inFavor, address tokenHolder) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActiveUser();
        if (block.timestamp >= req.deadline) revert Errors.FundingVotingEnded();

        // Prepare delegated vote and snapshot lock inside DAO
        address voter = IInvtronDao(dao).prepareFundingVote(msg.sender, tokenHolder);
        if (voter == address(0)) revert Errors.InvalidTokenHolder();

        if (voter == req.proposer) revert Errors.SelfVoting();

        if (fundingUsersVoted[id][voter]) revert Errors.FundingUserAlreadyVoted();

        // --- Price validation & normalization ---
        int p = IInvtronDao(dao).getLatestUsdPrice();
        if (p <= 0) revert Errors.OraclePriceInvalid();
        uint256 price = uint256(p);
        // Original unclamped powers (USD6), derived from delegated votes model:
        uint256 senderPower = _getVotingValueByVotes(msg.sender, int(price), req.amount);
        uint256 delegatedPower = 0;
        if (voter != msg.sender) {
            delegatedPower = _getVotingValueByVotes(voter, int(price), req.amount);
        }
        uint256 rawPower = senderPower + delegatedPower;
        uint256 power = rawPower;

        // -------- Cross-type headroom clamp (prevents "free votes") --------
        // Headroom tokens available for *any* new lock right now:
        uint256 headroomSender = IInvtronDao(dao).freeHeadroomTokens(msg.sender);
        uint256 headroomVoter  = voter != msg.sender ? IInvtronDao(dao).freeHeadroomTokens(voter) : 0;
        // Maximum USD capacity implied by headroom (must be covered by actual lock later):
        //   lockTokens = usd6 * 200 * 1e30 / price  =>  usd6 = lockTokens * price / (200 * 1e30)
        uint256 maxUsdBySenderFree = (headroomSender * price) / (200 * 1e30);
        uint256 maxUsdByVoterFree  = voter != msg.sender ? (headroomVoter  * price) / (200 * 1e30) : 0;

        // Clamp each leg independently by the USD capacity implied by its free tokens.
        if (senderPower > maxUsdBySenderFree) senderPower = maxUsdBySenderFree;
        if (delegatedPower > maxUsdByVoterFree) delegatedPower = maxUsdByVoterFree;
        power = senderPower + delegatedPower;
        if (power == 0) {
            if (rawPower > 0) revert Errors.TokensLocked();
            revert Errors.NoVotingPower();
        }
        // Clamp applied vote so raised never exceeds hardcap and never drops below zero
        uint256 currentRaised = _currentRaisedClamped(req);
        uint256 applied;
        if (inFavor) {
            uint256 room = req.details.hardCapAmount > currentRaised
                ? (req.details.hardCapAmount - currentRaised)
                : 0;
            applied = power > room ? room : power;
            if (applied == 0) revert Errors.NoVotingPower(); // prevent zero-effect "for" votes

            req.userVotesFor += applied;
        } else {
            applied = power > currentRaised ? currentRaised : power;
            if (applied == 0) revert Errors.NoVotingPower(); // prevent zero-effect "against" votes

            req.userVotesAgainst += applied;
        }

        fundingUsersVoted[id][voter] = true;
        fundingUserVoteChoice[id][voter] = inFavor;

        // Scale stored powers proportionally to applied vote for reward calculations
        uint256 appliedSender = senderPower;
        uint256 appliedDelegated = delegatedPower;
        if (power > 0 && applied < power) {
            appliedSender = (senderPower * applied) / power;
            appliedDelegated = applied - appliedSender;
        }
        // Lock tokens for the sender, proportional to their contribution.
        if (appliedSender > 0) {
            // Lock intention & units:
            // - Voting power here is USD(6).
            // - Convert USD(6) -> tokens (18d): tokens = usd6 * 1e30 / price (price has 18d).
            // - Apply LOCK_FACTOR = 200 so that $1 at $1/INV locks 200 INV.
            //   Example: appliedSender = $1 => 1e6 * 200 * 1e30 / 1e18 = 200e18 (200 tokens).

            uint256 senderLockTokens = (appliedSender * 200 * 1e30) / price;
            IInvtronDao(dao).lockTokensForFunding(msg.sender, senderLockTokens);
        }
        // If a delegate was used, lock their tokens as well, proportional to their contribution.
        if (voter != msg.sender && appliedDelegated > 0) {
            // Same formula as above, applied to the delegated portion
            uint256 delegatedLockTokens = (appliedDelegated * 200 * 1e30) / price;
            IInvtronDao(dao).lockTokensForFunding(voter, delegatedLockTokens);
        }
        if (voter == msg.sender) {
            votingPowerAtVote[id][voter] = appliedSender;
        } else {
            votingPowerAtVote[id][voter] = appliedDelegated;
            delegateePowerAtVote[id][voter] = appliedSender;
        }
        // Persist delegate-at-vote from DAO mapping
        delegateAtVote[id][voter] = IInvtronDao(dao).getDelegate(voter);

        emit EventLib.Voted(id, voter, inFavor, applied);
    }

    /// @notice Finalize a funding request that failed to reach majority support.
    function finalizeFundingRequest(uint256 id) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActive();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        if (req.userVotesFor > req.userVotesAgainst) revert Errors.FundingProposalPassed();
        req.status = ProposalLib.ProposalStatus.Defeated;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
    }

    /// @notice CEO approval required before a passed funding request can mint tokens.
    function releaseFundingRequest(uint256 id) external {
        _onlyCeo();
        FundingLib.releaseFundingRequest(_fundingState, id);
    }

    /// @notice Execute a passed funding request to mint INV-USD and seed exchange state in DAO.
    function mintTokensForFundingRequest(uint256 id) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (_currentRaisedClamped(req) == 0) revert Errors.FundingProposalFailed();
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActiveExecution();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActiveExecution();
        if (req.userVotesFor <= req.userVotesAgainst) revert Errors.FundingProposalFailed();
        if (!req.ceoApproved) revert Errors.FundingRequestNotApproved();

        // Mark executed
        req.status = ProposalLib.ProposalStatus.Executed;
        uint256 mintAmount = req.amount * 1e12; // convert USD(6) to token(18)

        // Mint INV-USD via DAO (owner of token) and seed exchange remaining
        IInvtronDao(dao).mintInvUsdByManager(req.proposer, mintAmount);
        IInvtronDao(dao).seedExchangeRemaining(id, mintAmount);

        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Executed));
    }

    // --- Rewards ---
    /// @notice View expected reward for a voter after finalization.
    function getVotingReward(uint256 fundingRequestId, address voter)
        external
        view
        returns (uint256 rewardInvWei)
    {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[fundingRequestId];
        if (!(req.status == ProposalLib.ProposalStatus.Executed || req.status == ProposalLib.ProposalStatus.Defeated)) {
            return 0;
        }
        if (!fundingUsersVoted[fundingRequestId][voter]) return 0;
        bool votedFor = fundingUserVoteChoice[fundingRequestId][voter];
        bool correct = (req.status == ProposalLib.ProposalStatus.Executed && votedFor) ||
            (req.status == ProposalLib.ProposalStatus.Defeated && !votedFor);
        if (!correct) return 0;

        uint256 price = uint256(IInvtronDao(dao).getLatestUsdPrice());
        if (price == 0) return 0;
        (address delegatee, uint256 baseInv, uint256 delegateInv) = _payoutParts(fundingRequestId, voter, price);
        if (delegatee != address(0)) {
            rewardInvWei = (baseInv * 90) / 100;
        } else {
            rewardInvWei = baseInv + delegateInv;
        }
    }

    /// @notice Claim voting rewards for a funding proposal.
    function claimReward(uint256 fundingRequestId) external {
        if (rewardClaimed[fundingRequestId][msg.sender]) revert Errors.RewardAlreadyClaimed();
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[fundingRequestId];
        if (!(req.status == ProposalLib.ProposalStatus.Executed || req.status == ProposalLib.ProposalStatus.Defeated)) {
            revert Errors.ProposalNotFinalized();
        }
        if (!fundingUsersVoted[fundingRequestId][msg.sender]) revert Errors.AddressDidNotVote();
        bool votedFor = fundingUserVoteChoice[fundingRequestId][msg.sender];
        bool correct = (req.status == ProposalLib.ProposalStatus.Executed && votedFor) ||
            (req.status == ProposalLib.ProposalStatus.Defeated && !votedFor);
        if (!correct) revert Errors.VoteMismatch();

        uint256 price = uint256(IInvtronDao(dao).getLatestUsdPrice());
        if (price == 0) revert Errors.OraclePriceInvalid();
        (address delegatee, uint256 baseInv, uint256 delegateInv) = _payoutParts(fundingRequestId, msg.sender, price);
        rewardClaimed[fundingRequestId][msg.sender] = true;
        if (delegatee != address(0)) {
            uint256 delegatorShare = (baseInv * 90) / 100;
            uint256 delegateeShare = (baseInv + delegateInv) - delegatorShare;
            IInvtronDao(dao).mintGovByManager(msg.sender, delegatorShare);
            IInvtronDao(dao).mintGovByManager(delegatee, delegateeShare);
            emit EventLib.RewardClaimed(msg.sender, delegatorShare);
        } else {
            uint256 totalReward = baseInv + delegateInv;
            IInvtronDao(dao).mintGovByManager(msg.sender, totalReward);
            emit EventLib.RewardClaimed(msg.sender, totalReward);
        }
    }

    // --- Internals ---
    /// @dev Convert a USD(6) voting value into INV(18) at 22% reward.
    ///      tokensWei = usd6 * 22% * 1e30 / price(18)  ==  usd6 * 22 * 1e28 / price
    function _toInv(uint256 usd6, uint256 price) internal pure returns (uint256) {
        // exact integer math for wei:
        // return (usd6 * 22 * 1e30) / (100 * price);
        return (usd6 * 22 * 1e28) / price;
    }

    function _getVotingValueByVotes(address who, int price, uint256 requestAmount)
        internal
        view
        returns (uint256 value)
    {
        // --- Constants for the model (using basis points for precision) ---
        uint256 BASE_RATE_BPS = 5; // 0.05%
        uint256 MAX_RATE_BPS = 50; // 0.5%
        uint256 MATURATION_PERIOD_SECONDS = 12 * 30 days; // 12 months

        // 1. Get user's INV balance and its USD value
        uint256 vp = IInvtronDao(dao).getPastVotes(who, block.number - 1);
        uint256 invValueUsd = (vp * uint256(price)) / 1e30; // USD(6)

        // 2. Get the user's holding duration from the DAO
        uint256 age = IInvtronDao(dao).balanceAge(who);
        uint256 holdingDuration = block.timestamp > age ? block.timestamp - age : 0;

        // 3. Calculate the effective rate in basis points
        uint256 effectiveRateBps;
        if (holdingDuration >= MATURATION_PERIOD_SECONDS) {
            effectiveRateBps = MAX_RATE_BPS;
        } else {
            uint256 rateIncreaseBps = MAX_RATE_BPS - BASE_RATE_BPS;
            uint256 bonusBps = (rateIncreaseBps * holdingDuration) / MATURATION_PERIOD_SECONDS;
            effectiveRateBps = BASE_RATE_BPS + bonusBps;
        }

        // 4. Calculate the time-weighted voting value
        value = (invValueUsd * effectiveRateBps) / 10000;

        // 5. Apply the existing 10% cap relative to the request amount
        uint256 maxValue = requestAmount / 10;
        if (value > maxValue) {
            value = maxValue;
        }
    }

    function _currentRaisedClamped(FundingLib.FundingRequest storage req)
        internal
        view
        returns (uint256 raised)
    {
        if (req.userVotesFor > req.userVotesAgainst) {
            raised = req.userVotesFor - req.userVotesAgainst;
        }
        uint256 cap = req.details.hardCapAmount;
        if (raised > cap) raised = cap;
    }

    function _payoutParts(uint256 fundingRequestId, address voter, uint256 price)
        internal
        view
        returns (address delegatee, uint256 baseInv, uint256 delegateInv)
    {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[fundingRequestId];
        bool votedFor = fundingUserVoteChoice[fundingRequestId][voter];
        bool correct = (req.status == ProposalLib.ProposalStatus.Executed && votedFor) ||
            (req.status == ProposalLib.ProposalStatus.Defeated && !votedFor);
        if (!correct) return (address(0), 0, 0);
        delegatee = delegateAtVote[fundingRequestId][voter];
        baseInv = _toInv(votingPowerAtVote[fundingRequestId][voter], price);
        delegateInv = _toInv(delegateePowerAtVote[fundingRequestId][voter], price);
    }
}
