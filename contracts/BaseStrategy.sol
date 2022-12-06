// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IVault.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

abstract contract BaseStrategy {
    address public vault;
    address public immutable asset;
    string public name;

    constructor(address _vault, string memory _name) {
        vault = _vault;
        name = _name;
        asset = IVault(vault).asset();
    }

    function maxDeposit(
        address receiver
    ) public view virtual returns (uint256 maxAssets) {
        maxAssets = type(uint256).max;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        // 1:1
        return shares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        // 1:1
        return assets;
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets();
    }

    function balanceOf(address owner) public view returns (uint256) {
        if (owner == vault) {
            return _totalAssets();
        }
        return 0;
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public returns (uint256) {
        require(msg.sender == vault && msg.sender == receiver, "not owner");

        // transfer and invest
        IERC20(asset).transferFrom(vault, address(this), assets);
        _invest();
        return assets;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _maxWithdraw(owner);
    }

    function tend() external {
        require(msg.sender == vault, "not owner");
        return _tend();
    }

    function tendTrigger() external view returns (bool) {
        return _tendTrigger();
    }

    function withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) public returns (uint256) {
        require(msg.sender == vault && msg.sender == receiver, "not owner");
        require(amount <= maxWithdraw(vault), "withdraw more than max");

        uint256 amountWithdrawn = _withdraw(amount, receiver, owner);
        IERC20(asset).transfer(receiver, amountWithdrawn);
        return amountWithdrawn;
    }

    function _maxWithdraw(
        address owner
    ) internal view virtual returns (uint256 withdraw_amount);

    function _withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) internal virtual returns (uint256 withdrawAmount);

    function _invest() internal virtual;

    function _totalAssets() internal view virtual returns (uint256);

    function _tend() internal virtual {}

    function _tendTrigger() internal view virtual returns (bool) {}

    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }
}
