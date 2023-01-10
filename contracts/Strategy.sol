// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {BaseStrategy, IERC20, SafeERC20} from "BaseStrategy.sol";

import "./interfaces/IVault.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/aave/IProtocolDataProvider.sol";
import "./interfaces/aave/IReserveInterestRateStrategy.sol";
import "./libraries/aave/DataTypes.sol";
import "./interfaces/morpho/IMorpho.sol";
import "./interfaces/morpho/IRewardsDistributor.sol";
import "./interfaces/morpho/ILens.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";

contract Strategy is BaseStrategy, Ownable {
    using SafeERC20 for IERC20;

    ILendingPool internal constant POOL = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IProtocolDataProvider internal constant AAVE_DATA_PROIVDER =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    // Morpho is a contract to handle interaction with the protocol
    IMorpho internal constant MORPHO =
        IMorpho(0x777777c9898D384F785Ee44Acfe945efDFf5f3E0);
    // Lens is a contract to fetch data about Morpho protocol
    ILens internal constant LENS =
        ILens(0x507fA343d0A90786d86C7cd885f5C49263A91FF4);
    // reward token, not currently listed
    address internal constant MORPHO_TOKEN =
        0x9994E35Db50125E0DF82e4c2dde62496CE330999;
    // used for claiming reward Morpho token
    address public rewardsDistributor;
    // aToken = Morpho Aave Market for want token
    address public aToken;
    // Max gas used for matching with p2p deals
    uint256 public maxGasForMatching;

    address public tradeFactory;

    constructor(
        address _vault,
        string memory _name,
        address _aToken
    ) BaseStrategy(_vault, _name) {
        aToken = _aToken;
        IMorpho.Market memory market = MORPHO.market(aToken);
        require(market.underlyingToken == IVault(vault).asset(), "WRONG ATOKEN");
        IERC20(IVault(vault).asset()).safeApprove(
            address(MORPHO),
            type(uint256).max
        );
    }

    /**
     * @notice Set the maximum amount of gas to consume to get matched in peer-to-peer.
     * @dev
     *  This value is needed in Morpho supply liquidity calls.
     *  Supplyed liquidity goes to loop with current loans on Morpho
     *  and creates a match for p2p deals. The loop starts from bigger liquidity deals.
     *  The default value set by Morpho is 100000.
     * @param _maxGasForMatching new maximum gas value for P2P matching
     */
    function setMaxGasForMatching(
        uint256 _maxGasForMatching
    ) external onlyOwner {
        maxGasForMatching = _maxGasForMatching;
    }

    /**
     * @notice Set new rewards distributor contract
     * @param _rewardsDistributor address of new contract
     */
    function setRewardsDistributor(
        address _rewardsDistributor
    ) external onlyOwner {
        rewardsDistributor = _rewardsDistributor;
    }

    function _maxWithdraw(
        address owner
    ) internal view override returns (uint256) {
        if (owner == vault) {
            // return total value we have even if illiquid so the vault doesnt assess incorrect unrealized losses
            return _totalAssets();
        } else {
            return 0;
        }
    }

    function _withdraw(uint256 amount) internal override returns (uint256 amountFreed) {
        uint256 idleAmount = balanceOfAsset();
        if (amount > idleAmount) {
            // safe from underflow
            unchecked {
                _withdrawFromMorpho(amount - idleAmount);
            }
            amountFreed = balanceOfAsset();
        } else {
            // we have enough idle assets for the vault to take
            amountFreed = amount;
        }
    }

    function _totalAssets() internal view override returns (uint256) {
        (, , uint256 totalBalance) = underlyingBalance();
        return balanceOfAsset() + totalBalance;
    }

    function _invest() internal override {
        uint256 _availableToInvest = balanceOfAsset();
        if (_availableToInvest == 0) {
            return;
        }

        _depositToMorpho(_availableToInvest);
    }

    function _withdrawFromMorpho(uint256 _amount) internal {
        // if the market is paused we cannot withdraw
        IMorpho.Market memory market = MORPHO.market(aToken);
        if (!market.isPaused) {
            // check if there is enough liquidity in aave
            uint256 aaveLiquidity = IERC20(asset).balanceOf(address(aToken));
            if (aaveLiquidity > 1) {
                MORPHO.withdraw(aToken, Math.min(_amount, aaveLiquidity));
            }
        }
    }

    function _depositToMorpho(uint256 _amount) internal {
        // _checkAllowance(address(MORPHO), asset, _amount);
        MORPHO.supply(
            aToken,
            address(this),
            _amount,
            maxGasForMatching
        );
    }

    // function _checkAllowance(
    //     address _contract,
    //     address _token,
    //     uint256 _amount
    // ) internal {
    //     if (IERC20(_token).allowance(address(this), _contract) < _amount) {
    //         IERC20(_token).approve(_contract, 0);
    //         IERC20(_token).approve(_contract, _amount);
    //     }
    // }

    /**
     * @notice Returns the value deposited in Morpho protocol
     * @return balanceInP2P Amount supplied through Morpho that is matched peer-to-peer
     * @return balanceOnPool Amount supplied through Morpho on the underlying protocol's pool
     * @return totalBalance Equals `balanceOnPool` + `balanceInP2P`
     */
    function underlyingBalance()
        public
        view
        returns (
            uint256 balanceInP2P,
            uint256 balanceOnPool,
            uint256 totalBalance
        )
    {
        (balanceInP2P, balanceOnPool, totalBalance) = LENS
            .getCurrentSupplyBalanceInOf(aToken, address(this));
    }

    function balanceOfAsset() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function aprAfterDebtChange(int256 delta) external view returns (uint256 apr) {
        if (delta < 0) {
            (, , uint256 totalBalance) = underlyingBalance();
            // TODO: think how to implement logic for 
            // if (delta > balanceOnPool) {
            // }
            // simulated supply rate is a lower bound
            // use address(0) because we simulate removing liquidity
            (apr, , , ) = LENS.getNextUserSupplyRatePerYear(
                aToken,
                address(0),
                totalBalance
            );
            // downscale to WAD(1e18)
            apr = apr / 1e9;
        } else {
            // add amount to current user
            // simulated supply rate is a lower bound 
            (apr, , , ) = LENS.getNextUserSupplyRatePerYear(aToken, address(this), uint256(delta));
            // downscale to WAD(1e18)
            apr = apr / 1e9;
        }
    }

    function _tend() internal override {
        // no rewards so only if what is free
        _invest();
    }

    function _migrate(address _newStrategy) internal override {
        // withdraw all
        _withdrawFromMorpho(type(uint256).max);

        uint256 looseAsset = balanceOfAsset();
        IERC20(asset).transfer(_newStrategy, looseAsset);
    }

    /**
     * @notice Claims MORPHO rewards. Use Morpho API to get the data: https://api.morpho.xyz/rewards/{address}
     * @dev See stages of Morpho rewards distibution: https://docs.morpho.xyz/usdmorpho/ages-and-epochs/age-2
     * @param _account The address of the claimer.
     * @param _claimable The overall claimable amount of token rewards.
     * @param _proof The merkle proof that validates this claim.
     */
    function claimMorphoRewards(
        address _account,
        uint256 _claimable,
        bytes32[] calldata _proof
    ) external onlyOwner {
        IRewardsDistributor(rewardsDistributor).claim(
            _account,
            _claimable,
            _proof
        );
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------
    // potential to rug
    function setTradeFactory(address _tradeFactory) external onlyOwner {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        ITradeFactory tf = ITradeFactory(_tradeFactory);

        IERC20(MORPHO_TOKEN).safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(MORPHO_TOKEN, address(asset));

        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyOwner {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(MORPHO_TOKEN).safeApprove(tradeFactory, 0);
        ITradeFactory(tradeFactory).disable(MORPHO_TOKEN, address(asset));
        tradeFactory = address(0);
    }
}
