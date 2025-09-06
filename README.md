# **INVTRON DAO: Comprehensive Smart Contract Guide**

This document provides a complete and detailed guide to interacting with the INVTRON\_DAO smart contract. It covers all functions a user or developer can call, including both the custom logic for the DAO and the standard functions inherited from its OpenZeppelin parent contracts. The project is ready for production use; review the release checklist before deploying to mainnet.

Endorser management, signature-based delegation, token holder tracking, funding requests and event declarations have been moved into dedicated libraries (`EndorserLib`, `DelegateLib`, `TokenHolderLib`, `FundingLib` and `EventLib`) to keep the core contract within the EVM size limit. The INV-USD voucher now lives in its own `InvUsdToken` contract deployed separately so the DAO can stay under the bytecode cap.
Whitelisting requests are handled by a dedicated `WhitelistManager` contract deployed alongside the DAO. All major events are declared in `contracts/libraries/EventLib.sol` and must be emitted from contracts using `emit EventLib.<EventName>`. Whitelisting events are emitted exclusively by `WhitelistManager`; UI or other offchain consumers should monitor `WhitelistManager` events to track whitelist changes.
Core governance logic is split across composable contracts. `CeoManager` contains CEO role and transition mechanics, `FundingManagerContract` (separately deployed) now owns all funding request flows and storage backed by `FundingLib`, and `ExchangeManager` manages INV-USD conversion limits and price feed updates. `INVTRON_DAO` composes these modules and exposes manager-only hooks for minting and vote-lock snapshots.

Note on funding migration:
- The following functions have moved from `INVTRON_DAO` to `FundingManagerContract`: `createFundingRequest`, `voteOnFundingByEndorser`, `voteOnFundingByUser`, `expireFundingRequest`, `finalizeFundingRequest`, `releaseFundingRequest`, `mintTokensForFundingRequest`, `getVotingReward`, and `claimReward`.
- Scripts now deploy `FundingManagerContract`, set `dao` with `setDao(dao)`, and pass its address to the DAO constructor.
- UI should call these funding functions on `FundingManagerContract` instead of the DAO.
Redundant helper functions have been removed from `INVTRON_DAO`. Use `WhitelistManager` for whitelist status, and `PriceLib` for price and valuation helpers to avoid duplicated logic. Token holder enumeration on-chain has been removed; `TokenHolderLib` now tracks holder presence (boolean) only, and the DAO maintains an O(1) running total of locked tokens via `totalLockedTokens`.
Recent security updates include:

- Endorser role assignments can only change via `challengeEndorser`; the CEO no longer administers `ENDORSER_ROLE`.
- Role checks now use minimal storage mappings; OpenZeppelin AccessControl has been removed. Compatibility shims for `CEO_ROLE`, `ENDORSER_ROLE` and `hasRole` remain for integrations.
- CEOs cannot renounce their role until a successor has been elected and is ready for activation.
- INV-USD swaps reject price moves over 10% from the last oracle value and now use reentrancy guards.
- Supply tracking simplified; unswapped accounting has been removed from runtime logic.
- Revoking `CEO_ROLE` requires a ready successor and disallows self-removal; all CEO transitions emit `CeoChanged` events.
- ExchangeManager now exposes `setPriceFeed` for price management (legacy unswapped helpers removed).
- `setPriceFeed` seeds `lastPrice` to avoid stale comparisons and emits `PriceFeedUpdated`.
- Circulating supply excludes locked tokens (no vesting/unswapped buckets).
- Default self-delegation removed: holders must explicitly delegate to gain voting power.
- Lock cleanup is lazy: call `unlockYourTokens()` to clear an expired lock and restore full transferability.
- Voting uses `ERC20Votes` snapshots taken one block prior, requiring voters to retain that balance until the appropriate unlock timestamp (`tokenUnlockTimeForCeoVote` or `tokenUnlockTimeForFundingVote`). Only the excess is transferable and delegation is blocked while either lock remains active.
- Locked tokens provide no voting power; `getVotes` returns only the balance above the locked requirement.
- Historical voting data is available again through `getPastVotes`; voting power is evaluated from these snapshots instead of live balances.
 - Funding request voting power is time-weighted, starting at 0.05% of holdings and rising linearly to 0.5% after 12 months of continuous holding. Each account tracks a weighted-average `balanceAge`, so incoming transfers blend with existing holdings and selling all tokens resets the age.
