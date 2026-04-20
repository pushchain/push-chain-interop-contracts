// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title  MockFeeOnTransferERC20
 * @notice Minimal ERC20 that charges a fixed-bps fee on every transfer/transferFrom.
 *         Used to verify that UniversalGateway rejects fee-on-transfer tokens.
 * @dev    feeBps is expressed in basis points: 100 = 1%, 10_000 = 100%.
 *         The fee is subtracted from the amount sent to the recipient; for simplicity it is burned
 *         rather than redirected to a fee wallet — the invariant "recipient receives less than
 *         amount" is the only property under test.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ > 0 && feeBps_ < 10_000, "feeBps out of range");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint/burn paths skip the fee so tests can seed balances cleanly.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        // Sender still pays `value`; recipient receives `value - fee`; the fee portion is burned.
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee);
    }
}
