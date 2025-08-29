//libraries/DelegateLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library DelegateLib {
    event VotingPowerDelegated(address indexed delegator, address indexed delegatee);

    function delegateBySig(
        mapping(address => address) storage delegateMap,
        bytes32 typehash,
        function(bytes32) internal view returns (bytes32) hashTypedDataV4Func,
        function(address) internal returns (uint256) useNonceFunc,
        address delegatee,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (block.timestamp > deadline) revert Errors.SignatureExpired();
        bytes32 structHash = keccak256(abi.encode(typehash, delegatee, nonce, deadline));
        address signer = ECDSA.recover(hashTypedDataV4Func(structHash), v, r, s);
        if (nonce != useNonceFunc(signer)) revert Errors.InvalidNonce();
        delegateMap[signer] = delegatee;
        emit VotingPowerDelegated(signer, delegatee);
    }
}