- Proposers and candidates are prevented from voting on their own funding requests, CEO applications, or endorser candidacies; such attempts revert with `SelfVoting`.
- Rewards are based on the vote amount registered at submission time rather than raw voting power so capped proposals do not overpay.
- Custom errors replace string-based reverts for clearer failure cases and lower gas costs.
- Voting reverts with `InvalidTokenHolder` when a zero delegate is supplied and `TokensAlreadyLocked` if voting before an existing lock expires.
- InvUsdToken ownership transfer rejects the zero address using the `NewOwnerZero` error.
- Funding request creation validates caps and valuation, reverting with `InvalidFundingCaps` or `InvalidValuation`.
- `setDailyExchangeLimit` enforces a 1-100% range via `InvalidLimitPercent`.

Pending CEO applications and funding requests now expire after 72 hours if endorsers do not reach quorum. Anyone may clear these stalled proposals using `expireCeoApplication` or `expireFundingRequest`. Funding votes that fail community approval can be finalized with `finalizeFundingRequest`, enabling voters to claim rewards. Endorser candidates must hold at least $10,000 worth of INV before registering, and whitelist records reset when a user is removed so they can reapply.

Reward payouts record the delegate at the time of voting to prevent reassignment exploits and split delegated vote rewards 90/10 between the token holder and delegatee while the delegatee keeps the full reward from their own voting power. Rewards are based on the vote amount registered at the time of voting, ensuring caps on funding requests limit payouts appropriately. Voting power starts at 0.05% of the voter's USD-denominated holdings and linearly scales to 0.5% after 12 months based on `now - balanceAge`, capped at 10% of the funding request. Rewards are computed as `(registeredVote * 22) / 100` in USD(6) and converted to INV using the current oracle price.

Funding request votes now sum the caller's own voting power and any delegated voting power, each derived from past vote snapshots and priced using a time-weighted rate computed as `balance * f(now - balanceAge)` where `f` scales from 0.05% to 0.5% over 12 months.
Only the portion of tokens backing the capped voting value is locked; any excess remains transferable during the lock period.

Locked tokens accounting has been optimized: the DAO now maintains a running total of locked tokens (`totalLockedTokens`). The public view `getTotalTokensLocked()` returns this counter in O(1). Per-user lock status remains available via `tokenUnlockTimeForCeoVote[user]`, `tokenUnlockTimeForFundingVote[user]`, `lockedBalanceForCeoVote[user]`, and `lockedBalanceForFundingVote[user]`.

## Requirements

- Node.js 20 LTS
- Install dependencies with `npm install`
- Ensure Hardhat plugins like `hardhat-contract-sizer` are installed; rerun `npm install` if a plugin is missing
- Review security warnings with `npm audit` and apply fixes with `npm audit fix`. If vulnerabilities remain, evaluate advisories and run `npm audit fix --force` only after assessing potential breaking changes
- Run the test suite with `npm test`
- Contract size is enforced during compilation; `npx hardhat compile` fails if `INVTRON_DAO` exceeds 24KB
- The Solidity optimizer runs with `runs: 200` and `viaIR: true`


