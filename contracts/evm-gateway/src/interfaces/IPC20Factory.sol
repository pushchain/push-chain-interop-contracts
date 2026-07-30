// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPC20Factory {
    event PC20WrapperDeployed(
        address indexed sourceAsset, address indexed wrapper, string name, string symbol, uint8 decimals
    );

    event VaultUpdated(address indexed oldVault, address indexed newVault);

    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    function deployWrapper(address sourceAsset, string calldata name, string calldata symbol, uint8 decimals)
        external
        returns (address wrapper);

    function mintFor(address sourceAsset, address to, uint256 amount) external;

    function burnFrom(address sourceAsset, address from, uint256 amount) external;

    function revertMint(address wrapper, address to, uint256 amount) external;

    function getWrapper(address sourceAsset) external view returns (address wrapper);

    function isPC20Wrapper(address addr) external view returns (bool);

    function computeWrapperAddress(address sourceAsset) external view returns (address predicted);

    function updateVault(address newVault) external;

    function updateGateway(address newGateway) external;

    function pause() external;

    function unpause() external;
}
