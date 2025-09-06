// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFundingManager {
    function setDao(address _dao) external;

    function nextFundingRequestId() external view returns (uint256);

    function fundingStatus(uint256 id) external view returns (uint8);

    function fundingAmount(uint256 id) external view returns (uint256);

    function proposerOf(uint256 id) external view returns (address);
}