## Quickstart

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
npx hardhat coverage
npx hardhat node
node scripts/dv-test.js
```

Before deploying you will need two environment files:

- `.env` containing `INFURA_PROJECT_ID`, `INFURA_PROJECT_SECRET`, `PRIVATE_KEY` and `ETHERSCAN_API_KEY`.
- `constructor.env` containing `_priceFeedAddress`, `_initialCeo`, `_initialEndorsers`, `_treasuryOwner`.

All of these values must be valid, non-zero Ethereum addresses. The deployment
scripts now verify each entry and will exit with a clear error message if a
required variable is missing or malformed. The deployment scripts also deploy
`InvUsdToken` automatically and transfer ownership to the DAO, so no
`_invUsdToken` entry is required.
For troubleshooting, the deployment scripts (`scripts/dv-test.js` and
`scripts/dv-main.js`) print all constructor arguments before deploying
`INVTRON_DAO` so malformed or zero addresses can be caught early. Each script
broadcasts the DAO deployment transaction and logs the hash immediately, then
waits up to `DEPLOY_TX_TIMEOUT_MS` milliseconds (default `600000`) for
`DEPLOY_CONFIRMATIONS` blocks. If the timeout elapses, they attempt to fetch the
receipt and output an Etherscan link; increase `DEPLOY_TX_TIMEOUT_MS` to wait
longer. This prevents deployments from hanging indefinitely.

These variables are loaded by the scripts in `scripts/` when deploying.

## Release Process

Before going live, follow the [release checklist](RELEASE_CHECKLIST.md).
It covers Node.js version requirements, dependency installation, security
auditing with `npm audit` and guidance on when a forced fix may be necessary,
contract compilation, unit testing, environment configuration, deployment and
documentation updates to ensure the app is production ready.

INV tokens are only minted in three places: the constructor for the initial one
billion supply, the `exchangeInvUsdForInv` function when proposers convert
approved INV-USD, and `claimReward` for voter incentives. Rewards are now
based on the voting power recorded at the time each vote was cast, preventing
manipulation via balance changes. Use `getVotingReward` to preview your payout
once a funding proposal is finalized. All other minting is disabled to keep the
supply in line with governance decisions. INV-USD minting requires both a
successful vote and explicit CEO approval.

## Web UI

A generic front-end is available in the `ui/` folder. Serve the contents of this directory with any static server. After running `scripts/dv-main.js` (mainnet) or `scripts/dv-test.js` (sepolia) the deployed contract addresses are written to `ui/addressInfo.json` and `ui/app.js` reads the `INVTRON_DAO` address from this file automatically. The file also includes addresses for `InvUsdToken`, `WhitelistManager`, and `FundingManagerContract` for convenience. The interface loads the contract ABI from `ui/ABI.json` and automatically generates a form for every read and write function. Additional ABI files (`WL-ABI.json`, `FM-ABI.json`, and `INVUSD-ABI.json`) are generated for other contracts. Both deployment scripts load constructor parameters from `constructor.env` and validate each address (`_priceFeedAddress`, `_initialCeo`, `_initialEndorsers`, `_treasuryOwner`) before broadcasting.

Cap and valuation inputs provided through the UI must be scaled to USDT's 6-decimal format.

The dashboard now also lists the active endorsers and displays their vote totals by calling `activeEndorserList` and `getVotes`.

Additional spacing between the logo and navigation menu has been added for Arabic and Urdu translations to improve readability.

### Updated Interface

The web interface organises contract functions into three tabs labelled **User**, **Endorser** and **CEO**. Selecting a tab now initiates the wallet connection and checks your current role. Roles fall into four categories: **New User**, **Whitelisted User**, **Active Endorser** and **Active CEO**. If the selected tab does not match your role, the interface suggests the correct one. Connection details and your detected role appear at the top of the page.
If the wallet connection fails, the status area displays an error such as `Wallet connection failed: <reason>`.

Boolean parameters now use simple up/down arrow buttons so you can quickly choose **Yes** or **No** without typing.

Function listings now rely on an explicit role map so each tab shows every available action for that role.

The functions are separated into two main categories:

1. **Write Functions:** These modify the contract's state and require a transaction fee (gas).  
2. **Read Functions:** These retrieve data from the blockchain and are free to call.

## **I. Write Functions (State-Changing)**

These functions require a transaction to be submitted to the blockchain. They are grouped by purpose.

### **A. DAO-Specific Actions**

These functions are unique to the INVTRON DAO's logic.

#### **makeWhitelisted** (in `WhitelistManager`)

* **Purpose:** Called by a CEO to add or remove a user from the whitelist.
* **Inputs:**
  * user (address): The wallet address of the user.
  * value (bool): true to whitelist, false to remove.

#### **requestWhitelisting** (in `WhitelistManager`)

* **Purpose:** Allows a non-whitelisted user to submit personal information and request whitelist status.
* **Inputs:**
  * info (tuple): Personal details containing firstName, lastName, mobile, zipCode, city, state, country, bio.

#### **ceoApproveWhitelisting** (in `WhitelistManager`)

* **Purpose:** CEO can approve or reject whitelisting requests.
* **Inputs:**
  * wallets (address[]): Addresses with pending requests.
  * ids (uint256[]): Request IDs to process.
  * approve (bool): true to approve, false to reject.

#### **setDailyExchangeLimit**

* **Purpose:** Called by a CEO to set the daily INV-USD to INV exchange limit for a specific funding request.
* **Inputs:**
  * fundingRequestId (uint256): The ID of the funding request.
  * limitPercent (uint256): Percentage of the request's total amount that can be exchanged each day (1-100).
* **Notes:** Reverts with `InvalidLimitPercent` if `limitPercent` is outside the 1-100 range.

#### **setTreasuryOwner**

* **Purpose:** Updates the address that receives application fees.
* **Inputs:**
  * newOwner (address): The new treasury owner address.

#### **setPriceFeed**

* **Purpose:** Allows the CEO to change the Chainlink price feed if needed.
* **Inputs:**
  * newFeed (address): Address of the new price feed contract.

#### **applyForCeo**

* **Purpose:** Allows a whitelisted user to apply to become a CEO. Requires a fee and a minimum balance.
* **Prerequisite:** The user must first call approve() to give this contract permission to spend the INV token fee.
* **Inputs:** None (personal information is provided during whitelisting).


### **B. Endorser Leaderboard**

These functions implement the permanent leaderboard system for Endorsers.

#### **registerEndorserCandidate**

* **Purpose:** One-time registration for users wishing to appear on the leaderboard. Requires the standard endorser fee.
* **Prerequisite:** The user must be whitelisted and call approve() for the fee.
* **Inputs:** None (personal information is reused from whitelisting).

#### **voteForEndorser**

* **Purpose:** Assigns your current voting power to a registered candidate. Calling again moves your vote to a new candidate.
* **Inputs:**
  * candidate (address): The candidate you want to support.

#### **challengeEndorser**

* **Purpose:** Triggers a check to see if the specified inactive candidate has more votes than the lowest ranked active endorser. If so, they replace that endorser.
* **Inputs:**
  * candidate (address): The candidate to challenge into the Top 50.

#### **createFundingRequest**

* **Purpose:** Allows a whitelisted user to submit a funding proposal. Requires a fee.
* **Prerequisite:** The user must first call approve() to give this contract permission to spend the INV token fee.
* **Inputs:**
  * details (tuple):
    * projectName (string)
    * softCapAmount (uint256, USDT 6 decimals)
    * hardCapAmount (uint256, USDT 6 decimals)
    * valuation (uint256, USDT 6 decimals)
    * country (string)
    * websiteUrl (string)
    * ceoLinkedInUrl (string)
    * shortDescription (string)
    * companyRegistrationUrl (string)
* **Notes:** `softCapAmount` and `hardCapAmount` must be greater than zero with `softCapAmount <= hardCapAmount`, otherwise the call reverts with `InvalidFundingCaps`. `valuation` must be greater than zero or the call reverts with `InvalidValuation`.

#### **voteOnCeoByEndorser**

* **Purpose:** Called by an Endorser to vote on a pending CEO application.  
* **Inputs:**  
  * id (uint256): The unique ID of the CEO application.

#### **voteOnFundingByEndorser**

* **Purpose:** Called by an Endorser to vote on a pending funding request.  
* **Inputs:**  
  * id (uint256): The unique ID of the funding request.

#### **voteOnCeoByUser**

* **Purpose:** Called by any INV token holder to vote on an Active CEO application.
* **Inputs:**
  * id (uint256): The unique ID of the CEO application.
  * inFavor (bool): true for YES, false for NO.
  * tokenHolder (address): Address whose voting power is used. Must be the caller or have delegated via `delegateVPbySig`.


#### **voteOnFundingByUser**

* **Purpose:** Called by any INV token holder to vote on an Active funding request. The vote weight adds the caller's own voting power and any voting power delegated to them. Each component is computed from a snapshot using `getPastVotes` and the latest price, applying a time-weighted rate starting at 0.05% and scaling to 0.5% after 12 months of holding, capped at 10% of the request amount.
* **Inputs:**
  * id (uint256): The unique ID of the funding request.
  * inFavor (bool): true for YES, false for NO.
  * tokenHolder (address): Address whose voting power is used. Must be the caller or have delegated via `delegateVPbySig`.

#### **finalizeCeoVote**

* **Purpose:** Called by anyone after a CEO vote ends to tally the results and grant the role if passed.  
* **Inputs:**  
  * id (uint256): The ID of the CEO application to finalize.

#### **activateElectedCeo**

* **Purpose:** After a successful CEO vote and the activation delay has passed, this function promotes the elected address to CEO.
* **Inputs:**
  * None.

#### **releaseFundingRequest**

* **Purpose:** Called by the CEO after voting ends on a funding request. If the proposal passed, this marks it as CEO approved so it can be executed.
* **Inputs:**
  * id (uint256): The ID of the funding request to approve.

#### **mintTokensForFundingRequest**

* **Purpose:** After a funding vote ends and the CEO has approved the request, this function mints and sends INV-USD to the proposer.
* **Inputs:**
  * id (uint256): The ID of the funding request to execute.

#### **claimReward**

* **Purpose:** Allows a voter to claim PoDD rewards after a funding request is finalized.
* **Reward Formula:** The token holder receives 90% of the vote amount registered when they cast their ballot. This vote amount is the time-weighted portion of their USD balance—0.05% for new holders increasing linearly to 0.5% after 12 months—capped at 10% of the funding request. Rewards are calculated as `(registeredVote * 22) / 100` in USD(6) and converted to INV using the current oracle price. Delegated votes send the remaining 10% to the delegatee, who also retains the full reward from their own voting power.

* **Inputs:**
  * fundingRequestId (uint256): The ID of the funding request the user voted on.

#### **exchangeInvUsdForInv**

* **Purpose:** Allows a proposer to exchange INV-USD for INV tokens, subject to the daily limit of a specific funding request.
* **Prerequisite:** The user must first call approve() on the invUsdToken contract, giving this DAO permission to spend their INV-USD.
* **Inputs:**
  * fundingRequestId (uint256): The funding request the tokens were minted for.
  * invUsdAmount (uint256): The amount of INV-USD to exchange.

#### **expireCeoApplication**

* **Purpose:** Anyone can expire a Pending CEO application after its deadline if endorsers did not reach quorum.
* **Inputs:**
  * id (uint256): The application ID to expire.

#### **expireFundingRequest**

* **Purpose:** Anyone can expire a Pending funding request after its deadline if endorsers did not reach quorum.
* **Inputs:**
  * id (uint256): The funding request ID to expire.

#### **finalizeFundingRequest**

* **Purpose:** Anyone can finalize an Active funding request after its voting period if it failed (for ≤ against). Enables reward claims.
* **Inputs:**
  * id (uint256): The funding request ID to finalize.

#### **unlockYourTokens**

* **Purpose:** Clears your expired voting locks and adjusts the global locked total, restoring full transferability after `tokenUnlockTimeForCeoVote` and `tokenUnlockTimeForFundingVote` have both passed.
* **Inputs:** None.

### **B. Inherited Standard Functions**

These are standard functions from the OpenZeppelin contracts that INVTRON\_DAO inherits.

#### **transfer**

* **Purpose:** Standard ERC20 function to send INV tokens from your wallet to another address.  
* **Inputs:**  
  * to (address): The recipient's address.  
  * amount (uint256): The amount of INV tokens to send.

#### **approve**

* **Purpose:** Standard ERC20 function to grant another address permission to spend your INV tokens. **Crucial for paying application fees.**  
* **Inputs:**  
  * spender (address): The address you are giving permission to (the DAO contract address).  
  * amount (uint256): The maximum amount of INV tokens the spender is allowed to take.

#### **transferFrom**

* **Purpose:** Standard ERC20 function used by a spender (who has been approved) to transfer INV tokens from an owner's wallet to a third party.  
* **Inputs:**  
  * from (address): The address of the token owner.  
  * to (address): The address of the recipient.  
  * amount (uint256): The amount of INV tokens to transfer.

#### **delegate**

* **Purpose:** Delegate your INV voting power to another address or to yourself.
* **Important:** There is no default self-delegation. Holders must call `delegate(<address>)` (use your own address to self-delegate) to gain voting power.
* **Notes:** Reverts with `Errors.TokensLocked()` if called before either token unlock time.
* **Inputs:**
  * delegatee (address): The address to delegate voting power to (use `address(0)` to clear delegation).

#### **delegateBySig**

* **Purpose:** Allows a third party to submit a delegation transaction on a user's behalf using a signed message. Requires a dApp front-end.
* **Notes:** Reverts with `Errors.TokensLocked()` if the signer is still locked.
* **Inputs:**
  * delegatee (address): The address to delegate to.
  * nonce (uint256): The owner's current nonce.
  * expiry (uint256): The signature's expiration timestamp.  
  * v, r, s (uint8, bytes32, bytes32): The signature components.

#### **delegateVPbySig**

* **Purpose:** Delegates your full voting power for CEO and funding proposals using an EIP-712 signature. When the delegate votes, 90% of the reward from your delegated voting power goes to you and 10% to the delegatee, while the delegatee keeps the full reward from their own voting power. The 73-hour token lock applies to your address when the delegate votes. No default self-delegation—use this or `delegate()` to set one.
* **Notes:** Cannot be used while the signer is locked.
* **Inputs:**
  * delegatee (address): The address that may vote on your behalf.
  * nonce (uint256): Your current nonce (from `nonces`).
  * deadline (uint256): Expiration timestamp for the signature.
  * v, r, s (uint8, bytes32, bytes32): Signature components.

#### Signature Field Reference

The `delegateBySig` and `delegateVPbySig` functions use ECDSA signatures. The parameters below describe the pieces of those signatures and the delegation target.

| Field | Purpose |
|-------|---------|
| **Delegatee Address** | The address receiving delegated voting power (leave blank or use your own address to self-delegate). |
| **nonce** | A per-signer counter that prevents replay attacks by ensuring each signature is used only once. |
| **expiry / deadline** | Unix timestamp after which the signature becomes invalid. |
| **v** | Recovery ID that specifies which of the two possible public keys created the signature (usually 27 or 28). |
| **r** | First 32 bytes of the ECDSA signature; represents an x-coordinate on the secp256k1 curve. |
| **s** | Second 32 bytes of the ECDSA signature; a scalar proving knowledge of the private key. |

Example inputs:

```text
Delegatee Address : 0x1234567890abcdef1234567890abcdef12345678
nonce             : 0
expiry            : 1700000000          (≈ Nov-14-2023, 22:13:20 UTC)
v                 : 28
r                 : 0x34d1c52f05e790c964d23faee4039bb39b43d441bf0b90c1f9e2e0aef583d9a3
s                 : 0x4f44db03feb49f998d5681d7d6a20b5409e1c3d8f97d2a0d1f64dbf1c5073b6b
```


## **II. Read Functions (View-Only)**

These functions retrieve data from the contract and do not cost any gas.

### **A. DAO-Specific Data**

* **ceoApplications**: Mapping of all CEO applications. Query with an ID to get the full details.
* **fundingRequests**: Takes a request id and returns the details of a specific funding request.  
* **ceoEndorsersVoted**: Takes a CEO application id and an endorser address; returns true if they have voted.  
* **ceoUsersVoted**: Takes a CEO application id and a user address; returns true if they have voted.  
* **fundingEndorsersVoted**: Takes a funding request id and an endorser address; returns true if they have voted.
* **fundingUsersVoted**: Takes a funding request id and a user address; returns true if they have voted.
* **fundingUserVoteChoice**: Takes a funding request id and a user address; returns whether the user voted in favor.
* **votingPowerAtVote**: Returns the USD(6) vote amount recorded for a voter on a funding request.
* **delegateePowerAtVote**: Returns the portion of the delegatee’s own USD(6) vote recorded at vote time.
* **delegateAtVote**: Returns the delegate address recorded at the time of voting for a funding request.
* **rewardClaimed**: Takes a funding request id and a user address; returns true if the user already claimed their reward.
* **getRaisedAmount**: Takes a funding request id and returns in-favor minus against votes clamped to the request's hard cap.
* **getVotingReward**: Takes a funding request id and a voter address; returns the reward amount if the vote matched the final outcome.
* **getTotalTokensLocked**: Returns the aggregate amount of tokens temporarily locked for voting (O(1) running counter).
* **getCirculatingSupply**: Returns the current supply minus locked tokens (uses the running locked counter).
* **getExchangeState**: Takes a funding request id and returns the daily exchange cap, amount exchanged today, last exchange day and remaining INV-USD available for that request.
* **activeEndorserList()**: Returns the array of currently active endorsers (function).
* **isCEO(address)**: Returns true if the address is the current CEO.
* **isEndorserActive(address)**: Returns true if the address is an active endorser.

### **B. Public State Variables (Auto-Generated Getters)**

* **invUsdToken**: Returns the address of the internal InvUsdToken contract.
* **whitelistManager**: Address of the WhitelistManager contract.
* **nextCeoApplicationId**: Counter for generating the next unique CEO application ID.
* **activeCeoApplication**: Maps a user to their currently open CEO application ID.
  This ensures each address has at most one pending application at a time.
* **nextFundingRequestId**: Returns the ID that will be assigned to the next funding request.
* **recentVoteTimestamps**: Takes a voter address and returns the timestamp of their last vote.
* **tokenUnlockTimeForCeoVote / tokenUnlockTimeForFundingVote**: Each takes a voter address and returns the unlock timestamp for CEO and funding votes respectively.
* **lockedBalanceForCeoVote / lockedBalanceForFundingVote**: Return the minimum balance a voter must maintain during the lock period for CEO and funding votes.
* **lowestActiveEndorser**: Returns the active endorser with the fewest votes.
* **currentCeo**: The address of the presently active CEO.
* **electedCeo**: The address elected by the DAO waiting for activation.
* **electedCeoTimestamp**: Timestamp when the elected CEO was chosen.
* **treasuryOwner**: Address that receives fees paid during applications.
* **totalLockedTokens**: Running total of tokens locked by voting snapshots (O(1) getter). If a user’s lock expires without activity, the counter is corrected on subsequent interactions.
* **lastPrice**: Last accepted INV/USD oracle price (18 decimals).
* **votingDelegate**: Returns the address currently authorized to vote on behalf of a user (via signature delegation).
* **ceoStatus**: Takes an address and returns its CEO status (None, Nominated, Elected, Active).
* **CEO\_ROLE / ENDORSER\_ROLE**: Returns the bytes32 identifier for each role.
* **CEO\_APPLICATION\_FEE / ENDORSER\_APPLICATION\_FEE / FUNDING\_REQUEST\_FEE**: Returns the fee amount (in USD value with 18 decimals) for each application type.
* **CEO\_REQUIRED\_BALANCE\_USD / ENDORSER\_REQUIRED\_BALANCE\_USD**: Returns the minimum balance required (in USD value with 18 decimals) for applications.  
* **ENDORSER\_VOTES\_FOR\_CEO\_PASS / ENDORSER\_VOTES\_FOR\_FUNDING\_PASS**: Returns the number of endorser votes required to pass the first stage.  
* **MAX\_ACTIVE\_ENDORSERS / VOTING\_PERIOD / TOKEN\_LOCK\_DURATION / ELECTED\_CEO\_ACTIVATION\_DELAY / MAX\_PRICE\_DEVIATION\_BPS**: Public constants for limits and timings.
* **VOTING\_PERIOD / TOKEN\_LOCK\_DURATION**: Returns the duration (in seconds) for these periods.

### **C. Inherited Standard Functions**

* **name**: Returns the name of the token ("INVTRON").  
* **symbol**: Returns the symbol of the token ("INV").  
* **decimals**: Returns the number of decimals for the token (18).  
* **totalSupply**: Returns the total supply of INV tokens in existence.  
* **balanceOf**: Takes a user address and returns their INV token balance.  
* **allowance**: Takes an owner and a spender address and returns the remaining approved amount.  
* **getVotes**: Takes a user address and returns their current INV voting power.  
* **getPastVotes**: Returns historical voting power for an account at a given block.
* **getPastTotalSupply**: Returns the token supply at a given block.
* **delegates**: Takes a user address and returns the address they have delegated their votes to.  
* **nonces**: Takes a user address and returns their current nonce for delegateBySig.
* **hasRole**: Compatibility shim that checks if an account holds a role.

### **D. WhitelistManager Reads**

* **isWhitelisted(address)**: Returns true if the user is on the whitelist.
* **getWhitelistingReqStatus(address)**: Returns the status of the caller's most recent whitelist request.
* **getWwhitelistReqList()**: Returns all pending whitelist requests.
* **getWhitelistInfo(address)**: Returns the stored personal info for a whitelisted user.
* **whitelistRequests(uint256)** / **lastWhitelistRequest(address)** / **nextWhitelistRequestId()**: Administrative state for pending/processed requests.
