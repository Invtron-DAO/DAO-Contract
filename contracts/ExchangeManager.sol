//ExchangeManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "./InvUsdToken.sol";
import "./CeoManager.sol";
import "./interfaces/IFundingManager.sol";
import "./libraries/Errors.sol";
import "./libraries/PriceLib.sol";
import "./libraries/EventLib.sol";
import "./libraries/FundingLib.sol";
import "./libraries/ProposalLib.sol";

/// @title ExchangeManager
/// @notice Handles INV-USD exchange limits and conversion logic.
abstract contract ExchangeManager is CeoManager, ReentrancyGuard {
    InvUsdToken public invUsdToken;
    AggregatorV3Interface internal priceFeed;
    IFundingManager public fundingManager;

    // --- Price Guard ---
    int public lastPrice;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 1000; // 10%

    // --- State Variables for Exchange Limits ---
    mapping(uint256 => uint256) internal dailyExchangeLimit;
    mapping(uint256 => uint256) internal dailyExchangedAmount;
    mapping(uint256 => uint256) internal lastExchangeDay;
    mapping(uint256 => uint256) internal remainingToExchange;

    /// @notice Fetch exchange parameters for a funding request in a single call.
    /// @param requestId Identifier of the funding request.
    /// @return limit Daily exchange cap for the request.
    /// @return exchanged Amount of INV-USD exchanged today.
    /// @return lastDay Last day when an exchange occurred.
    /// @return remaining INV-USD still available for exchange.
    function getExchangeState(uint256 requestId)
        external
        view
        returns (
            uint256 limit,
            uint256 exchanged,
            uint256 lastDay,
            uint256 remaining
        )
    {
        limit = dailyExchangeLimit[requestId];
        exchanged = dailyExchangedAmount[requestId];
        lastDay = lastExchangeDay[requestId];
        remaining = remainingToExchange[requestId];
    }

    /// @dev Hooks that allow the composing contract to expose core DAO state (vesting removed)
    function _totalSupply() internal view virtual returns (uint256);
    function _getTotalTokensLocked() internal view virtual returns (uint256);

    /// @dev Required mint hook implemented by the composing contract
    function _daoMint(address to, uint256 amount) internal virtual;

    /// @notice Update the Chainlink price feed used for INV/USD conversions.
    /// @param newFeed Address of the new price feed contract.
    function setPriceFeed(address newFeed) external onlyCEO {
        if (newFeed == address(0)) revert Errors.InvalidFeedAddress();
        priceFeed = AggregatorV3Interface(newFeed);
        lastPrice = PriceLib.getLatestPrice(priceFeed);
        emit EventLib.PriceFeedUpdated(newFeed, lastPrice);
    }

    // Note: legacy unswapped-accounting functions removed.

    /// @notice Limit how much INV-USD can be converted back to INV each day for a request.
    /// @param requestId The funding request to configure.
    /// @param limitPercent Percentage of the total amount that may be exchanged per day.
    function setDailyExchangeLimit(uint256 requestId, uint256 limitPercent)
        external
        onlyCEO
    {
        if (limitPercent == 0 || limitPercent > 100) revert Errors.InvalidLimitPercent();
        if (fundingManager.fundingStatus(requestId) != uint8(ProposalLib.ProposalStatus.Executed)) {
            revert Errors.FundingRequestNotExecuted();
        }
        uint256 total = fundingManager.fundingAmount(requestId) * 1e12;
        uint256 limit = (total * limitPercent) / 100;
        dailyExchangeLimit[requestId] = limit;
        emit EventLib.DailyLimitSet(requestId, limit);
    }

    /// @notice Exchange previously minted INV-USD back into INV governance tokens.
    /// @param requestId The funding request being converted.
    /// @param invUsdAmount Amount of INV-USD to exchange.
    function exchangeInvUsdForInv(uint256 requestId, uint256 invUsdAmount) external nonReentrant {
        if (fundingManager.fundingStatus(requestId) != uint8(ProposalLib.ProposalStatus.Executed)) {
            revert Errors.FundingRequestNotExecuted();
        }
        if (msg.sender != fundingManager.proposerOf(requestId)) revert Errors.OnlyProposer();
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

        int currentPrice = PriceLib.getLatestPrice(priceFeed);
        if (lastPrice != 0) {
            uint256 diff = currentPrice > lastPrice
                ? uint256(currentPrice - lastPrice)
                : uint256(lastPrice - currentPrice);
            if (diff * 10000 > uint256(lastPrice) * MAX_PRICE_DEVIATION_BPS) {
                revert Errors.PriceOutOfBounds();
            }
        }
        invUsdToken.burnFrom(msg.sender, invUsdAmount);
        uint256 invAmount = (invUsdAmount * 1e18) / uint256(currentPrice);
        _daoMint(msg.sender, invAmount);
        dailyExchangedAmount[requestId] += invUsdAmount;
        remainingToExchange[requestId] -= invUsdAmount;
        lastPrice = currentPrice;
        emit EventLib.Exchanged(msg.sender, invUsdAmount, invAmount);
    }
}
