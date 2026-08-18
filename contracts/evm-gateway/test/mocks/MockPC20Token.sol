// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

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

/// @dev Minimal token exposing only the mandatory EIP-20 surface — no decimals()/name()/symbol().
///      EIP-20 marks metadata OPTIONAL, so such tokens must remain exportable.
contract MockNoMetadataERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A real ERC-721. Must never be exportable via the PC20 path.
///      Note balanceOf(address) and approve(address,uint256) share selectors with ERC-20,
///      so only allowance()/ERC-165 can tell this apart from a fungible token.
contract MockERC721 is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev An ERC-721 that also exposes an allowance() stub, defeating the primary probe.
///      Caught only by the ERC-165 supportsInterface(0x80ac58cd) check.
contract MockERC721WithAllowance is ERC721 {
    constructor() ERC721("SneakyNFT", "SNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
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
