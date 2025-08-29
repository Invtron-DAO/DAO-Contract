//FundingManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/FundingLib.sol";

abstract contract FundingManager {
    using FundingLib for FundingLib.State;
    FundingLib.State internal _fundingState;

    function nextFundingRequestId() external view returns (uint256) {
        return _fundingState.nextFundingRequestId;
    }

    function fundingRequests(uint256 id)
        external
        view
        returns (FundingLib.FundingRequest memory)
    {
        return _fundingState.fundingRequests[id];
    }
}
