//WhitelistManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/WhitelistLib.sol";
import "./libraries/EventLib.sol";
import "./libraries/EndorserLib.sol";
import "./libraries/Errors.sol";
import "./INVTRON_DAO.sol";

contract WhitelistManager {
    address public dao;

    mapping(address => bool) private _whitelisted;
    uint256 public nextWhitelistRequestId;
    mapping(uint256 => WhitelistLib.Request) public whitelistRequests;
    mapping(address => uint256) public lastWhitelistRequest;
    uint256[] private _pendingWhitelistRequests;
    mapping(address => EndorserLib.PersonalInfo) public whitelistInfo;

    function setDao(address _dao) external {
        if (dao != address(0)) revert Errors.DaoAlreadySet();
        if (_dao == address(0)) revert Errors.DaoAddressZero();
        dao = _dao;
    }

    function _onlyCeo() internal view {
        if (!INVTRON_DAO(dao).hasRole(INVTRON_DAO(dao).CEO_ROLE(), msg.sender)) {
            revert Errors.OnlyCeo();
        }
    }

    function makeWhitelisted(address user, bool value) external {
        _onlyCeo();
        _whitelisted[user] = value;
        if (value) {
            emit EventLib.Whitelisted(user);
        } else {
            lastWhitelistRequest[user] = 0;
        }
    }

    function isWhitelisted(address user) external view returns (bool) {
        return _whitelisted[user];
    }

    function requestWhitelisting(EndorserLib.PersonalInfo calldata info) external {
        if (_whitelisted[msg.sender]) revert Errors.AlreadyWhitelisted();
        uint256 existingId = lastWhitelistRequest[msg.sender];
        if (existingId != 0) {
            WhitelistLib.Request storage existing = whitelistRequests[existingId];
            if (
                existing.status == WhitelistLib.RequestStatus.Pending ||
                existing.status == WhitelistLib.RequestStatus.Approved
            ) {
                revert Errors.WhitelistRequestExists();
            }
        }
        uint256 id = ++nextWhitelistRequestId;
        whitelistRequests[id] = WhitelistLib.Request({
            applicant: msg.sender,
            info: info,
            status: WhitelistLib.RequestStatus.Pending
        });
        whitelistInfo[msg.sender] = info;
        lastWhitelistRequest[msg.sender] = id;
        _pendingWhitelistRequests.push(id);
    }

    function getWhitelistingReqStatus(address user) external view returns (WhitelistLib.RequestStatus) {
        uint256 id = lastWhitelistRequest[user];
        if (id == 0) revert Errors.NoWhitelistRequest();
        return whitelistRequests[id].status;
    }

    function getWwhitelistReqList() external view returns (WhitelistLib.Request[] memory) {
        uint256 count = _pendingWhitelistRequests.length;
        WhitelistLib.Request[] memory list = new WhitelistLib.Request[](count);
        for (uint256 i = 0; i < count; i++) {
            list[i] = whitelistRequests[_pendingWhitelistRequests[i]];
        }
        return list;
    }

    function getWhitelistInfo(address user) external view returns (EndorserLib.PersonalInfo memory) {
        return whitelistInfo[user];
    }

    function ceoApproveWhitelisting(
        address[] calldata wallets,
        uint256[] calldata ids,
        bool approve
    ) external {
        _onlyCeo();
        if (wallets.length > 0) {
            for (uint256 i = 0; i < wallets.length; i++) {
                uint256 id = lastWhitelistRequest[wallets[i]];
                _processWhitelist(id, wallets[i], approve);
            }
        } else {
            for (uint256 i = 0; i < ids.length; i++) {
                WhitelistLib.Request storage req = whitelistRequests[ids[i]];
                _processWhitelist(ids[i], req.applicant, approve);
            }
        }
    }

    function _processWhitelist(uint256 id, address user, bool approve) internal {
        if (id == 0) revert Errors.NoWhitelistRequest();
        WhitelistLib.Request storage req = whitelistRequests[id];
        if (req.status != WhitelistLib.RequestStatus.Pending) revert Errors.WhitelistRequestNotPending();
        if (approve) {
            req.status = WhitelistLib.RequestStatus.Approved;
            _whitelisted[user] = true;
            emit EventLib.Whitelisted(user);
        } else {
            req.status = WhitelistLib.RequestStatus.Rejected;
        }
        WhitelistLib.removePending(_pendingWhitelistRequests, id);
    }
}

