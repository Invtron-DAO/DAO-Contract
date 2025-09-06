// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInvtronDao {
    // Role shims
    function CEO_ROLE() external pure returns (bytes32);
    function ENDORSER_ROLE() external pure returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);

    // External dependencies
    function whitelistManager() external view returns (address);

    // Manager hooks
    function prepareFundingVote(address caller, address tokenHolder) external returns (address voter);
    function lockTokensForFunding(address voter, uint256 amount) external;
    function getDelegate(address voter) external view returns (address);

    // Price feed helper
    function getLatestUsdPrice() external view returns (int);

    // Weighted-average balance age helper
    function balanceAge(address user) external view returns (uint256);

    // Minting hooks
    function mintGovByManager(address to, uint256 amount) external;
    function mintInvUsdByManager(address to, uint256 amount) external;

    // Exchange seeding
    function seedExchangeRemaining(uint256 id, uint256 amount) external;
    function freeHeadroomTokens(address user) external view returns (uint256);

    // Fee collection for funding requests
    function collectInvFee(address from, uint256 amount) external;
    // already public in DAO via public mappings; surface here for Funding manager
    function tokenUnlockTimeForFundingVote(address user) external view returns (uint256);

    // New helpers for amount-aware clamping by vote type
    function freeTokensForCeo(address user) external view returns (uint256);
    function freeTokensForFunding(address user) external view returns (uint256);
    // Optional: expose raw getPastVotes shim if needed elsewhere
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
 }