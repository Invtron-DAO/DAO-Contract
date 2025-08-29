//CeoManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/Errors.sol";
import "./libraries/EventLib.sol";

abstract contract CeoManager {
    uint256 public constant ELECTED_CEO_ACTIVATION_DELAY = 360 hours;

    address public currentCeo;
    address public electedCeo;
    uint256 public electedCeoTimestamp;

    enum CeoStatus { None, Nominated, Elected, Active }
    mapping(address => CeoStatus) public ceoStatus;

    modifier onlyCEO() {
        if (msg.sender != currentCeo) revert Errors.OnlyCeo();
        _;
    }

    function _setCeo(address newCeo) internal {
        address previous = currentCeo;
        if (previous != address(0)) {
            ceoStatus[previous] = CeoStatus.None;
        }
        currentCeo = newCeo;
        if (newCeo != address(0)) {
            ceoStatus[newCeo] = CeoStatus.Active;
        }
        if (previous != newCeo) {
            emit EventLib.CeoChanged(previous, newCeo);
        }
    }
}
