// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./libraries/VotingLib.sol";
import "./libraries/Errors.sol";
import "./libraries/PriceLib.sol";

/**
 * @title InvUsdToken
 * @dev A simple ERC20 token contract for INV-USD, mintable and burnable only by its owner (the DAO).
 * This token is non-transferable between users and can only be sent back to the DAO.
 */
contract InvUsdToken is ERC20 {
    address public owner;

    constructor() ERC20("INVTRON USD", "INV-USD") {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.OnlyDao();
        _;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /**
     * @dev Overrides the core _update function to enforce spending restrictions.
     * INV-USD can only be transferred back to the DAO contract that owns it.
     * This prevents user-to-user trading and keeps it as a utility voucher.
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        // This custom logic is checked before the actual transfer happens.
        // Allow minting (from address(0)) and burning (to address(0))
        if (from != address(0) && to != address(0)) {
            // The DAO contract (owner) can move tokens freely, for example when calling burnFrom.
            if (msg.sender != owner) {
                // Any other transfer initiated by a user MUST be to the DAO contract.
                if (to != owner) revert Errors.InvalidExchangeRecipient();
            }
        }
        
        // After checking, call the original logic from the parent ERC20 contract
        super._update(from, to, amount);
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
contract INVTRON_DAO is ERC20, ERC20Permit, ERC20Votes, AccessControl {

    // --- Roles ---
    bytes32 public constant CEO_ROLE = keccak256("CEO_ROLE");
    bytes32 public constant ENDORSER_ROLE = keccak256("ENDORSER_ROLE");

    // Track the single active CEO
    address public currentCeo;
    // Track an elected CEO waiting for activation
    address public electedCeo;
    // Timestamp when the CEO was elected and ready for activation
    uint256 public electedCeoTimestamp;

    // Simple whitelist mapping
    mapping(address => bool) private _whitelisted;


    // --- External Contracts & Feeds ---
    InvUsdToken public invUsdToken;
    AggregatorV3Interface internal priceFeed;
    uint8 private priceFeedDecimals;
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
    uint256 public constant ELECTED_CEO_ACTIVATION_DELAY = 360 hours;
    bytes32 public constant DELEGATE_VP_TYPEHASH =
        keccak256("DelegateVP(address delegatee,uint256 nonce,uint256 deadline)");

    // --- State Variables for Exchange Limits ---
    // Each funding request can have its own daily exchange cap expressed in
    // INV-USD. By default the limit is zero, meaning exchanges are disabled
    // until the CEO specifies a limit for that request.
    mapping(uint256 => uint256) public dailyExchangeLimit;
    mapping(uint256 => uint256) public dailyExchangedAmount;
    mapping(uint256 => uint256) public lastExchangeDay;
    mapping(uint256 => uint256) public remainingToExchange;

    // --- State Variables for Proposal Storage ---
    uint256 public nextCeoApplicationId;
    uint256 public nextFundingRequestId;

    mapping(uint256 => CeoApplication) public ceoApplications;
    mapping(uint256 => FundingRequest) public fundingRequests;

    // --- State Variables for Vote Tracking (Externalized from Structs) ---
    mapping(uint256 => mapping(address => bool)) public ceoEndorsersVoted;
    mapping(uint256 => mapping(address => bool)) public ceoUsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingEndorsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUsersVoted;
    mapping(uint256 => mapping(address => bool)) public fundingUserVoteChoice;
    mapping(uint256 => mapping(address => bool)) public rewardClaimed;

    // Track active applications per address to prevent duplicates
    mapping(address => uint256) public activeCeoApplication;
    mapping(address => CeoStatus) public ceoStatus;

    // --- Dynamic Endorser Leaderboard ---
    uint256 public constant MAX_ACTIVE_ENDORSERS = 50;

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

    mapping(address => EndorserCandidate) public endorserCandidates;
    mapping(address => address) public endorserVotes; // voter => candidate
    address[] private _activeEndorserList;
    address public lowestActiveEndorser;

    // --- State Variables for Rate-Limiting & Token-Locking ---
    mapping(address => uint256) public recentVoteTimestamps;
    mapping(address => uint256) public tokenUnlockTime;
    mapping(address => address) public votingDelegate;

    modifier onlyWhitelisted() {
        if (!isWhitelisted(msg.sender)) revert Errors.NotWhitelisted();
        _;
    }

    // --- Proposal Structs (Mappings Removed) ---
    enum ProposalStatus { Pending, Active, Succeeded, Defeated, Executed }

    enum CeoStatus { None, Nominated, Elected, Active }

    struct CeoApplication {
        address applicant;
        PersonalInfo info;
        uint256 endorserVotes;
        uint256 userVotesFor;
        uint256 userVotesAgainst;
        uint256 deadline;
        ProposalStatus status;
    }


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
        uint256 endorserVotes;
        uint256 userVotesFor;
        uint256 userVotesAgainst;
        uint256 deadline;
        ProposalStatus status;
        bool ceoApproved;
    }

    // --- Events ---
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
    event ProposalStatusUpdated(uint256 id, ProposalStatus status);
    event Exchanged(address indexed user, uint256 invUsdAmount, uint256 invAmount);
    event RewardClaimed(address indexed voter, uint256 amount);
    event DailyLimitSet(uint256 indexed requestId, uint256 newLimit);
    event EndorserCandidateRegistered(address indexed candidate);
    event EndorserVoteChanged(address indexed voter, address indexed candidate, uint256 weight);
    event EndorserChallengeSuccess(address indexed candidate, address indexed replaced);
    event FundingRequestApproved(uint256 indexed id);
    event VotingPowerDelegated(address indexed delegator, address indexed delegatee);

    /**
     * @dev Initializes all parent contracts and sets up initial DAO state.
     */
    constructor(
        address _priceFeedAddress,
        address _initialCeo,
        address[] memory _initialEndorsers,
        address _treasuryOwner
    )
        ERC20("INVTRON", "INV")
        ERC20Permit("INVTRON")
        ERC20Votes()
    {
        // Deploy the internal INV-USD token
        invUsdToken = new InvUsdToken();

        // Grant admin and initial roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CEO_ROLE, _initialCeo);
        _grantRole(DEFAULT_ADMIN_ROLE, _initialCeo);
        _setRoleAdmin(CEO_ROLE, CEO_ROLE);
        _setRoleAdmin(ENDORSER_ROLE, CEO_ROLE);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        ceoStatus[_initialCeo] = CeoStatus.Active;
        currentCeo = _initialCeo;
        if (_initialEndorsers.length > MAX_ACTIVE_ENDORSERS) {
            revert Errors.TooManyInitialEndorsers();
        }
        for (uint256 i = 0; i < _initialEndorsers.length; i++) {
            _grantRole(ENDORSER_ROLE, _initialEndorsers[i]);
            endorserCandidates[_initialEndorsers[i]].registered = true;
            endorserCandidates[_initialEndorsers[i]].active = true;
            _activeEndorserList.push(_initialEndorsers[i]);
        }
        lowestActiveEndorser = VotingLib.findLowestActiveEndorser(_activeEndorserList, getVotes);

        // Set external feeds
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        priceFeedDecimals = priceFeed.decimals();
        treasuryOwner = _treasuryOwner;

        // Mint initial governance token supply (1 billion tokens as per white paper)
        _mint(msg.sender, 1_000_000_000 * 10**decimals());
    }

    // --- Role Management & Applications ---

    /// @notice Add or remove an address from the DAO whitelist.
    /// @param user Address to update.
    /// @param value True to whitelist the address, false to remove it.
    function makeWhitelisted(address user, bool value) external onlyRole(CEO_ROLE) {
        _whitelisted[user] = value;
        if (value) {
            emit Whitelisted(user);
        }
    }

    /// @notice Check if an address has been whitelisted by the DAO.
    /// @param user Address to query.
    /// @return True if the address is allowed to participate in proposals.
    function isWhitelisted(address user) public view returns (bool) {
        return _whitelisted[user];
    }

    /// @notice Update the address that collects application fees.
    /// @param newOwner The new treasury address.
    function setTreasuryOwner(address newOwner) external onlyRole(CEO_ROLE) {
        if (newOwner == address(0)) revert Errors.TreasuryOwnerZero();
        treasuryOwner = newOwner;
    }

    /// @notice Set a new Chainlink price feed for INV/USD.
    /// @param newFeed Address of the price feed contract.
    function setPriceFeed(address newFeed) external onlyRole(CEO_ROLE) {
        if (newFeed == address(0)) revert Errors.InvalidFeedAddress();
        priceFeed = AggregatorV3Interface(newFeed);
        priceFeedDecimals = priceFeed.decimals();
    }


    /// @notice Submit yourself as a candidate for the CEO role.
    /// @dev Requires the caller to be whitelisted and to hold a minimum amount
    ///      of INV tokens equivalent to $25,000.
    function applyForCeo(PersonalInfo calldata info) external {
        if (!isWhitelisted(msg.sender)) revert Errors.ApplicantNotWhitelisted();
        if (electedCeo != address(0)) revert Errors.ElectedCeoPending();
        if (ceoStatus[msg.sender] != CeoStatus.None) revert Errors.CeoApplicationExists();

        int currentPrice = getLatestPrice();
        uint256 userValue = (balanceOf(msg.sender) * uint256(currentPrice)) / 1e18;
        if (userValue < CEO_REQUIRED_BALANCE_USD) revert Errors.InsufficientInvBalance();

        uint256 feeInInv = (CEO_APPLICATION_FEE * 1e18) / uint256(currentPrice);

        // Correctly spend the allowance granted to this contract
        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        uint256 id = nextCeoApplicationId++;
        CeoApplication storage app = ceoApplications[id];
        app.applicant = msg.sender;
        app.info = info;
        app.deadline = block.timestamp + VOTING_PERIOD;
        app.status = ProposalStatus.Pending;
        activeCeoApplication[msg.sender] = id;
        ceoStatus[msg.sender] = CeoStatus.Nominated;
        emit CeoApplicationCreated(id, msg.sender);
    }

    // --- Funding Requests ---

    /// @notice Propose a new funding request payable in INV-USD.
    /// @param details Struct containing all project information:
    ///  - projectName: name of the project
    ///  - softCapAmount: minimum amount targeted in INV-USD
    ///  - hardCapAmount: maximum amount targeted in INV-USD
    ///  - valuation: company valuation in USD
    ///  - country: country of registration
    ///  - websiteUrl: project website URL
    ///  - ceoLinkedInUrl: CEO LinkedIn profile URL
    ///  - shortDescription: brief summary of the project
    ///  - companyRegistrationUrl: link to company registration proof
    /// @dev A small fee in INV is charged and transferred to the treasury.
    function createFundingRequest(FundingDetails calldata details)
        external
        onlyWhitelisted
    {
        int currentPrice = getLatestPrice();
        uint256 feeInInv = (FUNDING_REQUEST_FEE * 1e18) / uint256(currentPrice);
        
        // Correctly spend the allowance granted to this contract
        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        uint256 id = nextFundingRequestId++;
        FundingRequest storage req = fundingRequests[id];
        req.proposer = msg.sender;
        req.details = details;
        req.amount = details.softCapAmount;
        req.deadline = block.timestamp + VOTING_PERIOD;
        req.status = ProposalStatus.Pending;
        emit FundingRequestCreated(
            id,
            msg.sender,
            details.projectName,
            details.softCapAmount,
            details.hardCapAmount
        );
    }

    // --- Endorser Leaderboard ---

    /// @notice Register the caller as a potential endorser candidate.
    /// @dev Charges a small application fee which is sent to the treasury.
    function registerEndorserCandidate(PersonalInfo calldata info) external onlyWhitelisted {
        if (endorserCandidates[msg.sender].registered) revert Errors.AlreadyRegistered();

        int currentPrice = getLatestPrice();
        uint256 feeInInv = (ENDORSER_APPLICATION_FEE * 1e18) / uint256(currentPrice);
        _spendAllowance(msg.sender, address(this), feeInInv);
        _transfer(msg.sender, treasuryOwner, feeInInv);

        EndorserCandidate storage cand = endorserCandidates[msg.sender];
        cand.registered = true;
        cand.info = info;
        emit EndorserCandidateRegistered(msg.sender);
    }

    /// @notice Vote for an endorser candidate using the caller's voting power.
    /// @param candidate Address of the candidate being supported.
    function voteForEndorser(address candidate) external {
        if (!endorserCandidates[candidate].registered) revert Errors.CandidateNotRegistered();
        if (getVotes(msg.sender) == 0) revert Errors.NoVotingPower();

        endorserVotes[msg.sender] = candidate;
        delegate(candidate);
        emit EndorserVoteChanged(msg.sender, candidate, getVotes(msg.sender));
        lowestActiveEndorser = VotingLib.findLowestActiveEndorser(_activeEndorserList, getVotes);
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
        bytes32 structHash = keccak256(
            abi.encode(DELEGATE_VP_TYPEHASH, delegatee, nonce, deadline)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        if (nonce != _useNonce(signer)) revert Errors.InvalidNonce();
        votingDelegate[signer] = delegatee;
        emit VotingPowerDelegated(signer, delegatee);
    }

    /// @notice Attempt to join the active endorser set by displacing the weakest member.
    /// @param candidate Address of the registered candidate trying to join.
    function challengeEndorser(address candidate) external {
        if (!endorserCandidates[candidate].registered) revert Errors.CandidateNotRegistered();
        if (endorserCandidates[candidate].active) revert Errors.CandidateAlreadyActive();

        if (_activeEndorserList.length < MAX_ACTIVE_ENDORSERS) {
            _activeEndorserList.push(candidate);
            endorserCandidates[candidate].active = true;
            _grantRole(ENDORSER_ROLE, candidate);
            lowestActiveEndorser = VotingLib.findLowestActiveEndorser(_activeEndorserList, getVotes);
            emit EndorserChallengeSuccess(candidate, address(0));
            return;
        }

        address weakest = lowestActiveEndorser;
        if (getVotes(candidate) <= getVotes(weakest)) revert Errors.NotEnoughVotes();

        // Replace weakest endorser
        for (uint256 i = 0; i < _activeEndorserList.length; i++) {
            if (_activeEndorserList[i] == weakest) {
                _activeEndorserList[i] = candidate;
                break;
            }
        }
        endorserCandidates[weakest].active = false;
        _revokeRole(ENDORSER_ROLE, weakest);

        endorserCandidates[candidate].active = true;
        _grantRole(ENDORSER_ROLE, candidate);
        lowestActiveEndorser = VotingLib.findLowestActiveEndorser(_activeEndorserList, getVotes);
        emit EndorserChallengeSuccess(candidate, weakest);
    }


    /**
     * @dev Returns the full list of active endorsers.
     */
    function activeEndorserList() public view returns (address[] memory) {
        return _activeEndorserList;
    }


    // --- Voting Functions ---

    /// @notice Endorsers cast their vote on a pending CEO application.
    /// @param id Identifier of the CEO application.
    function voteOnCeoByEndorser(uint256 id) external onlyRole(ENDORSER_ROLE) {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalStatus.Pending) revert Errors.CeoProposalNotPending();
        if (ceoEndorsersVoted[id][msg.sender]) revert Errors.EndorserAlreadyVoted();
        ceoEndorsersVoted[id][msg.sender] = true;
        app.endorserVotes++;
        if (app.endorserVotes >= ENDORSER_VOTES_FOR_CEO_PASS) {
            app.status = ProposalStatus.Active;
            app.deadline = block.timestamp + VOTING_PERIOD;
            emit ProposalStatusUpdated(id, ProposalStatus.Active);
        }
    }

    /// @notice Endorsers vote on a funding request before it is opened to all users.
    /// @param id Identifier of the funding request.
    function voteOnFundingByEndorser(uint256 id) external onlyRole(ENDORSER_ROLE) {
        FundingRequest storage req = fundingRequests[id];
        if (req.status != ProposalStatus.Pending) revert Errors.FundingProposalNotPending();
        if (fundingEndorsersVoted[id][msg.sender]) revert Errors.FundingEndorserAlreadyVoted();
        fundingEndorsersVoted[id][msg.sender] = true;
        req.endorserVotes++;
        if (req.endorserVotes >= ENDORSER_VOTES_FOR_FUNDING_PASS) {
            req.status = ProposalStatus.Active;
            req.deadline = block.timestamp + VOTING_PERIOD;
            emit ProposalStatusUpdated(id, ProposalStatus.Active);
        }
    }

    /// @notice Cast a user vote on an active CEO application.
    /// @param id Identifier of the CEO application.
    /// @param inFavor True to vote in favour, false to vote against.
    /// @param tokenHolder Address whose voting power is used (can be a delegate).
    function voteOnCeoByUser(uint256 id, bool inFavor, address tokenHolder) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalStatus.Active) revert Errors.CeoProposalNotActive();
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
        if (app.applicant == voter) revert Errors.ApplicantSelfVote();
        if (ceoUsersVoted[id][voter]) revert Errors.CeoUserAlreadyVoted();
        ceoUsersVoted[id][voter] = true;
        if (inFavor) app.userVotesFor += power;
        else app.userVotesAgainst += power;
        emit Voted(id, voter, inFavor, power);
    }

    /// @notice Users vote on a funding request using their delegated voting power.
    /// @param id Identifier of the funding request.
    /// @param inFavor True to vote in favour, false otherwise.
    /// @param tokenHolder Address whose votes will be counted.
    function voteOnFundingByUser(uint256 id, bool inFavor, address tokenHolder) external {
        FundingRequest storage req = fundingRequests[id];
        if (req.status != ProposalStatus.Active) revert Errors.FundingProposalNotActiveUser();
        if (block.timestamp >= req.deadline) revert Errors.FundingVotingEnded();
        (address voter, uint256 power) = VotingLib.prepareDelegatedVote(
            votingDelegate,
            tokenUnlockTime,
            recentVoteTimestamps,
            getVotes,
            TOKEN_LOCK_DURATION,
            msg.sender,
            tokenHolder
        );
        if (fundingUsersVoted[id][voter]) revert Errors.FundingUserAlreadyVoted();

        power = VotingLib.getVotingValue(balanceOf, getLatestPrice, voter, req.amount);
        fundingUsersVoted[id][voter] = true;
        fundingUserVoteChoice[id][voter] = inFavor;
        if (inFavor) req.userVotesFor += power;
        else req.userVotesAgainst += power;
        emit Voted(id, voter, inFavor, power);
    }

    /// @dev Records a vote and locks the voter's tokens for a short period.

    // --- Finalization ---

    /// @notice Conclude an active CEO election once its voting period has ended.
    /// @param id Identifier of the CEO application.
    function finalizeCeoVote(uint256 id) external {
        CeoApplication storage app = ceoApplications[id];
        if (app.status != ProposalStatus.Active) revert Errors.CeoProposalNotActiveFinalization();
        if (block.timestamp < app.deadline) revert Errors.CeoVotingActive();

        if (app.userVotesFor > app.userVotesAgainst) {
            app.status = ProposalStatus.Succeeded;
            ceoStatus[app.applicant] = CeoStatus.Elected;
            electedCeo = app.applicant;
            electedCeoTimestamp = block.timestamp;
        } else {
            app.status = ProposalStatus.Defeated;
            ceoStatus[app.applicant] = CeoStatus.None;
        }
        emit ProposalStatusUpdated(id, app.status);
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
        _grantRole(CEO_ROLE, newCeo);
    }

    /// @notice CEO approval required before a passed funding request can mint tokens.
    /// @param id Identifier of the funding request.
    function releaseFundingRequest(uint256 id) external onlyRole(CEO_ROLE) {
        FundingRequest storage req = fundingRequests[id];
        if (req.status != ProposalStatus.Active) revert Errors.FundingProposalNotActive();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActive();
        if (req.userVotesFor <= req.userVotesAgainst) revert Errors.FundingProposalFailed();
        if (req.ceoApproved) revert Errors.FundingRequestAlreadyApproved();
        req.ceoApproved = true;
        emit FundingRequestApproved(id);
        emit ProposalStatusUpdated(id, req.status);
    }


    /// @notice Mint INV-USD to the proposer after a successful vote and CEO approval.
    /// @param id Identifier of the funding request.
    function executeFundingRequest(uint256 id) external {
        FundingRequest storage req = fundingRequests[id];
        if (req.status != ProposalStatus.Active) revert Errors.FundingProposalNotActiveExecution();
        if (block.timestamp < req.deadline) revert Errors.FundingVotingActiveExecution();
        if (req.userVotesFor <= req.userVotesAgainst) revert Errors.FundingProposalFailed();
        if (!req.ceoApproved) revert Errors.FundingRequestNotApproved();

        req.status = ProposalStatus.Executed;
        invUsdToken.mint(req.proposer, req.amount);
        remainingToExchange[id] = req.amount;
        emit ProposalStatusUpdated(id, ProposalStatus.Executed);
    }

    /// @notice Claim voting rewards for a funding proposal once it is finalized.
    /// @param fundingRequestId Identifier of the funding request.
    function claimReward(uint256 fundingRequestId) external {
        FundingRequest storage req = fundingRequests[fundingRequestId];
        if (!(req.status == ProposalStatus.Executed || req.status == ProposalStatus.Defeated)) {
            revert Errors.ProposalNotFinalized();
        }
        if (!fundingUsersVoted[fundingRequestId][msg.sender]) revert Errors.AddressDidNotVote();
        if (rewardClaimed[fundingRequestId][msg.sender]) revert Errors.RewardAlreadyClaimed();
        bool votedFor = fundingUserVoteChoice[fundingRequestId][msg.sender];
        bool correct = (req.status == ProposalStatus.Executed && votedFor) ||
            (req.status == ProposalStatus.Defeated && !votedFor);
        if (!correct) revert Errors.VoteMismatch();
        uint256 reward = balanceOf(msg.sender) / 20000;
        rewardClaimed[fundingRequestId][msg.sender] = true;
        address delegatee = votingDelegate[msg.sender];
        if (delegatee != address(0)) {
            uint256 holderShare = (reward * 70) / 100;
            uint256 delegateShare = reward - holderShare;
            _mint(msg.sender, holderShare);
            _mint(delegatee, delegateShare);
        } else {
            _mint(msg.sender, reward);
        }
        emit RewardClaimed(msg.sender, reward);
    }

    // --- Exchange & Admin ---

    /// @notice Limit how much INV-USD can be converted back to INV each day for a request.
    /// @param requestId The funding request to configure.
    /// @param limitPercent Percentage of the total amount that may be exchanged per day.
    function setDailyExchangeLimit(uint256 requestId, uint256 limitPercent)
        external
        onlyRole(CEO_ROLE)
    {
        FundingRequest storage req = fundingRequests[requestId];
        if (req.status != ProposalStatus.Executed) revert Errors.FundingRequestNotExecuted();
        uint256 limit = (req.amount * limitPercent) / 100;
        dailyExchangeLimit[requestId] = limit;
        emit DailyLimitSet(requestId, limit);
    }

    /// @notice Exchange previously minted INV-USD back into INV governance tokens.
    /// @param requestId The funding request being converted.
    /// @param invUsdAmount Amount of INV-USD to exchange.
    function exchangeInvUsdForInv(uint256 requestId, uint256 invUsdAmount) external {
        FundingRequest storage req = fundingRequests[requestId];
        if (req.status != ProposalStatus.Executed) revert Errors.FundingRequestNotExecuted();
        if (msg.sender != req.proposer) revert Errors.OnlyProposer();
        if (dailyExchangeLimit[requestId] == 0) revert Errors.ExchangeDisabled();
        if (remainingToExchange[requestId] < invUsdAmount) revert Errors.AmountExceedsRemaining();

        uint256 today = block.timestamp / 1 days;
        if (lastExchangeDay[requestId] != today) {
            lastExchangeDay[requestId] = today;
            dailyExchangedAmount[requestId] = 0;
        }
        if (dailyExchangedAmount[requestId] + invUsdAmount > dailyExchangeLimit[requestId]) {
            revert Errors.ExceedsDailyLimit();
        }

        // Note: The user must first call `approve()` on the INV-USD token contract,
        // giving this DAO contract an allowance to spend on their behalf.
        invUsdToken.burnFrom(msg.sender, invUsdAmount);
        uint256 invAmount = (invUsdAmount * 1e18) / uint256(getLatestPrice());
        _mint(msg.sender, invAmount);
        dailyExchangedAmount[requestId] += invUsdAmount;
        remainingToExchange[requestId] -= invUsdAmount;
        emit Exchanged(msg.sender, invUsdAmount, invAmount);
    }

    // --- Helpers ---

    /**
     * @notice Fetch the latest INV/USD price from the configured oracle.
     * @dev Scales the returned value to 18 decimals and reverts if the feed is stale.
     */
    function getLatestPrice() public view returns (int) {
        return PriceLib.getLatestPrice(priceFeed, priceFeedDecimals);
    }

    /// @notice Helper to calculate the USD value of a user's INV holdings.
    /// @param user Address to query.
    /// @return USD value scaled to 18 decimals.
    function getInvValueInUsd(address user) public view returns (uint256) {
        return
            PriceLib.getInvValueInUsd(
                balanceOf,
                priceFeed,
                priceFeedDecimals,
                user
            );
    }
    
    // --- Required Multi-Inheritance Overrides ---

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        if (from != address(0)) {
            if (block.timestamp < tokenUnlockTime[from]) revert Errors.TokensLocked();
        }
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        if (role == CEO_ROLE && currentCeo != address(0) && currentCeo != account) {
            super._revokeRole(CEO_ROLE, currentCeo);
            ceoStatus[currentCeo] = CeoStatus.None;
        }
        if (role == CEO_ROLE) {
            currentCeo = account;
        }
        granted = super._grantRole(role, account);
        return granted;
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        revoked = super._revokeRole(role, account);
        if (role == CEO_ROLE && currentCeo == account) {
            currentCeo = address(0);
            ceoStatus[account] = CeoStatus.None;
        }
        return revoked;
    }
}