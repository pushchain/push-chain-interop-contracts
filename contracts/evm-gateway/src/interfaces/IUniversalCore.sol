// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalCore {
    function getOutboundTxGasAndFees(address _prc20, uint256 gasLimit)
        external
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace,
            uint256 gasLimitUsed
        );

    function swapAndBurnGas(address gasToken, uint24 fee, uint256 gasFee, uint256 deadline, address caller)
        external
        payable
        returns (uint256 gasTokenOut, uint256 refund);

    function getRescueFundsGasLimit(address _prc20)
        external
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 rescueGasLimit,
            uint256 gasPrice,
            string memory chainNamespace
        );

    function getPC20ExportGasAndFees(string memory destChainNamespace, uint256 gasLimit, address pc20Token)
        external
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace,
            uint256 gasLimitUsed,
            bool isFirstExport
        );

    function pc20Deployed(address sourceAsset, string memory destChain) external view returns (bool);

    function getPC20Wrapper(
        address sourceAsset,
        string memory destChain
    ) external view returns (bytes32 wrapper, bool deployed);

    function getPC20Source(
        bytes32 wrapper,
        string memory destChain
    ) external view returns (address sourceAsset, bool known);

    function pc20WrapperBySource(
        address sourceAsset,
        string memory destChain
    ) external view returns (bytes32 wrapper);

    function pc20SourceByWrapper(
        string memory destChain,
        bytes32 wrapper
    ) external view returns (address sourceAsset);

    function pc20FactoryByChain(
        string memory chainNamespace
    ) external view returns (bytes32 factory);
}
