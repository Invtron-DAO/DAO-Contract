// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./Errors.sol";

library PriceLib {
    function getLatestPrice(
        AggregatorV3Interface feed,
        uint8 feedDecimals
    ) internal view returns (int) {
        (
            ,
            int price,
            ,
            uint256 timeStamp,
            
        ) = feed.latestRoundData();
        if (timeStamp == 0) revert Errors.OracleStale();
        if (price <= 0) revert Errors.OraclePriceInvalid();
        if (feedDecimals > 18) revert Errors.OracleDecimalsTooLarge();
        return price * int(10 ** (18 - feedDecimals));
    }

    function getInvValueInUsd(
        function(address) view returns (uint256) balanceOfFunc,
        AggregatorV3Interface feed,
        uint8 feedDecimals,
        address user
    ) internal view returns (uint256) {
        int latestPrice = getLatestPrice(feed, feedDecimals);
        return (balanceOfFunc(user) * uint256(latestPrice)) / 1e18;
    }
}

