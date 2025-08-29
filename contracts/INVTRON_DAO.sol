//Main Contract: INVTRON_DAO.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "./libraries/VotingLib.sol";
import "./libraries/Errors.sol";
import "./libraries/PriceLib.sol";
import "./libraries/EndorserLib.sol";
import "./libraries/DelegateLib.sol";
import "./libraries/WhitelistLib.sol";
import "./libraries/TokenHolderLib.sol";
import "./libraries/EventLib.sol";
import "./libraries/ProposalLib.sol";
import "./libraries/FundingLib.sol";
import "./InvUsdToken.sol";
import "./WhitelistManager.sol";
import "./CeoManager.sol";
import "./ExchangeManager.sol";

/// @dev Minimal live-votes delegation (no checkpoints, no past-block reads).
/// - Voting power mirrors current balances of delegatees.
/// - Exposes ERC20Votes-like names: delegates(), getVotes(), delegate().
abstract contract __MinimalVotes {
    mapping(address => address) internal __delegates;     // delegator => delegatee (0 => self)
    mapping(address => uint256) internal __votingPower;   // current power per delegatee

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    function delegates(address account) public view returns (address) {
        address d = __delegates[account];
        return d == address(0) ? account : d; // default to self
    }

    function getVotes(address account) public view returns (uint256) {
        return __votingPower[account];
    }

    function _delegate(address delegator, address to) internal {
        address fromDel = delegates(delegator);
        address toDel = (to == address(0)) ? delegator : to;
        if (fromDel == toDel) return;
        __delegates[delegator] = toDel;
        emit DelegateChanged(delegator, fromDel, toDel);

        uint256 bal = _balanceOfForVotes(delegator);
        uint256 prevFrom = __votingPower[fromDel];
        __votingPower[fromDel] = prevFrom - bal;
        emit DelegateVotesChanged(fromDel, prevFrom, prevFrom - bal);

        uint256 prevTo = __votingPower[toDel];
        __votingPower[toDel] = prevTo + bal;
        emit DelegateVotesChanged(toDel, prevTo, prevTo + bal);
    }

    function delegate(address to) public virtual {
        _delegate(msg.sender, to);
    }

    /// @dev Must be implemented by the token to expose balances for votes accounting.
    function _balanceOfForVotes(address account) internal view virtual returns (uint256);

    /// @dev Call this after any token balance change affecting `owner`.
    function _afterTokenBalanceChange(address owner, uint256 oldBal, uint256 newBal) internal {
        if (newBal == oldBal) return;
        address del = delegates(owner);
        if (newBal > oldBal) {
            __votingPower[del] += newBal - oldBal;
        } else {
            __votingPower[del] -= oldBal - newBal;
        }
    }
}
/**
 * @title INVTRON_DAO
 * @notice Core governance contract powering the Invtron ecosystem.
 * @dev Manages tokenized voting, funding requests and role based permissions.
 * The DAO issues INV governance tokens and an internal INV-USD voucher used
 * during funding rounds. Most state changing actions are gated by either the
 * CEO or a vote of the community.
 */
