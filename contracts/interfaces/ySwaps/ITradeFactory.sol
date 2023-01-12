// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use
pragma solidity 0.8.14;

interface ITradeFactory {
    function enable(address, address) external;

    function disable(address, address) external;
}
