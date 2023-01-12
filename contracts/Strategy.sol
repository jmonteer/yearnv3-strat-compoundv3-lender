// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {BaseStrategy, IERC20, SafeERC20} from "./BaseStrategy.sol";

import "./interfaces/IVault.sol";
import "./interfaces/aave/ILendingPool.sol";
import "./interfaces/aave/IProtocolDataProvider.sol";
import "./interfaces/aave/IReserveInterestRateStrategy.sol";
import "./interfaces/morpho/IMorpho.sol";
import "./interfaces/morpho/IRewardsDistributor.sol";
import "./interfaces/morpho/ILens.sol";
import "./interfaces/ySwaps/ITradeFactory.sol";
import "./libraries/aave/DataTypes.sol";
import "./libraries/morpho/WadRayMath.sol";
import "./libraries/morpho/PercentageMath.sol";

contract Strategy is BaseStrategy, Ownable {
    using SafeERC20 for IERC20;

    ILendingPool internal constant POOL =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
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
    address public rewardsDistributor =
        0x3B14E5C73e0A56D607A8688098326fD4b4292135;
    // aToken = Morpho Aave Market for want token
    address public aToken;
    // Max gas used for matching with p2p deals
    uint256 public maxGasForMatching = 100000;
    address public tradeFactory = 0xd6a8ae62f4d593DAf72E2D7c9f7bDB89AB069F06;

    constructor(
        address _vault,
        string memory _name,
        address _aToken
    ) BaseStrategy(_vault, _name) {
        aToken = _aToken;
        IMorpho.Market memory market = MORPHO.market(aToken);
        require(market.underlyingToken == asset, "WRONG A_TOKEN");
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

    function _withdraw(
        uint256 amount
    ) internal override returns (uint256 amountFreed) {
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
                // morpho will downgrade to max user value
                MORPHO.withdraw(aToken, Math.min(_amount, aaveLiquidity));
            }
        }
    }

    function _depositToMorpho(uint256 _amount) internal {
        _checkAllowance(address(MORPHO), asset, _amount);
        MORPHO.supply(aToken, address(this), _amount, maxGasForMatching);
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

    function aprAfterDebtChange(
        int256 delta
    ) external view returns (uint256 apr) {
        if (delta == 0) {
            apr = LENS.getCurrentUserSupplyRatePerYear(aToken, address(this));
        } else if (delta > 0) {
            apr = aprAfterLiquiditySupply(uint256(delta));
        } else {
            apr = aprAfterLiquidityWithdraw(uint256(-delta));
        }
        apr = apr / WadRayMath.WAD_RAY_RATIO;
    }

    function aprAfterLiquiditySupply(
        uint256 _amount
    ) internal view returns (uint256 apr) {
        ILens.Indexes memory indexes = LENS.getIndexes(aToken);
        IMorpho.Market memory market = MORPHO.market(aToken);
        IMorpho.Delta memory delta = MORPHO.deltas(aToken);
        IMorpho.SupplyBalance memory supplyBalance = MORPHO.supplyBalanceInOf(
            aToken,
            address(this)
        );

        /// Peer-to-peer supply ///

        uint256 repaidToPool;
        if (!market.isP2PDisabled) {
            // Match the peer-to-peer borrow delta.
            if (delta.p2pBorrowDelta > 0) {
                uint256 matchedDelta = Math.min(
                    WadRayMath.rayMul(
                        delta.p2pBorrowDelta,
                        indexes.poolBorrowIndex
                    ),
                    _amount
                );

                supplyBalance.inP2P += WadRayMath.rayDiv(
                    matchedDelta,
                    indexes.p2pSupplyIndex
                );
                repaidToPool += matchedDelta;
                _amount -= matchedDelta;
            }

            // Promote pool borrowers.
            if (_amount > 0) {
                address firstPoolBorrower = MORPHO.getHead(
                    aToken,
                    IMorpho.PositionType.BORROWERS_ON_POOL
                );
                uint256 firstPoolBorrowerBalance = MORPHO
                    .borrowBalanceInOf(aToken, firstPoolBorrower)
                    .onPool;

                if (firstPoolBorrowerBalance > 0) {
                    uint256 matchedP2P = Math.min(
                        WadRayMath.rayMul(
                            firstPoolBorrowerBalance,
                            indexes.poolBorrowIndex
                        ),
                        _amount
                    );

                    supplyBalance.inP2P += WadRayMath.rayDiv(
                        matchedP2P,
                        indexes.p2pSupplyIndex
                    );
                    repaidToPool += matchedP2P;
                    _amount -= matchedP2P;
                }
            }
        }

        /// Pool supply ///

        // Supply on pool.
        uint256 suppliedToPool = _amount;
        supplyBalance.onPool += WadRayMath.rayDiv(
            suppliedToPool,
            indexes.poolSupplyIndex
        );

        (uint256 poolSupplyRate, uint256 variableBorrowRate) = getAaveRates(
            suppliedToPool,
            0,
            repaidToPool,
            0
        );

        uint256 p2pSupplyRate = computeP2PSupplyRatePerYear(
            P2PRateComputeParams({
                poolSupplyRatePerYear: poolSupplyRate,
                poolBorrowRatePerYear: variableBorrowRate,
                poolIndex: indexes.poolSupplyIndex,
                p2pIndex: indexes.p2pSupplyIndex,
                p2pDelta: delta.p2pSupplyDelta,
                p2pAmount: delta.p2pSupplyAmount,
                p2pIndexCursor: market.p2pIndexCursor,
                reserveFactor: market.reserveFactor
            })
        );

        (apr, ) = getWeightedRate(
            p2pSupplyRate,
            poolSupplyRate,
            WadRayMath.rayMul(supplyBalance.inP2P, indexes.p2pSupplyIndex),
            WadRayMath.rayMul(supplyBalance.onPool, indexes.poolSupplyIndex)
        );
    }

    function aprAfterLiquidityWithdraw(
        uint256 _amount
    ) internal view returns (uint256 apr) {
        ILens.Indexes memory indexes = LENS.getIndexes(aToken);
        IMorpho.Market memory market = MORPHO.market(aToken);
        IMorpho.Delta memory delta = MORPHO.deltas(aToken);
        IMorpho.SupplyBalance memory supplyBalance = MORPHO.supplyBalanceInOf(
            aToken,
            address(this)
        );

        /// Pool withdraw ///

        // Withdraw supply on pool.
        uint256 withdrawnFromPool;
        if (supplyBalance.onPool > 0) {
            withdrawnFromPool += Math.min(
                WadRayMath.rayMul(
                    supplyBalance.onPool,
                    indexes.poolSupplyIndex
                ),
                _amount
            );

            supplyBalance.onPool -= WadRayMath.rayDiv(
                withdrawnFromPool,
                indexes.poolSupplyIndex
            );
            _amount -= withdrawnFromPool;
        }

        // Reduce the peer-to-peer supply delta.
        if (delta.p2pSupplyDelta > 0) {
            uint256 matchedDelta = Math.min(
                WadRayMath.rayMul(
                    delta.p2pSupplyDelta,
                    indexes.poolSupplyIndex
                ),
                _amount
            );

            supplyBalance.inP2P -= WadRayMath.rayDiv(
                matchedDelta,
                indexes.p2pSupplyIndex
            );
            delta.p2pSupplyDelta -= Math.min(
                delta.p2pSupplyDelta,
                WadRayMath.rayDiv(matchedDelta, indexes.poolSupplyIndex)
            );
            withdrawnFromPool += matchedDelta;
            _amount -= matchedDelta;
        }

        /// Transfer withdraw ///

        // Promote pool suppliers.
        if (_amount > 0 && supplyBalance.inP2P > 0 && !market.isP2PDisabled) {
            address firstPoolSupplier = MORPHO.getHead(
                aToken,
                IMorpho.PositionType.SUPPLIERS_ON_POOL
            );
            uint256 firstPoolSupplierBalance = MORPHO
                .supplyBalanceInOf(aToken, firstPoolSupplier)
                .onPool;

            if (firstPoolSupplierBalance > 0) {
                uint256 matchedP2P = Math.min(
                    WadRayMath.rayMul(
                        firstPoolSupplierBalance,
                        indexes.poolSupplyIndex
                    ),
                    _amount
                );

                supplyBalance.inP2P -= WadRayMath.rayDiv(
                    matchedP2P,
                    indexes.p2pSupplyIndex
                );
                withdrawnFromPool += matchedP2P;
                _amount -= matchedP2P;
            }
        }

        /// Breaking withdraw ///

        // Demote peer-to-peer borrowers.
        uint256 borrowedFromPool = Math.min(
            WadRayMath.rayMul(supplyBalance.inP2P, indexes.p2pSupplyIndex),
            _amount
        );
        if (borrowedFromPool > 0) {
            delta.p2pSupplyAmount -= Math.min(
                delta.p2pSupplyAmount,
                WadRayMath.rayDiv(borrowedFromPool, indexes.p2pSupplyIndex)
            );
        }

        (uint256 poolSupplyRate, uint256 variableBorrowRate) = getAaveRates(
            0,
            borrowedFromPool,
            0,
            withdrawnFromPool
        );

        uint256 p2pSupplyRate = computeP2PSupplyRatePerYear(
            P2PRateComputeParams({
                poolSupplyRatePerYear: poolSupplyRate,
                poolBorrowRatePerYear: variableBorrowRate,
                poolIndex: indexes.poolSupplyIndex,
                p2pIndex: indexes.p2pSupplyIndex,
                p2pDelta: delta.p2pSupplyDelta,
                p2pAmount: delta.p2pSupplyAmount,
                p2pIndexCursor: market.p2pIndexCursor,
                reserveFactor: market.reserveFactor
            })
        );

        (apr, ) = getWeightedRate(
            p2pSupplyRate,
            poolSupplyRate,
            WadRayMath.rayMul(supplyBalance.inP2P, indexes.p2pSupplyIndex),
            WadRayMath.rayMul(supplyBalance.onPool, indexes.poolSupplyIndex)
        );
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

    // ---------------------- RATES CALCULATIONS ----------------------

    /// @dev Returns the rate experienced based on a given pool & peer-to-peer distribution.
    /// @param _p2pRate The peer-to-peer rate (in a unit common to `_poolRate` & `weightedRate`).
    /// @param _poolRate The pool rate (in a unit common to `_p2pRate` & `weightedRate`).
    /// @param _balanceInP2P The amount of balance matched peer-to-peer (in a unit common to `_balanceOnPool`).
    /// @param _balanceOnPool The amount of balance supplied on pool (in a unit common to `_balanceInP2P`).
    /// @return weightedRate The rate experienced by the given distribution (in a unit common to `_p2pRate` & `_poolRate`).
    /// @return totalBalance The sum of peer-to-peer & pool balances.
    function getWeightedRate(
        uint256 _p2pRate,
        uint256 _poolRate,
        uint256 _balanceInP2P,
        uint256 _balanceOnPool
    ) internal pure returns (uint256 weightedRate, uint256 totalBalance) {
        totalBalance = _balanceInP2P + _balanceOnPool;
        if (totalBalance == 0) return (weightedRate, totalBalance);

        if (_balanceInP2P > 0)
            weightedRate = WadRayMath.rayMul(
                _p2pRate,
                WadRayMath.rayDiv(_balanceInP2P, totalBalance)
            );
        if (_balanceOnPool > 0)
            weightedRate =
                weightedRate +
                WadRayMath.rayMul(
                    _poolRate,
                    WadRayMath.rayDiv(_balanceOnPool, totalBalance)
                );
    }

    struct PoolRatesVars {
        uint256 availableLiquidity;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 avgStableBorrowRate;
        uint256 reserveFactor;
    }

    /// @notice Computes and returns the underlying pool rates on AAVE.
    /// @param _supplied The amount hypothetically supplied.
    /// @param _borrowed The amount hypothetically borrowed.
    /// @param _repaid The amount hypothetically repaid.
    /// @param _withdrawn The amount hypothetically withdrawn.
    /// @return supplyRate The market's pool supply rate per year (in ray).
    /// @return variableBorrowRate The market's pool borrow rate per year (in ray).
    function getAaveRates(
        uint256 _supplied,
        uint256 _borrowed,
        uint256 _repaid,
        uint256 _withdrawn
    ) private view returns (uint256 supplyRate, uint256 variableBorrowRate) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(asset);
        PoolRatesVars memory vars;
        (
            vars.availableLiquidity,
            vars.totalStableDebt,
            vars.totalVariableDebt,
            ,
            ,
            ,
            vars.avgStableBorrowRate,
            ,
            ,

        ) = AAVE_DATA_PROIVDER.getReserveData(asset);
        (, , , , vars.reserveFactor, , , , , ) = AAVE_DATA_PROIVDER
            .getReserveConfigurationData(asset);

        (supplyRate, , variableBorrowRate) = IReserveInterestRateStrategy(
            reserve.interestRateStrategyAddress
        ).calculateInterestRates(
                asset,
                vars.availableLiquidity +
                    _supplied +
                    _repaid -
                    _borrowed -
                    _withdrawn, // repaidToPool is added to avaiable liquidity by aave impl, see: https://github.com/aave/protocol-v2/blob/0829f97c5463f22087cecbcb26e8ebe558592c16/contracts/protocol/lendingpool/LendingPool.sol#L277
                vars.totalStableDebt,
                vars.totalVariableDebt + _borrowed - _repaid,
                vars.avgStableBorrowRate,
                vars.reserveFactor
            );
    }

    struct P2PRateComputeParams {
        uint256 poolSupplyRatePerYear; // The pool supply rate per year (in ray).
        uint256 poolBorrowRatePerYear; // The pool borrow rate per year (in ray).
        uint256 poolIndex; // The last stored pool index (in ray).
        uint256 p2pIndex; // The last stored peer-to-peer index (in ray).
        uint256 p2pDelta; // The peer-to-peer delta for the given market (in pool unit).
        uint256 p2pAmount; // The peer-to-peer amount for the given market (in peer-to-peer unit).
        uint256 p2pIndexCursor; // The index cursor of the given market (in bps).
        uint256 reserveFactor; // The reserve factor of the given market (in bps).
    }

    /// @notice Computes and returns the peer-to-peer supply rate per year of a market given its parameters.
    /// @param _params The computation parameters.
    /// @return p2pSupplyRate The peer-to-peer supply rate per year (in ray).
    function computeP2PSupplyRatePerYear(
        P2PRateComputeParams memory _params
    ) internal pure returns (uint256 p2pSupplyRate) {
        if (_params.poolSupplyRatePerYear > _params.poolBorrowRatePerYear) {
            p2pSupplyRate = _params.poolBorrowRatePerYear; // The p2pSupplyRate is set to the poolBorrowRatePerYear because there is no rate spread.
        } else {
            p2pSupplyRate = PercentageMath.weightedAvg(
                _params.poolSupplyRatePerYear,
                _params.poolBorrowRatePerYear,
                _params.p2pIndexCursor
            );

            p2pSupplyRate =
                p2pSupplyRate -
                PercentageMath.percentMul(
                    (p2pSupplyRate - _params.poolSupplyRatePerYear),
                    _params.reserveFactor
                );
        }

        if (_params.p2pDelta > 0 && _params.p2pAmount > 0) {
            uint256 shareOfTheDelta = Math.min(
                WadRayMath.rayDiv(
                    WadRayMath.rayMul(_params.p2pDelta, _params.poolIndex),
                    WadRayMath.rayMul(_params.p2pAmount, _params.p2pIndex)
                ), // Using ray division of an amount in underlying decimals by an amount in underlying decimals yields a value in ray.
                WadRayMath.RAY // To avoid shareOfTheDelta > 1 with rounding errors.
            ); // In ray.

            p2pSupplyRate =
                WadRayMath.rayMul(
                    p2pSupplyRate,
                    WadRayMath.RAY - shareOfTheDelta
                ) +
                WadRayMath.rayMul(
                    _params.poolSupplyRatePerYear,
                    shareOfTheDelta
                );
        }
    }
}
