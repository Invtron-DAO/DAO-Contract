//libraries/TokenHolderLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TokenHolderLib
/// @notice Utility library to manage tracking of token holders.
library TokenHolderLib {
    struct State {
        address[] tokenHolders;
        mapping(address => bool) isTokenHolder;
    }

    /// @notice Add an address to the tracked list if not already present.
    /// @param state Storage pointer to library state
    /// @param account Address to add
    function addTokenHolder(State storage state, address account) internal {
        if (!state.isTokenHolder[account]) {
            state.isTokenHolder[account] = true;
            state.tokenHolders.push(account);
        }
    }

    /// @notice Mark an address as no longer holding tokens.
    /// @param state Storage pointer to library state
    /// @param account Address to remove
    function removeTokenHolder(State storage state, address account) internal {
        if (state.isTokenHolder[account]) {
            state.isTokenHolder[account] = false;
        }
    }

    /// @notice Retrieve the current list of token holders.
    /// @param state Storage pointer to library state
    /// @return holders Array of active token holder addresses
    function getTokenHolders(State storage state) internal view returns (address[] memory holders) {
        uint256 count;
        for (uint256 i = 0; i < state.tokenHolders.length; i++) {
            if (state.isTokenHolder[state.tokenHolders[i]]) count++;
        }
        holders = new address[](count);
        uint256 index;
        for (uint256 i = 0; i < state.tokenHolders.length; i++) {
            address addr = state.tokenHolders[i];
            if (state.isTokenHolder[addr]) {
                holders[index++] = addr;
            }
        }
    }
}

