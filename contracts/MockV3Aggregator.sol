// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockV3Aggregator {
    uint8 public decimals;
    int256 private _answer;

    constructor(uint8 _decimals, int256 answer_) {
        decimals = _decimals;
        _answer = answer_;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (0, _answer, 0, block.timestamp, 0);
    }
}
