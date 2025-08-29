//libraries/WhitelistLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./EndorserLib.sol";

library WhitelistLib {
    enum RequestStatus { Pending, Approved, Rejected }

    struct Request {
        address applicant;
        EndorserLib.PersonalInfo info;
        RequestStatus status;
    }

    function removePending(uint256[] storage arr, uint256 id) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == id) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }
}
