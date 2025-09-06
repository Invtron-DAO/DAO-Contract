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
import "./interfaces/IFundingManager.sol";
import "./InvUsdToken.sol";
import "./WhitelistManager.sol";
import "./CeoManager.sol";
import "./ExchangeManager.sol";

/// @dev Minimal live-votes delegation (no checkpoints, no past-block reads).
/// - Voting power mirrors current balances of delegatees.
/// - Exposes ERC20Votes-like names: delegates(), getVotes(), delegate().
enum VoteType { Ceo, Funding }

abstract contract __MinimalVotes {
    mapping(address => address) internal __delegates;     // delegator => delegatee (0 => self)
    mapping(address => uint256) internal __votingPower;   // current power per delegatee

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    function delegates(address account) public view returns (address) {
        return __delegates[account]; // no default self-delegation
    }

    function getVotes(address account) public view returns (uint256) {
        return __votingPower[account];
    }

    function _delegate(address delegator, address to) internal {
        address fromDel = __delegates[delegator];
        address toDel = to; // allow clearing to zero
        if (fromDel == toDel) return;
        __delegates[delegator] = toDel;
        emit DelegateChanged(delegator, fromDel, toDel);

        uint256 bal = _balanceOfForVotes(delegator);
        if (fromDel != address(0)) {
            uint256 prevFrom = __votingPower[fromDel];
            __votingPower[fromDel] = prevFrom - bal;
            emit DelegateVotesChanged(fromDel, prevFrom, prevFrom - bal);
        }
        if (toDel != address(0)) {
            uint256 prevTo = __votingPower[toDel];
            __votingPower[toDel] = prevTo + bal;
            emit DelegateVotesChanged(toDel, prevTo, prevTo + bal);
        }
    }

    function delegate(address to) public virtual {
        _delegate(msg.sender, to);
    }

    /// @dev Must be implemented by the token to expose balances for votes accounting.
    function _balanceOfForVotes(address account) internal view virtual returns (uint256);

    /// @dev Call this after any token balance change affecting `owner`.
    function _afterTokenBalanceChange(address owner, uint256 oldBal, uint256 newBal) internal {
        if (newBal == oldBal) return;
        address del = __delegates[owner];
        if (del == address(0)) return;
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

    // -------- Amount-aware helpers (same-type clamping) --------
    /// @notice Tokens not locked for CEO voting, for this holder.
    function freeTokensForCeo(address user) public view returns (uint256) {
        uint256 bal = balanceOf(user);
        // Treat expired locks as zero to avoid post-expiry undercount on first re-vote.
        uint256 req = (block.timestamp < tokenUnlockTimeForCeoVote[user])
            ? lockedBalanceForCeoVote[user]
            : 0;
        return bal > req ? bal - req : 0;
    }

    /// @notice Cross-type headroom: additional tokens that can still be locked now.
    /// @dev Treats expired locks as zero for both types; prevents "free votes" when sum==balance.
    function freeHeadroomTokens(address user) public view returns (uint256) {
        uint256 bal = balanceOf(user);
        uint256 ceoReq = (block.timestamp < tokenUnlockTimeForCeoVote[user])
            ? lockedBalanceForCeoVote[user]
            : 0;
        uint256 fundReq = (block.timestamp < tokenUnlockTimeForFundingVote[user])
            ? lockedBalanceForFundingVote[user]
            : 0;
        uint256 used = ceoReq + fundReq;
        if (bal <= used) return 0;
        return bal - used;
    }

    /// @notice Tokens not locked for Funding voting, for this holder.
    function freeTokensForFunding(address user) public view returns (uint256) {
        uint256 bal = balanceOf(user);
        // Treat expired locks as zero to avoid post-expiry undercount on first re-vote.
        uint256 req = (block.timestamp < tokenUnlockTimeForFundingVote[user])
            ? lockedBalanceForFundingVote[user]
            : 0;
        return bal > req ? bal - req : 0;
    }


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
    // Funding vote state moved to FundingManagerContract

    // Track active applications per address to prevent duplicates
    mapping(address => uint256) public activeCeoApplication;

    // --- Dynamic Endorser Leaderboard ---
    uint256 public constant MAX_ACTIVE_ENDORSERS = 50;

    mapping(address => EndorserLib.EndorserCandidate) public endorserCandidates;
    mapping(address => address) public endorserVotes; // voter => candidate
    // Independent support weights for endorsers, separate from delegation
    mapping(address => uint256) public endorserSupport;
    // Track last recorded voter weight to adjust support when changing votes
    mapping(address => uint256) public endorserVoterWeight;
    address[] private _activeEndorserList;
    address public lowestActiveEndorser;

    // --- State Variables for Rate-Limiting & Token-Locking ---
    mapping(address => uint256) public recentVoteTimestamps;
    
    // --- State Variables for Vote-Specific Locking ---
    mapping(address => uint256) public tokenUnlockTimeForCeoVote;
    mapping(address => uint256) public tokenUnlockTimeForFundingVote;
    mapping(address => uint256) public lockedBalanceForCeoVote;
    mapping(address => uint256) public lockedBalanceForFundingVote;
    mapping(address => address) public votingDelegate;

    // Weighted-average acquisition timestamp of each holder's balance
    mapping(address => uint256) public balanceAge;

    using TokenHolderLib for TokenHolderLib.State;
    TokenHolderLib.State private _tokenHolderState;

    // --- Supply Tracking ---
    // Running total of tokens locked by voting snapshots (sum of lockedBalanceRequirement for active locks)
    uint256 public totalLockedTokens;

    // --- Hooks required by ExchangeManager ---
    function _totalSupply() internal view override returns (uint256) {
        return totalSupply();
    }

    // Vesting removed: no vested-supply hook required.

    function _getTotalTokensLocked() internal view override returns (uint256) {
        return totalLockedTokens;
    }

    function _balanceOfForVotes(address account) internal view override returns (uint256) {
        // Decoupled from locks: full balance counts toward delegated voting power.
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
        address _whitelistManager,
        address _fundingManager
    )
        ERC20("INVTRON", "INV")
        EIP712("INVTRON", "1")
    {
        invUsdToken = InvUsdToken(_invUsdToken);
        whitelistManager = WhitelistManager(_whitelistManager);
        fundingManager = IFundingManager(_fundingManager);

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
        // lowestActiveEndorser left default to save code size

        // Set external feeds
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        treasuryOwner = _treasuryOwner;
        lastPrice = PriceLib.getLatestPrice(priceFeed);

        // Mint initial governance token supply (1 billion tokens as per white paper)
        _mint(msg.sender, 1_000_000_000 * 10**decimals());
    }

    // --- Manager hooks for FundingManagerContract ---
    function getLatestUsdPrice() external view returns (int) {
        return PriceLib.getLatestPrice(priceFeed);
    }

    function prepareFundingVote(address caller, address tokenHolder) external returns (address voter) {

        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        (voter, ) = VotingLib.prepareDelegatedVote(
            votingDelegate,
            tokenUnlockTimeForFundingVote, // Use funding-specific unlock time
            recentVoteTimestamps,
            getVotes,
            TOKEN_LOCK_DURATION,
            caller,
            tokenHolder
        );
    }

    function lockTokensForFunding(address voter, uint256 amount) external {
        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        _snapshotLock(voter, amount, VoteType.Funding);
    }

    function getDelegate(address voter) external view returns (address) {
        return votingDelegate[voter];
    }

    function mintGovByManager(address to, uint256 amount) external {
        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        if (to == address(0) || amount == 0) return; // safe no-op
        _mint(to, amount);
    }

    function mintInvUsdByManager(address to, uint256 amount) external {
        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        invUsdToken.mint(to, amount);
    }

    function seedExchangeRemaining(uint256 id, uint256 amount) external {
        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        remainingToExchange[id] = amount;
    }

    function collectInvFee(address from, uint256 amount) external {
        if (msg.sender != address(fundingManager)) revert Errors.OnlyFundingManager();
        _spendAllowance(from, address(this), amount);
        _transfer(from, treasuryOwner, amount);
    }

    // --- Role Management & Applications ---

    /// @notice Update the address that collects application fees.
    /// @param newOwner The new treasury address.
    function setTreasuryOwner(address newOwner) external onlyCEO {
        if (newOwner == address(0)) revert Errors.TreasuryOwnerZero();
        treasuryOwner = newOwner;
    }

    // Note: vesting accounting fully removed.


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
    // moved to FundingManagerContract

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
        if (msg.sender == candidate) revert Errors.SelfVoting();
        uint256 weight = EndorserLib.voteForCandidate(
            endorserCandidates,
            endorserVotes,
            msg.sender,
            candidate,
            balanceOf,
            endorserSupport,
            endorserVoterWeight
        );
        // No delegation occurs here; endorsement support is tracked separately
        emit EndorserLib.EndorserVoteChanged(msg.sender, candidate, weight);
    }

    function delegate(address delegatee) public override {
        bool isCeoLocked = block.timestamp < tokenUnlockTimeForCeoVote[msg.sender];
        bool isFundingLocked = block.timestamp < tokenUnlockTimeForFundingVote[msg.sender];
        if (isCeoLocked || isFundingLocked) revert Errors.TokensLocked();
        _enforceDelegationRestrictions(msg.sender, delegatee);
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
        bool isCeoLocked = block.timestamp < tokenUnlockTimeForCeoVote[signer];
        bool isFundingLocked = block.timestamp < tokenUnlockTimeForFundingVote[signer];
        if (isCeoLocked || isFundingLocked) revert Errors.TokensLocked();
        _enforceDelegationRestrictions(signer, delegatee);
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

        bool isCeoLocked = block.timestamp < tokenUnlockTimeForCeoVote[signer];
        bool isFundingLocked = block.timestamp < tokenUnlockTimeForFundingVote[signer];
        if (isCeoLocked || isFundingLocked) revert Errors.TokensLocked();

        // Enforce delegation restrictions for vote-by-proxy mapping as well
        _enforceDelegationRestrictions(signer, delegatee);

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
        address replaced = EndorserLib.challengeCandidate(
            endorserCandidates,
            _activeEndorserList,
            candidate,
            MAX_ACTIVE_ENDORSERS,
            endorserSupport
        );
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

    // Funding endorser voting moved to FundingManagerContract

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

    // Funding expiry moved to FundingManagerContract

    /// @notice Cast a user vote on an active CEO application.
    /// @param id Identifier of the CEO application.
    /// @param inFavor True to vote in favour, false to vote against.
    /// @param tokenHolder Address whose voting power is used (can be a delegate).
    function voteOnCeoByUser(uint256 id, bool inFavor, address tokenHolder) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalLib.ProposalStatus.Active) revert Errors.CeoProposalNotActive();
        if (block.timestamp >= app.deadline) revert Errors.CeoVotingEnded();
        (address voter, uint256 powerRaw) = VotingLib.prepareDelegatedVote(
            votingDelegate,
            tokenUnlockTimeForCeoVote, // Use CEO-specific unlock time
            recentVoteTimestamps,
            getVotes,
            TOKEN_LOCK_DURATION,
            msg.sender,
            tokenHolder
        );
        // Clamp by cross-type headroom so each vote that counts must secure lock.
        uint256 head = freeHeadroomTokens(voter);
        uint256 power = powerRaw > head ? head : powerRaw;
        if (power == 0) {
            if (powerRaw > 0) revert Errors.TokensLocked();
            revert Errors.NoVotingPower();
        }

        // Disallow self-vote before touching locks (gas/clarity)
        if (app.applicant == voter) revert Errors.SelfVoting();
        if (ceoUsersVoted[id][voter]) revert Errors.CeoUserAlreadyVoted();

        // Take snapshot lock exactly for the applied amount
        _snapshotLock(voter, power, VoteType.Ceo);
        ceoUsersVoted[id][voter] = true;
        if (inFavor) app.userVotesFor += power;
        else app.userVotesAgainst += power;
        emit EventLib.Voted(id, voter, inFavor, power);
    }

    function _snapshotLock(address voter, uint256 amount, VoteType voteType) internal {
        // If an old lock expired, drop it from the running total
        uint256 prevReq;
        uint256 unlockTime;

        if (voteType == VoteType.Ceo) {
            prevReq = lockedBalanceForCeoVote[voter];
            unlockTime = tokenUnlockTimeForCeoVote[voter];
        } else { // VoteType.Funding
            prevReq = lockedBalanceForFundingVote[voter];
            unlockTime = tokenUnlockTimeForFundingVote[voter];
        }
        if (prevReq != 0 && block.timestamp >= unlockTime) {
            totalLockedTokens -= prevReq;
            prevReq = 0;
            if (voteType == VoteType.Ceo) {
                lockedBalanceForCeoVote[voter] = 0;
            } else {
                lockedBalanceForFundingVote[voter] = 0;
            }
        }
        // Also clear an expired OTHER-TYPE lock to avoid over-clamping this vote.
        uint256 otherReq;
        uint256 otherUnlock;
        if (voteType == VoteType.Ceo) {
            otherReq = lockedBalanceForFundingVote[voter];
            otherUnlock = tokenUnlockTimeForFundingVote[voter];
            if (otherReq != 0 && block.timestamp >= otherUnlock) {
                totalLockedTokens -= otherReq;
                lockedBalanceForFundingVote[voter] = 0;
                otherReq = 0;
            }
        } else {
            otherReq = lockedBalanceForCeoVote[voter];
            otherUnlock = tokenUnlockTimeForCeoVote[voter];
            if (otherReq != 0 && block.timestamp >= otherUnlock) {
                totalLockedTokens -= otherReq;
                lockedBalanceForCeoVote[voter] = 0;
                otherReq = 0;
            }
        }
        // Prevent cross-type over-lock: cap by remaining headroom across both types.
        uint256 bal = balanceOf(voter);
        uint256 used = prevReq + otherReq;
        uint256 available = bal > used ? bal - used : 0;
        if (amount > available) amount = available;
        // Prevent "free vote": if caller requested a positive lock but headroom is zero, revert.
        if (amount == 0) revert Errors.TokensLocked();
        if (amount > 0) {
            totalLockedTokens += amount;
            if (voteType == VoteType.Ceo) {
                lockedBalanceForCeoVote[voter] = prevReq + amount;
            } else {
                lockedBalanceForFundingVote[voter] = prevReq + amount;
            }
        }
    }

    /// @notice Clear your expired voting lock to restore full transferability.
    function unlockYourTokens() external {
        address sender = msg.sender;
        // Check and clear expired CEO vote lock
        uint256 ceoReq = lockedBalanceForCeoVote[sender];
        if (ceoReq > 0 && block.timestamp >= tokenUnlockTimeForCeoVote[sender]) {
            totalLockedTokens -= ceoReq;
            lockedBalanceForCeoVote[sender] = 0;
        }

        // Check and clear expired Funding vote lock
        uint256 fundingReq = lockedBalanceForFundingVote[sender];
        if (fundingReq > 0 && block.timestamp >= tokenUnlockTimeForFundingVote[sender]) {
            totalLockedTokens -= fundingReq;
            lockedBalanceForFundingVote[sender] = 0;
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

    // Funding finalization moved to FundingManagerContract

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

    // Funding release, execution and rewards moved to FundingManagerContract


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
    /// @dev Circulating supply excludes tokens locked by voting snapshots.
    function getCirculatingSupply() external view returns (uint256) {
        return totalSupply() - totalLockedTokens;
    }
    
    // --- Required Multi-Inheritance Overrides ---

    function _daoMint(address account, uint256 amount) internal override {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 oldFrom;
        uint256 oldTo;

        if (from != address(0)) {
            oldFrom = balanceOf(from);
            uint256 fromCeoReq = lockedBalanceForCeoVote[from];
            uint256 fromFundingReq = lockedBalanceForFundingVote[from];
            uint256 ceoUnlock = tokenUnlockTimeForCeoVote[from];
            uint256 fundingUnlock = tokenUnlockTimeForFundingVote[from];

            // Lazily clear expired locks from totals only; voting power stays decoupled.
            // Clear per type individually (no maxUnlockTime gate) so metrics stay fresh.
            if (fromCeoReq != 0 && block.timestamp >= ceoUnlock) {
                totalLockedTokens -= fromCeoReq;
                lockedBalanceForCeoVote[from] = 0;
            }
            if (fromFundingReq != 0 && block.timestamp >= fundingUnlock) {
                totalLockedTokens -= fromFundingReq;
                lockedBalanceForFundingVote[from] = 0;
            }
        }
        if (to != address(0)) {
            oldTo = balanceOf(to);
        }

        if (from != address(0)) {
            // During the lock window, allow spending only the excess over the required minimum
            uint256 totalRequired = lockedBalanceForCeoVote[from] + lockedBalanceForFundingVote[from];
            uint256 latestUnlock = tokenUnlockTimeForCeoVote[from] > tokenUnlockTimeForFundingVote[from] ? tokenUnlockTimeForCeoVote[from] : tokenUnlockTimeForFundingVote[from];
            if (block.timestamp < latestUnlock && totalRequired > 0) {
                // Disallow spending from the locked (snapshot) portion
                uint256 allowed = oldFrom > totalRequired ? oldFrom - totalRequired : 0;
                if (amount > allowed) revert Errors.TokensLocked();
            }
        }

        super._update(from, to, amount);

        // If a voter previously supported an endorser, reduce their recorded
        // support when their balance decreases due to a transfer/burn.
        if (from != address(0)) {
            uint256 newFrom = balanceOf(from);
            if (newFrom < oldFrom) {
                uint256 delta = oldFrom - newFrom;
                address supported = endorserVotes[from];
                if (supported != address(0)) {
                    uint256 prevWeight = endorserVoterWeight[from];
                    uint256 reduce = delta > prevWeight ? prevWeight : delta;
                    if (reduce > 0) {
                        endorserVoterWeight[from] = prevWeight - reduce;
                        uint256 prevSupport = endorserSupport[supported];
                        endorserSupport[supported] = prevSupport >= reduce ? (prevSupport - reduce) : 0;
                        // convenience tracker not updated here to save code size
                    }
                }
            }
        }

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
                balanceAge[from] = 0;
                _tokenHolderState.removeTokenHolder(from);
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
            if (newTo > oldTo) {
                uint256 inc = newTo - oldTo;
                uint256 prevAge = balanceAge[to];
                // weighted-average age of incoming balance
                balanceAge[to] = (prevAge * oldTo + block.timestamp * inc) / newTo;

                // If receiver previously supported an endorser, increase their recorded support
                address supportedTo = endorserVotes[to];
                if (supportedTo != address(0)) {
                    endorserVoterWeight[to] += inc;
                    endorserSupport[supportedTo] += inc;
                    // convenience tracker not updated here to save code size
                }
            }
        }
    }

    function getPastVotes(address account, uint256) public view returns (uint256) {
        return getVotes(account);
    }

    // getPastTotalSupply removed to reduce code size

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

    /// @notice Allow an endorser to renounce their role.
    function renounceEndorserShip() external onlyEndorser {
        // Always remove the core role for any endorser
        isEndorser[msg.sender] = false;

        // If the endorser was active, also clean up their active status and remove them from the list
        if (endorserCandidates[msg.sender].active) {
            endorserCandidates[msg.sender].active = false;

            // Remove from active list
            for (uint256 i = 0; i < _activeEndorserList.length; i++) {
                if (_activeEndorserList[i] == msg.sender) {
                    _activeEndorserList[i] = _activeEndorserList[_activeEndorserList.length - 1];
                    _activeEndorserList.pop();
                    break;
                }
            }
        }
        // Endorser renounced; no event to minimize code size
    }

    // --- Internal helpers ---
    function _enforceDelegationRestrictions(address delegator, address delegatee) internal view {
        // Always allow self-delegation to overwrite existing choices
        if (delegatee == delegator) return;
        // CEOs (Nominated, Elected, Active) cannot delegate to others
        CeoStatus status = ceoStatus[delegator];
        if (status == CeoStatus.Nominated || status == CeoStatus.Elected || status == CeoStatus.Active) {
            revert Errors.CeoCannotDelegateToOthers();
        }
        // Endorsers cannot delegate to others
        if (isEndorser[delegator]) {
            revert Errors.EndorserCannotDelegateToOthers();
        }
    }
}