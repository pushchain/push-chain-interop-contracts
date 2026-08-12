// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPC20Token is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A plain ERC-20 with no PC20-specific surface. Exportable like any other
///      ERC-20 — destination metadata is carried by the PC20 payload, not the token.
contract MockPlainERC20 is ERC20 {
    constructor() ERC20("PlainToken", "PLAIN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 that delivers fewer tokens than requested (fee-on-transfer).
contract MockFeeOnTransferPC20 is ERC20 {
    uint256 public fee;

    constructor(uint256 fee_) ERC20("FeeToken", "FEE") {
        fee = fee_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        uint256 actual = amount > fee ? amount - fee : 0;
        _burn(msg.sender, fee);
        return super.transfer(to, actual);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 actual = amount > fee ? amount - fee : 0;
        _burn(from, fee);
        _transfer(from, to, actual);
        return true;
    }
}
