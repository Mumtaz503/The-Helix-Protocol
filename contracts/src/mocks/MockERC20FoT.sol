// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Fee-on-transfer token for deposit FoT tests. `feeBps` of each transfer is burned.
 */
contract MockERC20FoT is ERC20 {
    uint256 public feeBps; // out of 10_000

    constructor(uint256 feeBps_) ERC20("FeeToken", "FOT") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sendAmount = amount - fee;
        address owner = _msgSender();
        _spend(owner, to, sendAmount, fee);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sendAmount = amount - fee;
        _spend(from, to, sendAmount, fee);
        return true;
    }

    function _spend(address from, address to, uint256 sendAmount, uint256 fee) internal {
        if (fee != 0) {
            _burn(from, fee);
        }
        if (sendAmount != 0) {
            _transfer(from, to, sendAmount);
        } else if (fee == 0) {
            _transfer(from, to, 0);
        }
        // 100% fee: burn all, recipient gets 0 — transferFrom still returns true
    }
}
