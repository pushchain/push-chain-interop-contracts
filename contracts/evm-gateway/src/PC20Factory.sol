// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Errors} from "./libraries/Errors.sol";
import {IPC20Factory} from "./interfaces/IPC20Factory.sol";
import {PC20Wrapper} from "./PC20Wrapper.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

contract PC20Factory is
    PausableUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    IPC20Factory
{
    // ==============================
    //      ROLES
    // ==============================

    bytes32 public constant ROLE_MANAGER_ROLE = keccak256("ROLE_MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant GATEWAY_ROLE = keccak256("GATEWAY_ROLE");

    // ==============================
    //      CONSTANTS
    // ==============================

    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 32;

    // ==============================
    //      STATE (slot 100+)
    // ==============================

    mapping(address => address) public sourceToWrapper;
    mapping(address => address) public wrapperToSource;
    address public vault;
    address public gateway;

    // ==============================
    //      CUSTOM ERRORS
    // ==============================

    error WrapperAlreadyDeployed(address sourceAsset);
    error WrapperNotDeployed(address sourceAsset);
    error InvalidSourceAsset();
    error NameTooLong();
    error SymbolTooLong();
    error EmptyName();
    error EmptySymbol();

    // ==============================
    //      CONSTRUCTOR
    // ==============================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ==============================
    //      INITIALIZER
    // ==============================

    function initialize(
        address admin,
        address pauser,
        address vault_,
        address gateway_
    ) external initializer {
        if (
            admin == address(0) ||
            pauser == address(0) ||
            vault_ == address(0) ||
            gateway_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        __Pausable_init();
        __AccessControlDefaultAdminRules_init(1 days, admin);

        _setRoleAdmin(VAULT_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(GATEWAY_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ROLE_MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ROLE_MANAGER_ROLE);

        _grantRole(ROLE_MANAGER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(VAULT_ROLE, vault_);
        _grantRole(GATEWAY_ROLE, gateway_);

        vault = vault_;
        gateway = gateway_;
    }

    // ==============================
    //      WRAPPER LIFECYCLE
    // ==============================

    /// @inheritdoc IPC20Factory
    function deployWrapper(
        address sourceAsset,
        string calldata name,
        string calldata symbol,
        uint8 decimals
    ) external onlyRole(VAULT_ROLE) whenNotPaused returns (address wrapper) {
        if (sourceAsset == address(0)) revert InvalidSourceAsset();
        if (sourceToWrapper[sourceAsset] != address(0)) {
            revert WrapperAlreadyDeployed(sourceAsset);
        }
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(name).length > MAX_NAME_LENGTH) revert NameTooLong();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (bytes(symbol).length > MAX_SYMBOL_LENGTH) revert SymbolTooLong();

        bytes32 salt = keccak256(abi.encode(sourceAsset));
        wrapper = address(
            new PC20Wrapper{salt: salt}(
                name, symbol, decimals, sourceAsset, address(this)
            )
        );

        sourceToWrapper[sourceAsset] = wrapper;
        wrapperToSource[wrapper] = sourceAsset;

        emit PC20WrapperDeployed(
            sourceAsset, wrapper, name, symbol, decimals
        );
    }

    // ==============================
    //      MINT / BURN
    // ==============================

    /// @inheritdoc IPC20Factory
    function mintFor(
        address sourceAsset,
        address to,
        uint256 amount
    ) external onlyRole(VAULT_ROLE) whenNotPaused {
        address wrapper = sourceToWrapper[sourceAsset];
        if (wrapper == address(0)) revert WrapperNotDeployed(sourceAsset);
        PC20Wrapper(wrapper).mint(to, amount);
    }

    /// @inheritdoc IPC20Factory
    function burnFrom(
        address sourceAsset,
        address from,
        uint256 amount
    ) external onlyRole(GATEWAY_ROLE) whenNotPaused {
        address wrapper = sourceToWrapper[sourceAsset];
        if (wrapper == address(0)) revert WrapperNotDeployed(sourceAsset);
        PC20Wrapper(wrapper).burn(from, amount);
    }

    /// @inheritdoc IPC20Factory
    function revertMint(
        address sourceAsset,
        address to,
        uint256 amount
    ) external onlyRole(GATEWAY_ROLE) whenNotPaused {
        address wrapper = sourceToWrapper[sourceAsset];
        if (wrapper == address(0)) revert WrapperNotDeployed(sourceAsset);
        PC20Wrapper(wrapper).mint(to, amount);
    }

    // ==============================
    //      VIEW FUNCTIONS
    // ==============================

    /// @inheritdoc IPC20Factory
    function getWrapper(
        address sourceAsset
    ) external view returns (address) {
        return sourceToWrapper[sourceAsset];
    }

    /// @inheritdoc IPC20Factory
    function isPC20Wrapper(
        address addr
    ) external view returns (bool) {
        return wrapperToSource[addr] != address(0);
    }

    /// @inheritdoc IPC20Factory
    function computeWrapperAddress(
        address sourceAsset,
        string calldata name,
        string calldata symbol,
        uint8 decimals
    ) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encode(sourceAsset));
        bytes memory creationCode = abi.encodePacked(
            type(PC20Wrapper).creationCode,
            abi.encode(name, symbol, decimals, sourceAsset, address(this))
        );
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(creationCode)
                        )
                    )
                )
            )
        );
    }

    // ==============================
    //      ADMIN
    // ==============================

    /// @inheritdoc IPC20Factory
    function updateVault(
        address newVault
    ) external onlyRole(OPERATOR_ROLE) {
        if (newVault == address(0)) revert Errors.ZeroAddress();
        address oldVault = vault;
        _revokeRole(VAULT_ROLE, oldVault);
        _grantRole(VAULT_ROLE, newVault);
        vault = newVault;
        emit VaultUpdated(oldVault, newVault);
    }

    /// @inheritdoc IPC20Factory
    function updateGateway(
        address newGateway
    ) external onlyRole(OPERATOR_ROLE) {
        if (newGateway == address(0)) revert Errors.ZeroAddress();
        address oldGateway = gateway;
        _revokeRole(GATEWAY_ROLE, oldGateway);
        _grantRole(GATEWAY_ROLE, newGateway);
        gateway = newGateway;
        emit GatewayUpdated(oldGateway, newGateway);
    }

    /// @inheritdoc IPC20Factory
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IPC20Factory
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }
}
