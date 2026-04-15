// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalCore {
    /**
     * @notice Get base gas limit for a chain
     * @return baseGasLimit Base gas limit
     */
    function BASE_GAS_LIMIT() external view returns (uint256 baseGasLimit);

    /**
     * @notice Get per-chain base gas limit by chain namespace
     * @param chainNamespace Chain namespace string (e.g. "eip155:11155111")
     * @return baseGasLimit Per-chain base gas limit (0 if not set)
     */
    function baseGasLimitByChainNamespace(string calldata chainNamespace) external view returns (uint256 baseGasLimit);

    /**
     * @notice Get gas fee for a PRC20 token, split into gasFee and protocolFee.
     * @dev    When gasLimit is 0, falls back to BASE_GAS_LIMIT.
     * @param _prc20 PRC20 address
     * @param gasLimit Gas limit (0 = use BASE_GAS_LIMIT)
     * @return gasToken Gas token address
     * @return gasFee Gas fee (gasPrice * effective gas limit)
     * @return protocolFee Protocol fee in native PC (from protocolFeeByToken mapping)
     * @return gasPrice Gas price on the external chain
     * @return chainNamespace Source chain namespace
     */
    function getOutboundTxGasAndFees(address _prc20, uint256 gasLimit)
        external
        view
        returns (address gasToken, uint256 gasFee, uint256 protocolFee, uint256 gasPrice, string memory chainNamespace);

    function swapAndBurnGas(
        address gasToken,
        uint24 fee,
        uint256 gasFee,
        uint256 deadline,
        address caller
    ) external payable returns (uint256 gasTokenOut, uint256 refund);

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
}
