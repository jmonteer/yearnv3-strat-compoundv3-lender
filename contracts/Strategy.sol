// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/IProtocolDataProvider.sol";
import "./interfaces/IVault.sol";

contract Strategy {
    using Math for uint256;

    IProtocolDataProvider public constant protocolDataProvider =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    string public name;
    address public immutable aToken;
    address public immutable asset;
    address public vault;

    constructor(address _vault, string memory _name) {
        vault = _vault;
        name = _name;
        asset = IVault(vault).asset();
        (address _aToken, , ) = protocolDataProvider.getReserveTokensAddresses(
            asset
        );
        aToken = _aToken;
    }

    function maxDeposit(address receiver)
        public
        view
        returns (uint256 maxAssets)
    {
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

    function deposit(uint256 assets, address receiver)
        public
        returns (uint256)
    {
        require(msg.sender == vault && msg.sender == receiver);

        // transfer and invest
        IERC20(asset).transferFrom(vault, address(this), assets);
        _invest();
        return assets;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        // TODO: review
        return Math.min(IERC20(asset).balanceOf(aToken), _totalAssets());
    }

    function withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) public returns (uint256) {
        require(amount <= maxWithdraw(owner), "withdraw more than max");
        return _withdraw(amount, receiver, owner);
    }

    function _freeFunds(uint256 _amount)
        internal
        returns (uint256 _amountFreed)
    {
        uint256 idle_amount = balanceOfAsset();
        if (_amount <= idle_amount) {
            // we have enough idle assets for the vault to take
            _amountFreed = _amount;
        } else {
            // We need to take from Aave enough to reach _amount
            // Balance of
            // We run with 'unchecked' as we are safe from underflow
            unchecked {
                _withdrawFromAave(
                    Math.min(_amount - idle_amount, balanceOfAToken())
                );
            }
            _amountFreed = balanceOfAsset();
        }
    }

    function _withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) internal returns (uint256) {
        uint256 amount_to_withdraw = _freeFunds(amount);
        IERC20(asset).transfer(receiver, amount_to_withdraw);
        return amount_to_withdraw;
    }

    function _totalAssets() internal view returns (uint256) {
        return balanceOfAsset() + balanceOfAToken();
    }

    function _invest() internal {
        uint256 available_to_invest = balanceOfAsset();
        require(available_to_invest > 0, "no funds to invest");
        _depositToAave(available_to_invest);
    }

    function _depositToAave(uint256 amount) internal {
        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), asset, amount);
        lp.deposit(asset, amount, address(this), 0);
    }

    function _withdrawFromAave(uint256 amount) internal {
        ILendingPool lp = _lendingPool();
        _checkAllowance(address(lp), aToken, amount);
        lp.withdraw(asset, amount, address(this));
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).approve(_contract, 0);
            IERC20(_token).approve(_contract, _amount);
        }
    }

    function _lendingPool() internal view returns (ILendingPool) {
        return
            ILendingPool(
                protocolDataProvider.ADDRESSES_PROVIDER().getLendingPool()
            );
    }

    function balanceOfAToken() internal view returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }

    function balanceOfAsset() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
