// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalCore {
    /**
     * @notice Get gas fee for a PRC20 token, split into gasFee and protocolFee.
     * @dev    When gasLimit is 0, falls back to per-chain baseGasLimitByChainNamespace.
     *         Reverts with GasLimitBelowBase when gasLimit is non-zero but below the
     *         chain's base gas limit.
     * @param _prc20 PRC20 address
     * @param gasLimit Gas limit (0 = use per-chain base gas limit)
     * @return gasToken Gas token address
     * @return gasFee Gas fee (gasPrice * effective gas limit)
     * @return protocolFee Protocol fee in native PC (from protocolFeeByToken mapping)
     * @return gasPrice Gas price on the external chain
     * @return chainNamespace Source chain namespace
     * @return gasLimitUsed Effective gas limit used to compute gasFee
     */
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
