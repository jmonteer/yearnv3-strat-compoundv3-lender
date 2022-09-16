// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;

interface IVault {
    function asset() external view returns (address _asset);

    function decimals() external view returns (uint256);
}
