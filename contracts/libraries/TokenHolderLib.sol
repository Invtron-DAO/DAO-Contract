//libraries/TokenHolderLib.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TokenHolderLib
/// @notice Utility library to manage tracking of token holders.
library TokenHolderLib {
    struct State {
        mapping(address => bool) isTokenHolder;
    }

    /// @notice Add an address to the tracked list if not already present.
    /// @param state Storage pointer to library state
    /// @param account Address to add
    function addTokenHolder(State storage state, address account) internal {
        if (!state.isTokenHolder[account]) {
            state.isTokenHolder[account] = true;
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
}
