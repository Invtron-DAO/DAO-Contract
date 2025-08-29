//libraries/PriceLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import "./Errors.sol";

library PriceLib {
    uint256 internal constant MAX_PRICE_AGE = 1 days;

    function getLatestPrice(
        AggregatorV3Interface feed
    ) internal view returns (int) {
        (
            ,
            int price,
            ,
            uint256 timeStamp,

        ) = feed.latestRoundData();
        if (timeStamp == 0 || block.timestamp - timeStamp > MAX_PRICE_AGE)
            revert Errors.OracleStale();
        if (price <= 0) revert Errors.OraclePriceInvalid();
        uint8 feedDecimals = feed.decimals();
        if (feedDecimals > 18) revert Errors.OracleDecimalsTooLarge();
        return price * int(10 ** (18 - feedDecimals));
    }

    function getInvValueInUsd(
        function(address) view returns (uint256) balanceOfFunc,
        AggregatorV3Interface feed,
        address user
    ) internal view returns (uint256) {
        int latestPrice = getLatestPrice(feed);
        return (balanceOfFunc(user) * uint256(latestPrice)) / 1e18;
    }
}

