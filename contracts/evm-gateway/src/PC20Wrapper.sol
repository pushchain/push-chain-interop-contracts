// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PC20Wrapper is ERC20 {
    address public immutable SOURCE_ASSET;
    uint8 private immutable _decimals;

    address public factory;
    address public pendingFactory;

    error OnlyFactory();
    error OnlyPendingFactory();
    error ZeroAddress();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address sourceAsset_,
        address factory_
    ) ERC20(name_, symbol_) {
        if (sourceAsset_ == address(0)) revert ZeroAddress();
        if (factory_ == address(0)) revert ZeroAddress();
        SOURCE_ASSET = sourceAsset_;
        factory = factory_;
        _decimals = decimals_;
    }

    function decimals()
        public
        view
        override
        returns (uint8)
    {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyFactory {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external onlyFactory {
        _burn(from, amount);
    }

    function transferFactory(
        address newFactory
    ) external onlyFactory {
        pendingFactory = newFactory;
    }

    function acceptFactory() external {
        if (msg.sender != pendingFactory)
            revert OnlyPendingFactory();
        factory = pendingFactory;
        pendingFactory = address(0);
    }
}