contract INVTRON_DAO is ERC20, EIP712, ExchangeManager, __MinimalVotes {

    // --- Roles ---
    mapping(address => bool) private isEndorser;

    WhitelistManager public whitelistManager;

    // --- External Contracts & Feeds ---
    address public treasuryOwner;

    // --- Constants for Fees & Thresholds ---
    uint256 public constant CEO_APPLICATION_FEE = 100 * 1e18; // $100
    uint256 public constant ENDORSER_APPLICATION_FEE = 50 * 1e18; // $50
    uint256 public constant FUNDING_REQUEST_FEE = 100 * 1e18; // $100
    uint256 public constant CEO_REQUIRED_BALANCE_USD = 25000 * 1e18; // $25,000
    uint256 public constant ENDORSER_REQUIRED_BALANCE_USD = 10000 * 1e18; // $10,000
    uint256 public constant ENDORSER_VOTES_FOR_CEO_PASS = 3; // go back to 26 on mainnet
    uint256 public constant ENDORSER_VOTES_FOR_FUNDING_PASS = 3; // go back to 26 on mainnet
    uint256 public constant VOTING_PERIOD = 72 hours;
    uint256 public constant TOKEN_LOCK_DURATION = 73 hours;
    bytes32 public constant DELEGATE_VP_TYPEHASH =
        keccak256("DelegateVP(address delegatee,uint256 nonce,uint256 deadline)");

    // Same typehash OZ uses for ERC20Votes delegation
    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    mapping(address => uint256) private _nonces;

    // --- State Variables for Proposal Storage ---
    uint256 public nextCeoApplicationId;
    mapping(uint256 => CeoApplication) public ceoApplications;

    // --- State Variables for Vote Tracking (Externalized from Structs) ---
    mapping(uint256 => mapping(address => bool)) public ceoEndorsersVoted;
    mapping(uint256 => mapping(address => bool)) public ceoUsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingEndorsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUserVoteChoice;
    // Store each voter's voting power at the time they voted on a funding request
    mapping(uint256 => mapping(address => uint256)) public votingPowerAtVote;
    // Track the caller's own voting power at the time of voting
    mapping(uint256 => mapping(address => uint256)) public delegateePowerAtVote;
    // Record the delegate a voter had assigned at the time of voting
    mapping(uint256 => mapping(address => address)) public delegateAtVote;
    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    // Track active applications per address to prevent duplicates
    mapping(address => uint256) public activeCeoApplication;

    // --- Dynamic Endorser Leaderboard ---
    uint256 public constant MAX_ACTIVE_ENDORSERS = 50;

    mapping(address => EndorserLib.EndorserCandidate) public endorserCandidates;
    mapping(address => address) public endorserVotes; // voter => candidate
    address[] private _activeEndorserList;
    address public lowestActiveEndorser;

    // --- State Variables for Rate-Limiting & Token-Locking ---
    mapping(address => uint256) public recentVoteTimestamps;
    mapping(address => uint256) public tokenUnlockTime;
    // Balance the account must retain while locked (snapshot at vote time)
    mapping(address => uint256) public lockedBalanceRequirement;
    mapping(address => address) public votingDelegate;

    using TokenHolderLib for TokenHolderLib.State;
    TokenHolderLib.State private _tokenHolderState;

    // --- Supply Tracking ---
    uint256 public totalVestedTokens;
    // Running total of tokens locked by voting snapshots (sum of lockedBalanceRequirement for active locks)
    uint256 public totalLockedTokens;

    // --- Hooks required by ExchangeManager ---
    function _totalSupply() internal view override returns (uint256) {
        return totalSupply();
    }

    function _totalVestedTokens() internal view override returns (uint256) {
        return totalVestedTokens;
    }

    function _getTotalTokensLocked() internal view override returns (uint256) {
        return totalLockedTokens;
    }

    function _balanceOfForVotes(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    modifier onlyWhitelisted() {
        if (!whitelistManager.isWhitelisted(msg.sender)) revert Errors.NotWhitelisted();
        _;
    }

    modifier onlyEndorser() {
        if (!isEndorser[msg.sender]) revert Errors.OnlyEndorser();
        _;
    }

    // --- Proposal Structs (Mappings Removed) ---

    struct CeoApplication {
        address applicant;
        uint256 endorserVotes;
        uint256 userVotesFor;
        uint256 userVotesAgainst;
        uint256 deadline;
        ProposalLib.ProposalStatus status;
    }

    // --- Events ---
    // Events are declared in EventLib.sol

    /**
     * @dev Initializes all parent contracts and sets up initial DAO state.
     */
    constructor(
        address _priceFeedAddress,
        address _initialCeo,
        address[] memory _initialEndorsers,
        address _treasuryOwner,
        address _invUsdToken,
        address _whitelistManager
    )
        ERC20("INVTRON", "INV")
        EIP712("INVTRON", "1")
    {
        invUsdToken = InvUsdToken(_invUsdToken);
        whitelistManager = WhitelistManager(_whitelistManager);

        _setCeo(_initialCeo);
        if (_initialEndorsers.length > MAX_ACTIVE_ENDORSERS) {
            revert Errors.TooManyInitialEndorsers();
        }
        for (uint256 i = 0; i < _initialEndorsers.length; i++) {
            isEndorser[_initialEndorsers[i]] = true;
            endorserCandidates[_initialEndorsers[i]].registered = true;
            endorserCandidates[_initialEndorsers[i]].active = true;
            _activeEndorserList.push(_initialEndorsers[i]);
        }
        lowestActiveEndorser = VotingLib.findLowestActiveEndorser(_activeEndorserList, getVotes);

        // Set external feeds
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        treasuryOwner = _treasuryOwner;
        lastPrice = PriceLib.getLatestPrice(priceFeed);

        // Mint initial governance token supply (1 billion tokens as per white paper)
        _mint(msg.sender, 1_000_000_000 * 10**decimals());
    }

    // --- Role Management & Applications ---

    /// @notice Update the address that collects application fees.
    /// @param newOwner The new treasury address.
    function setTreasuryOwner(address newOwner) external onlyCEO {
        if (newOwner == address(0)) revert Errors.TreasuryOwnerZero();
        treasuryOwner = newOwner;
    }

    // Note: legacy vested/unswapped increase function removed.

    /// @notice Decrease the amount of vested tokens excluded from circulation.
    function decreaseTotalVestedTokens(uint256 amount) external onlyCEO {
        if (amount > totalVestedTokens) revert Errors.VestedAmountExceedsTotal();
        uint256 previous = totalVestedTokens;
        totalVestedTokens -= amount;
        emit EventLib.TotalVestedTokensUpdated(previous, totalVestedTokens);
    }


    /// @notice Submit yourself as a candidate for the CEO role.
    /// @dev Requires the caller to be whitelisted and to hold a minimum amount
    ///      of INV tokens equivalent to $25,000.
    function applyForCeo() external {
        if (!whitelistManager.isWhitelisted(msg.sender)) revert Errors.ApplicantNotWhitelisted();
        if (electedCeo != address(0)) revert Errors.ElectedCeoPending();
        if (ceoStatus[msg.sender] != CeoStatus.None) revert Errors.CeoApplicationExists();

        int currentPrice = PriceLib.getLatestPrice(priceFeed);
        uint256 userValue = (balanceOf(msg.sender) * uint256(currentPrice)) / 1e18;
        if (userValue < CEO_REQUIRED_BALANCE_USD) revert Errors.InsufficientInvBalance();

        uint256 feeInInv = (CEO_APPLICATION_FEE * 1e18) / uint256(currentPrice);

        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        uint256 id = nextCeoApplicationId++;
        CeoApplication storage app = ceoApplications[id];
        app.applicant = msg.sender;
        app.deadline = block.timestamp + VOTING_PERIOD;
        app.status = ProposalLib.ProposalStatus.Pending;
        activeCeoApplication[msg.sender] = id;
        ceoStatus[msg.sender] = CeoStatus.Nominated;
        emit EventLib.CeoApplicationCreated(id, msg.sender);
    }

    // --- Funding Requests ---

    /// @notice Propose a new funding request with caps expressed in USDT units.
    /// @param details Struct containing all project information:
    ///  - projectName: name of the project
    ///  - softCapAmount: minimum amount targeted in USDT (6 decimals)
    ///  - hardCapAmount: maximum amount targeted in USDT (6 decimals)
    ///  - valuation: company valuation in USD
    ///  - country: country of registration
    ///  - websiteUrl: project website URL
    ///  - ceoLinkedInUrl: CEO LinkedIn profile URL
    ///  - shortDescription: brief summary of the project
    ///  - companyRegistrationUrl: link to company registration proof
    /// @dev A small fee in INV is charged and transferred to the treasury.
    function createFundingRequest(FundingLib.FundingDetails calldata details)
        external
        onlyWhitelisted
    {
        int currentPrice = PriceLib.getLatestPrice(priceFeed);
        uint256 feeInInv = (FUNDING_REQUEST_FEE * 1e18) / uint256(currentPrice);
        
        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        FundingLib.createFundingRequest(
            _fundingState,
            msg.sender,
            details,
            VOTING_PERIOD
        );
    }

    // --- Endorser Leaderboard ---

    /// @notice Register the caller as a potential endorser candidate.
    /// @dev Charges a small application fee which is sent to the treasury.
    function registerEndorserCandidate() external onlyWhitelisted {
        int currentPrice = PriceLib.getLatestPrice(priceFeed);
        uint256 userValue = (balanceOf(msg.sender) * uint256(currentPrice)) / 1e18;
        if (userValue < ENDORSER_REQUIRED_BALANCE_USD) revert Errors.InsufficientInvBalance();
        uint256 feeInInv = (ENDORSER_APPLICATION_FEE * 1e18) / uint256(currentPrice);
        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        EndorserLib.PersonalInfo memory info = whitelistManager
            .getWhitelistInfo(msg.sender);
        EndorserLib.registerCandidate(endorserCandidates, msg.sender, info);
    }

    /// @notice Vote for an endorser candidate using the caller's voting power.
    /// @param candidate Address of the candidate being supported.
    function voteForEndorser(address candidate) external {
        (uint256 weight, address newLowest) = EndorserLib.voteForCandidate(
            endorserCandidates,
            endorserVotes,
            _activeEndorserList,
            msg.sender,
            candidate,
            getVotes
        );
        delegate(candidate);
        emit EndorserLib.EndorserVoteChanged(msg.sender, candidate, weight);
        lowestActiveEndorser = newLowest;
    }

    function delegate(address delegatee) public override {
        if (block.timestamp < tokenUnlockTime[msg.sender]) revert Errors.TokensLocked();
        _delegate(msg.sender, delegatee);
    }

    function nonces(address owner) external view returns (uint256) {
        return _nonces[owner];
    }

    function _useNonce(address owner) internal returns (uint256 current) {
        current = _nonces[owner];
        _nonces[owner] = current + 1;
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        if (block.timestamp > expiry) revert Errors.SignatureExpired();

        // Recover signer and validate nonce
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        if (nonce != _useNonce(signer)) revert Errors.InvalidNonce();

        // Block delegation while locked
        if (block.timestamp < tokenUnlockTime[signer]) revert Errors.TokensLocked();

        _delegate(signer, delegatee);
    }

    /// @notice Delegate voting power using an EIP-712 signature.
    /// @param delegatee Address receiving the voting power.
    /// @param nonce Current nonce of the signer.
    /// @param deadline Expiration time of the signature.
    /// @param v Signature parameter v.
    /// @param r Signature parameter r.
    /// @param s Signature parameter s.
    function delegateVPbySig(
        address delegatee,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert Errors.SignatureExpired();

        // Pre-recover signer for the lock check (do not consume nonce here)
        bytes32 structHash = keccak256(abi.encode(DELEGATE_VP_TYPEHASH, delegatee, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);

        if (block.timestamp < tokenUnlockTime[signer]) revert Errors.TokensLocked();

        // Proceed with existing flow; DelegateLib will consume nonce
        DelegateLib.delegateBySig(
            votingDelegate,
            DELEGATE_VP_TYPEHASH,
            _hashTypedDataV4,
            _useNonce,
            delegatee,
            nonce,
            deadline,
            v,
            r,
            s
        );
    }

    /// @notice Attempt to join the active endorser set by displacing the weakest member.
    /// @param candidate Address of the registered candidate trying to join.
    function challengeEndorser(address candidate) external {
        (address replaced, address newLowest) = EndorserLib.challengeCandidate(
            endorserCandidates,
            _activeEndorserList,
            candidate,
            MAX_ACTIVE_ENDORSERS,
            getVotes
        );
        lowestActiveEndorser = newLowest;
        if (replaced != address(0)) {
            isEndorser[replaced] = false;
        }
        isEndorser[candidate] = true;
    }


    /**
     * @dev Returns the full list of active endorsers.
     */
    function activeEndorserList() external view returns (address[] memory) {
        return _activeEndorserList;
    }

    // --- Voting Functions ---

    /// @notice Endorsers cast their vote on a pending CEO application.
    /// @param id Identifier of the CEO application.
    function voteOnCeoByEndorser(uint256 id) external onlyEndorser {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalLib.ProposalStatus.Pending) revert Errors.CeoProposalNotPending();
        if (block.timestamp >= app.deadline) {
            app.status = ProposalLib.ProposalStatus.Defeated;
            ceoStatus[app.applicant] = CeoStatus.None;
            activeCeoApplication[app.applicant] = 0;
            emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
            revert Errors.CeoVotingEnded();
        }
        if (ceoEndorsersVoted[id][msg.sender]) revert Errors.EndorserAlreadyVoted();
        ceoEndorsersVoted[id][msg.sender] = true;
        app.endorserVotes++;
        if (app.endorserVotes >= ENDORSER_VOTES_FOR_CEO_PASS) {
            app.status = ProposalLib.ProposalStatus.Active;
            app.deadline = block.timestamp + VOTING_PERIOD;
            emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Active));
        }
    }

    /// @notice Endorsers vote on a funding request before it is opened to all users.
    /// @param id Identifier of the funding request.
    function voteOnFundingByEndorser(uint256 id) external onlyEndorser {
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

    /// @notice Expire a pending CEO application if the deadline has passed without enough endorser votes.
    function expireCeoApplication(uint256 id) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalLib.ProposalStatus.Pending) revert Errors.CeoProposalNotPending();
        if (block.timestamp < app.deadline) revert Errors.CeoVotingActive();
        app.status = ProposalLib.ProposalStatus.Defeated;
        ceoStatus[app.applicant] = CeoStatus.None;
        activeCeoApplication[app.applicant] = 0;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
    }

    /// @notice Expire a pending funding request if the deadline has passed without enough endorser votes.
    function expireFundingRequest(uint256 id) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Pending) revert Errors.FundingProposalNotPending();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        req.status = ProposalLib.ProposalStatus.Defeated;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
    }

    /// @notice Cast a user vote on an active CEO application.
    /// @param id Identifier of the CEO application.
    /// @param inFavor True to vote in favour, false to vote against.
    /// @param tokenHolder Address whose voting power is used (can be a delegate).
    function voteOnCeoByUser(uint256 id, bool inFavor, address tokenHolder) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalLib.ProposalStatus.Active) revert Errors.CeoProposalNotActive();
        if (block.timestamp >= app.deadline) revert Errors.CeoVotingEnded();
        (address voter, uint256 power) = VotingLib.prepareDelegatedVote(
            votingDelegate,
            tokenUnlockTime,
            recentVoteTimestamps,
            getVotes,
            TOKEN_LOCK_DURATION,
            msg.sender,
            tokenHolder
        );
        _snapshotLock(voter);
        if (app.applicant == voter) revert Errors.ApplicantSelfVote();
        if (ceoUsersVoted[id][voter]) revert Errors.CeoUserAlreadyVoted();
        ceoUsersVoted[id][voter] = true;
        if (inFavor) app.userVotesFor += power;
        else app.userVotesAgainst += power;
        emit EventLib.Voted(id, voter, inFavor, power);
    }

    /// @notice Users vote on a funding request using their delegated voting power.
    /// @param id Identifier of the funding request.
    /// @param inFavor True to vote in favour, false otherwise.
    /// @param tokenHolder Address whose votes will be counted.
    function voteOnFundingByUser(uint256 id, bool inFavor, address tokenHolder) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActiveUser();
        if (block.timestamp >= req.deadline) revert Errors.FundingVotingEnded();
        (address voter, ) = VotingLib.prepareDelegatedVote(
            votingDelegate,
            tokenUnlockTime,
            recentVoteTimestamps,
            balanceOf,
            TOKEN_LOCK_DURATION,
            msg.sender,
            tokenHolder
        );
        _snapshotLock(voter);
        if (fundingUsersVoted[id][voter]) revert Errors.FundingUserAlreadyVoted();

        int price = PriceLib.getLatestPrice(priceFeed);
        uint256 senderPower = VotingLib.getVotingValueByVotes(getPastVotes, price, msg.sender, req.amount);
        uint256 delegatedPower = 0;
        if (voter != msg.sender) {
            delegatedPower = VotingLib.getVotingValueByVotes(getPastVotes, price, voter, req.amount);
        }
        uint256 power = senderPower + delegatedPower;

        // Clamp applied vote so raised never exceeds hardcap and never drops below zero
        uint256 currentRaised = _currentRaisedClamped(req);
        uint256 applied;
        if (inFavor) {
            uint256 room = req.details.hardCapAmount > currentRaised
                ? (req.details.hardCapAmount - currentRaised)
                : 0;
            applied = power > room ? room : power;
            req.userVotesFor += applied;
        } else {
            applied = power > currentRaised ? currentRaised : power;
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
        votingPowerAtVote[id][voter] = appliedDelegated == 0 ? appliedSender : appliedDelegated;
        delegateePowerAtVote[id][voter] = appliedSender;
        delegateAtVote[id][voter] = votingDelegate[voter];

        emit EventLib.Voted(id, voter, inFavor, power);
    }

    function _snapshotLock(address voter) internal {
        // If an old lock expired, drop it from the running total
        uint256 prevReq = lockedBalanceRequirement[voter];
        if (prevReq != 0 && block.timestamp >= tokenUnlockTime[voter]) {
            totalLockedTokens -= prevReq;
            prevReq = 0;
            lockedBalanceRequirement[voter] = 0;
        }
        uint256 balAtVote = balanceOf(voter);
        if (balAtVote > prevReq) {
            uint256 delta = balAtVote - prevReq;
            totalLockedTokens += delta;
            lockedBalanceRequirement[voter] = balAtVote;
        }
    }

    

    // --- Finalization ---

    /// @notice Conclude an active CEO election once its voting period has ended.
    /// @param id Identifier of the CEO application.
    function finalizeCeoVote(uint256 id) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalLib.ProposalStatus.Active) revert Errors.CeoProposalNotActiveFinalization();
        if (block.timestamp < app.deadline) revert Errors.CeoVotingActive();

        if (app.userVotesFor > app.userVotesAgainst) {
            app.status = ProposalLib.ProposalStatus.Succeeded;
            ceoStatus[app.applicant] = CeoStatus.Elected;
            electedCeo = app.applicant;
            electedCeoTimestamp = block.timestamp;
        } else {
            app.status = ProposalLib.ProposalStatus.Defeated;
            ceoStatus[app.applicant] = CeoStatus.None;
        }
        activeCeoApplication[app.applicant] = 0;
        emit EventLib.ProposalStatusUpdated(id, uint8(app.status));
    }

    /// @notice Finalize a funding request that failed to reach majority support.
    /// @param id Identifier of the funding request.
    function finalizeFundingRequest(uint256 id) external {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (req.status != ProposalLib.ProposalStatus.Active) revert Errors.FundingProposalNotActive();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        if (req.userVotesFor > req.userVotesAgainst) revert Errors.FundingProposalPassed();
        req.status = ProposalLib.ProposalStatus.Defeated;
        emit EventLib.ProposalStatusUpdated(id, uint8(ProposalLib.ProposalStatus.Defeated));
    }

    /// @notice Activate the elected CEO after the mandatory waiting period.
    function activateElectedCeo() external {
        if (electedCeo == address(0)) revert Errors.NoElectedCeo();
        if (block.timestamp < electedCeoTimestamp + ELECTED_CEO_ACTIVATION_DELAY) {
            revert Errors.ActivationNotReached();
        }
        address newCeo = electedCeo;
        electedCeo = address(0);
        ceoStatus[newCeo] = CeoStatus.Active;
        _setCeo(newCeo);
    }

    /// @notice CEO approval required before a passed funding request can mint tokens.
    /// @param id Identifier of the funding request.
    function releaseFundingRequest(uint256 id) external onlyCEO {
        FundingLib.releaseFundingRequest(_fundingState, id);
    }


    /// @notice Mint INV-USD to the proposer after a successful vote and CEO approval.
    /// @param id Identifier of the funding request.
    function executeFundingRequest(uint256 id) external nonReentrant {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        if (_currentRaisedClamped(req) == 0) revert Errors.FundingProposalFailed();
        FundingLib.executeFundingRequest(
            _fundingState,
            invUsdToken,
            remainingToExchange,
            id
        );
        // Unswapped accounting removed; remainingToExchange still tracks per-request balances.
    }

    /// @notice View the clamped total raised amount for a funding request.
    /// @param id Identifier of the funding request.
    /// @return raised Amount raised in USDT (6 decimals).
    function getRaisedAmount(uint256 id) external view returns (uint256 raised) {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[id];
        raised = _currentRaisedClamped(req);
    }

    /// @dev Compute clamped raised amount: max(0, min(hardcap, for - against)).
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

    /// @notice View the reward a voter can claim (in INV wei) for a finalized funding request.
    /// @dev Rewards are based on the (capped) voting power snapshot (USD6) divided by 10,
    ///      converted to INV(18d) using the current oracle price. Delegators receive 90%
    ///      of their voting power reward; delegatees keep 10% plus rewards from delegated power.
    /// @param fundingRequestId Identifier of the funding request.
    /// @param voter Address of the voter.
    function getVotingReward(uint256 fundingRequestId, address voter)
        public
        view
        returns (uint256 rewardInvWei)
    {
        uint256 price = uint256(PriceLib.getLatestPrice(priceFeed));
        if (price == 0) return 0;
        uint256 invPer = 1e29 / price;
        (address delegatee, uint256 baseInv, uint256 delegateInv) = _validateAndGetPayoutParts(
            fundingRequestId,
            voter,
            invPer
        );
        if (delegatee != address(0)) {
            rewardInvWei = (baseInv * 90) / 100;
        } else {
            rewardInvWei = baseInv + delegateInv;
        }
    }

    /// @notice Claim voting rewards for a funding proposal once it is finalized.
    /// @param fundingRequestId Identifier of the funding request.
    function claimReward(uint256 fundingRequestId) external nonReentrant {
        if (rewardClaimed[fundingRequestId][msg.sender]) revert Errors.RewardAlreadyClaimed();
        uint256 price = uint256(PriceLib.getLatestPrice(priceFeed));
        if (price == 0) revert Errors.OraclePriceInvalid();
        uint256 invPer = 1e29 / price;
        (address delegatee, uint256 baseInv, uint256 delegateInv) = _validateAndGetPayoutParts(
            fundingRequestId,
            msg.sender,
            invPer
        );
        rewardClaimed[fundingRequestId][msg.sender] = true;
        if (delegatee != address(0)) {
            uint256 delegatorShare = (baseInv * 90) / 100;
            uint256 delegateeShare = (baseInv + delegateInv) - delegatorShare;
            _mint(msg.sender, delegatorShare);
            _mint(delegatee, delegateeShare);
            emit EventLib.RewardClaimed(msg.sender, delegatorShare);
        } else {
            uint256 totalReward = baseInv + delegateInv;
            _mint(msg.sender, totalReward);
            emit EventLib.RewardClaimed(msg.sender, totalReward);
        }
    }

    function _validateAndGetPayoutParts(
        uint256 fundingRequestId,
        address voter,
        uint256 invPer
    ) internal view returns (address delegatee, uint256 baseInv, uint256 delegateInv) {
        FundingLib.FundingRequest storage req = _fundingState.fundingRequests[fundingRequestId];
        if (!(req.status == ProposalLib.ProposalStatus.Executed || req.status == ProposalLib.ProposalStatus.Defeated)) {
            revert Errors.ProposalNotFinalized();
        }
        if (!fundingUsersVoted[fundingRequestId][voter]) revert Errors.AddressDidNotVote();
        bool votedFor = fundingUserVoteChoice[fundingRequestId][voter];
        bool correct = (req.status == ProposalLib.ProposalStatus.Executed && votedFor) ||
            (req.status == ProposalLib.ProposalStatus.Defeated && !votedFor);
        if (!correct) revert Errors.VoteMismatch();
        delegatee = delegateAtVote[fundingRequestId][voter];
        baseInv = votingPowerAtVote[fundingRequestId][voter] * invPer;
        delegateInv = delegateePowerAtVote[fundingRequestId][voter] * invPer;
    }


    // --- Exchange & Admin ---

    /// @notice Limit how much INV-USD can be converted back to INV each day for a request.
    /// @param requestId The funding request to configure.
    /// @param limitPercent Percentage of the total amount that may be exchanged per day.
    // --- Helpers ---

    /// @notice Calculate the total amount of tokens currently locked for voting.
    /// @dev Running counter updated on vote snapshots and on expiries observed during transfers.
    function getTotalTokensLocked() public view returns (uint256 total) {
        return totalLockedTokens;
    }

    // Intentionally no on-chain enumeration of holders; totals update lazily on activity.

    /// @notice Return the number of tokens currently in circulation.
    /// @dev Circulating supply excludes vested, locked and unswapped tokens.
    function getCirculatingSupply() external view returns (uint256) {
        return totalSupply() - totalVestedTokens - totalLockedTokens;
    }
    
    // --- Required Multi-Inheritance Overrides ---

    function _daoMint(address account, uint256 amount) internal override {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 oldFrom;
        uint256 oldTo;
        uint256 fromReq;
        uint256 fromUnlock;
        if (from != address(0)) {
            oldFrom = balanceOf(from);
            fromReq = lockedBalanceRequirement[from];
            fromUnlock = tokenUnlockTime[from];
        }
        if (to != address(0)) {
            oldTo = balanceOf(to);
        }

        if (from != address(0)) {
            // During the lock window, allow spending only the excess over the required minimum
            if (block.timestamp < fromUnlock) {
                // Disallow spending from the locked (snapshot) portion
                uint256 allowed = oldFrom - fromReq;
                if (amount > allowed) revert Errors.TokensLocked();
            }
        }

        super._update(from, to, amount);

        // Cache delegates once for minimal SLOADs
        address fromDel;
        address toDel;
        if (from != address(0) && to != address(0)) {
            fromDel = delegates(from);
            toDel = delegates(to);
        }

        if (from != address(0)) {
            uint256 newFrom = balanceOf(from);
            // Optimize voting power writes: if both sides delegate to the same address, net change is zero
            if (!(from != address(0) && to != address(0) && fromDel == toDel)) {
                _afterTokenBalanceChange(from, oldFrom, newFrom);
            }
            if (newFrom == 0) {
                _tokenHolderState.removeTokenHolder(from);
            }
            // If lock expired, drop from running total and clear requirement
            if (fromReq != 0 && block.timestamp >= fromUnlock) {
                totalLockedTokens -= fromReq;
                lockedBalanceRequirement[from] = 0;
            }
        }
        if (to != address(0)) {
            uint256 newTo = balanceOf(to);
            if (!(from != address(0) && to != address(0) && fromDel == toDel)) {
                _afterTokenBalanceChange(to, oldTo, newTo);
            }
            if (newTo > 0) {
                _tokenHolderState.addTokenHolder(to);
            }
            // Also clear expired lock for `to` if any is lingering
            uint256 toReq = lockedBalanceRequirement[to];
            if (toReq != 0 && block.timestamp >= tokenUnlockTime[to]) {
                totalLockedTokens -= toReq;
                lockedBalanceRequirement[to] = 0;
            }
        }
    }

    function getPastVotes(address account, uint256) public view returns (uint256) {
        return getVotes(account);
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupply();
    }

    // --- Compatibility Shims ---

    function CEO_ROLE() public pure returns (bytes32) {
        return keccak256("CEO_ROLE");
    }

    function ENDORSER_ROLE() public pure returns (bytes32) {
        return keccak256("ENDORSER_ROLE");
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        if (role == CEO_ROLE()) return account == currentCeo;
        if (role == ENDORSER_ROLE()) return isEndorser[account];
        return false;
    }

    function isCEO(address a) external view returns (bool) {
        return a == currentCeo;
    }

    function isEndorserActive(address a) external view returns (bool) {
        return isEndorser[a];
    }
}
