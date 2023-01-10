// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.14;

import {DataTypes} from "../../libraries/aave/DataTypes.sol";

interface ILendingPool {
    /**
     * @dev Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state of the reserve
     **/
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
}
