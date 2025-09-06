//InvUsdToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./libraries/Errors.sol";

/**
 * @title InvUsdToken
 * @dev ERC20 token for INV-USD, owned by the DAO and restricted to interactions with it.
 */
contract InvUsdToken is ERC20 {
    address public owner;

    constructor() ERC20("INVTRON USD", "INV-USD") {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.OnlyDao();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.NewOwnerZero();
        owner = newOwner;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /**
     * @dev Overrides the core _update function to enforce spending restrictions.
     * INV-USD can only be transferred back to the DAO contract that owns it.
     * This prevents user-to-user trading and keeps it as a utility voucher.
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0) && to != address(0)) {
            if (msg.sender != owner) {
                if (to != owner) revert Errors.InvalidExchangeRecipient();
            }
        }
        super._update(from, to, amount);
    }
}
