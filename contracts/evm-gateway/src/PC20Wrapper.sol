// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PC20Wrapper is ERC20 {
    address public immutable SOURCE_ASSET;

    string private _wrappedName;
    string private _wrappedSymbol;
    uint8 private _wrappedDecimals;
    bool private _initialized;

    address public factory;
    address public pendingFactory;

    error OnlyFactory();
    error OnlyPendingFactory();
    error ZeroAddress();
    error AlreadyInitialized();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        address sourceAsset_,
        address factory_
    ) ERC20("", "") {
        if (sourceAsset_ == address(0)) revert ZeroAddress();
        if (factory_ == address(0)) revert ZeroAddress();
        SOURCE_ASSET = sourceAsset_;
        factory = factory_;
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_
    ) external onlyFactory {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _wrappedName = name_;
        _wrappedSymbol = symbol_;
        _wrappedDecimals = decimals_;
    }

    function name()
        public
        view
        override
        returns (string memory)
    {
        return _wrappedName;
    }

    function symbol()
        public
        view
        override
        returns (string memory)
    {
        return _wrappedSymbol;
    }

    function decimals()
        public
        view
        override
        returns (uint8)
    {
        return _wrappedDecimals;
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
