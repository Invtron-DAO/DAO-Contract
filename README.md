# **INVTRON DAO: Comprehensive Smart Contract Guide**

This document provides a complete and detailed guide to interacting with the INVTRON\_DAO smart contract. It covers all functions a user or developer can call, including both the custom logic for the DAO and the standard functions inherited from its OpenZeppelin parent contracts.
Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.js --network sepolia
```

Before deploying you will need two environment files:

- `.env` containing `INFURA_PROJECT_ID`, `INFURA_PROJECT_SECRET`, `PRIVATE_KEY` and `ETHERSCAN_API_KEY`.
- `constructor.env` containing `_priceFeedAddress`, `_initialCeo`, `_initialEndorsers` and `_treasuryOwner`.

These variables are loaded by the scripts in `scripts/` when deploying.

INV tokens are only minted in three places: the constructor for the initial one
billion supply, the `exchangeInvUsdForInv` function when proposers convert
approved INV-USD, and `claimReward` for voter incentives. All other minting is
disabled to keep the supply in line with governance decisions. INV-USD minting
requires both a successful vote and explicit CEO approval.

## Web UI

A generic front-end is available in the `ui/` folder. Serve the contents of this directory with any static server. After running `scripts/deploy-and-verify.js` the deployed contract address is written to `ui/deployInfo.json` and `ui/app.js` reads the address from this file automatically. The interface loads the contract ABI from `ui/INVTRON_DAO.json` and automatically generates a form for every read and write function.

The dashboard now also lists the active endorsers and displays their vote totals by calling `activeEndorserList` and `getVotes`.

Additional spacing between the logo and navigation menu has been added for Arabic and Urdu translations to improve readability.

### Updated Interface

The web interface organises contract functions into three tabs labelled **User**, **Endorser** and **CEO**. Selecting a tab now initiates the wallet connection and checks your current role. Roles fall into four categories: **New User**, **Whitelisted User**, **Active Endorser** and **Active CEO**. If the selected tab does not match your role, the interface suggests the correct one. Connection details and your detected role appear at the top of the page.
If the wallet connection fails, the status area displays an error such as `Wallet connection failed: <reason>`.

Boolean parameters now use simple up/down arrow buttons so you can quickly choose **Yes** or **No** without typing.

Function listings now rely on an explicit role map so each tab shows every available action for that role.

### Development Notes

* Inline comments in `contracts/INVTRON_DAO.sol` were expanded for clarity around
  voting, funding and exchange logic.
* Introduced `VotingLib` library to house internal voting helpers. This keeps the
  main DAO contract smaller and easier to maintain.
* Added `prepareDelegatedVote` helper to further offload voting logic to the
  library and reduce contract complexity.
* Added `PriceLib` library for oracle price and balance calculations, further
  shrinking the main contract.
* Replaced revert strings with custom errors and enabled `viaIR` compilation to reduce bytecode size below the deployment limit.




The functions are separated into two main categories:

1. **Write Functions:** These modify the contract's state and require a transaction fee (gas).  
2. **Read Functions:** These retrieve data from the blockchain and are free to call.

## **I. Write Functions (State-Changing)**

These functions require a transaction to be submitted to the blockchain. They are grouped by purpose.

### **A. DAO-Specific Actions**

These functions are unique to the INVTRON DAO's logic.

#### **makeWhitelisted**

* **Purpose:** Called by a CEO to add or remove a user from the whitelist.
* **Inputs:**
  * user (address): The wallet address of the user.
  * value (bool): true to whitelist, false to remove.

#### **setDailyExchangeLimit**

* **Purpose:** Called by a CEO to set the daily INV-USD to INV exchange limit for a specific funding request.
* **Inputs:**
  * fundingRequestId (uint256): The ID of the funding request.
  * limitPercent (uint256): Percentage of the request's total amount that can be exchanged each day.

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
* **Inputs:**
  * info (tuple): Personal details containing:
    * firstName (string)
    * lastName (string)
    * mobile (string)
    * zipCode (string)
    * city (string)
    * state (string)
    * country (string)
    * bio (string)


### **B. Endorser Leaderboard**

These functions implement the permanent leaderboard system for Endorsers.

#### **registerEndorserCandidate**

* **Purpose:** One-time registration for users wishing to appear on the leaderboard. Requires the standard endorser fee.
* **Prerequisite:** The user must be whitelisted and call approve() for the fee.
* **Inputs:**
  * info (tuple): Personal details containing the same fields as `applyForCeo`.

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
    * softCapAmount (uint256)
    * hardCapAmount (uint256)
    * valuation (uint256)
    * country (string)
    * websiteUrl (string)
    * ceoLinkedInUrl (string)
    * shortDescription (string)
    * companyRegistrationUrl (string)

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

* **Purpose:** Called by any INV token holder to vote on an Active funding request.
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

#### **approveFundingRequest**

* **Purpose:** Called by the CEO after voting ends on a funding request. If the proposal passed, this marks it as CEO approved.
* **Inputs:**
  * id (uint256): The ID of the funding request to approve.

#### **executeFundingRequest**

* **Purpose:** After a funding vote ends and the CEO has approved the request, this function mints and sends INV-USD to the proposer.
* **Inputs:**
  * id (uint256): The ID of the funding request to execute.

#### **claimReward**

* **Purpose:** Allows a voter to claim PoDD rewards after a funding request is finalized.
* **Reward Formula:** The user receives 1% of their voting value. The voting value is 0.5% of the USD value of their INV balance:

  `UserVotingValue = (balanceOf(user) * tokenPrice) * 0.005`

  `Reward = UserVotingValue * 0.01`

  This equates to minting `balanceOf(user) / 20,000` INV tokens.
* **Inputs:**
  * fundingRequestId (uint256): The ID of the funding request the user voted on.

#### **exchangeInvUsdForInv**

* **Purpose:** Allows a proposer to exchange INV-USD for INV tokens, subject to the daily limit of a specific funding request.
* **Prerequisite:** The user must first call approve() on the invUsdToken contract, giving this DAO permission to spend their INV-USD.
* **Inputs:**
  * fundingRequestId (uint256): The funding request the tokens were minted for.
  * invUsdAmount (uint256): The amount of INV-USD to exchange.

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

* **Purpose:** Allows a user to delegate their INV voting power to another address or to themselves. **You must delegate to yourself to vote directly.**  
* **Inputs:**  
  * delegatee (address): The address to delegate voting power to.

#### **delegateBySig**

* **Purpose:** Allows a third party to submit a delegation transaction on a user's behalf using a signed message. Requires a dApp front-end.  
* **Inputs:**  
  * delegatee (address): The address to delegate to.  
  * nonce (uint256): The owner's current nonce.  
  * expiry (uint256): The signature's expiration timestamp.  
  * v, r, s (uint8, bytes32, bytes32): The signature components.

#### **delegateVPbySig**

* **Purpose:** Delegates your full voting power for CEO and funding proposals using an EIP-712 signature. Rewards from successful proposals are split 70% to you and 30% to the delegatee. The 73-hour token lock applies to your address when the delegate votes.
* **Inputs:**
  * delegatee (address): The address that may vote on your behalf.
  * nonce (uint256): Your current nonce (from `nonces`).
  * deadline (uint256): Expiration timestamp for the signature.
  * v, r, s (uint8, bytes32, bytes32): Signature components.

#### **permit**

* **Purpose:** Allows a third party to submit an approve transaction on a user's behalf using a signed message. Requires a dApp front-end.  
* **Inputs:**  
  * owner (address): The token owner's address.  
  * spender (address): The address being granted the allowance.  
  * value (uint256): The amount of the allowance.  
  * deadline (uint256): The signature's expiration timestamp.  
  * v, r, s (uint8, bytes32, bytes32): The signature components.

#### **grantRole**

* **Purpose:** Grants a specified role to an account. Restricted to the role's admin.  
* **Inputs:**  
  * role (bytes32): The role to grant (e.g., CEO\_ROLE).  
  * account (address): The address to grant the role to.

#### **revokeRole**

* **Purpose:** Revokes a specified role from an account. Restricted to the role's admin.  
* **Inputs:**  
  * role (bytes32): The role to revoke.  
  * account (address): The address to revoke the role from.

#### **renounceRole**

* **Purpose:** Allows a user to renounce a role they hold, abandoning its privileges.  
* **Inputs:**  
  * role (bytes32): The role to renounce.  
  * account (address): The address renouncing the role (must be msg.sender).

## **II. Read Functions (View-Only)**

These functions retrieve data from the contract and do not cost any gas.

### **A. DAO-Specific Data**

* **getLatestPrice**: Returns the current price of the INV token in USD (scaled to 18 decimals).  
* **getInvValueInUsd**: Takes a user address and returns the total USD value of their INV token holdings.  
* **ceoApplications**: Mapping of all CEO applications. Query with an ID to get the full details.
* **fundingRequests**: Takes a request id and returns the details of a specific funding request.  
* **ceoEndorsersVoted**: Takes a CEO application id and an endorser address; returns true if they have voted.  
* **ceoUsersVoted**: Takes a CEO application id and a user address; returns true if they have voted.  
* **fundingEndorsersVoted**: Takes a funding request id and an endorser address; returns true if they have voted.  
* **fundingUsersVoted**: Takes a funding request id and a user address; returns true if they have voted.

### **B. Public State Variables (Auto-Generated Getters)**

* **invUsdToken**: Returns the address of the internal InvUsdToken contract.
* **dailyExchangeLimit**: Takes a funding request id and returns the daily INV-USD exchange cap.
* **dailyExchangedAmount**: Takes a funding request id and returns how much INV-USD has been exchanged today for that request.
* **lastExchangeDay**: Takes a funding request id and returns the timestamp of its last exchange.
* **remainingToExchange**: Takes a funding request id and returns the remaining INV-USD available for exchange.
* **nextCeoApplicationId**: Counter for generating the next unique CEO application ID.
* **activeCeoApplication**: Maps a user to their currently open CEO application ID.
  This ensures each address has at most one pending application at a time.
* **nextFundingRequestId**: Returns the ID that will be assigned to the next funding request.
* **recentVoteTimestamps**: Takes a voter address and returns the timestamp of their last vote.
* **tokenUnlockTime**: Takes a voter address and returns the timestamp when their tokens will be unlocked.
* **activeEndorserList**: Returns the array of currently active endorsers. This
  function has no parameters and returns up to 50 addresses.
* **lowestActiveEndorser**: Returns the active endorser with the fewest votes.
* **currentCeo**: The address of the presently active CEO.
* **electedCeo**: The address elected by the DAO waiting for activation.
* **electedCeoTimestamp**: Timestamp when the elected CEO was chosen.
* **treasuryOwner**: Address that receives fees paid during applications.
* **CEO\_ROLE / ENDORSER\_ROLE**: Returns the bytes32 identifier for each role.
* **isWhitelisted**: Takes a user address and returns true if they are whitelisted.
* **CEO\_APPLICATION\_FEE / ENDORSER\_APPLICATION\_FEE / FUNDING\_REQUEST\_FEE**: Returns the fee amount (in USD value with 18 decimals) for each application type.  
* **CEO\_REQUIRED\_BALANCE\_USD / ENDORSER\_REQUIRED\_BALANCE\_USD**: Returns the minimum balance required (in USD value with 18 decimals) for applications.  
* **ENDORSER\_VOTES\_FOR\_CEO\_PASS / ENDORSER\_VOTES\_FOR\_FUNDING\_PASS**: Returns the number of endorser votes required to pass the first stage.  
* **VOTING\_PERIOD / TOKEN\_LOCK\_DURATION**: Returns the duration (in seconds) for these periods.

### **C. Inherited Standard Functions**

* **name**: Returns the name of the token ("INVTRON").  
* **symbol**: Returns the symbol of the token ("INV").  
* **decimals**: Returns the number of decimals for the token (18).  
* **totalSupply**: Returns the total supply of INV tokens in existence.  
* **balanceOf**: Takes a user address and returns their INV token balance.  
* **allowance**: Takes an owner and a spender address and returns the remaining approved amount.  
* **getVotes**: Takes a user address and returns their current INV voting power.  
* **getPastVotes**: Takes a user address and a blockNumber and returns their voting power at that past block.  
* **getPastTotalSupply**: Takes a blockNumber and returns the total INV supply at that past block.  
* **delegates**: Takes a user address and returns the address they have delegated their votes to.  
* **nonces**: Takes a user address and returns their current nonce for permit and delegateBySig.  
* **hasRole**: Takes a role and an account address and returns true if the account has the role.  
* **getRoleAdmin**: Takes a role and returns the admin role for that role.  
* **getRoleMember**: Takes a role and an index and returns the address of the member at that index.  
* **getRoleMemberCount**: Takes a role and returns the total number of accounts with that role.  
* **DOMAIN\_SEPARATOR**: Returns the EIP-712 domain separator for this contract, used in signing messages.