// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20, BaseStrategy} from "BaseStrategy.sol";
import "interfaces/IVault.sol";
import {ISwapRouter} from "interfaces/ISwapRouter.sol";
import {Comet, CometStructs, CometRewards} from "interfaces/CompoundV3.sol";

contract Strategy is BaseStrategy, Ownable {
    //For apr calculations
    uint256 private constant DAYS_PER_YEAR = 365;
    uint256 private constant SECONDS_PER_DAY = 60 * 60 * 24;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 internal immutable BASE_MANTISSA;
    uint256 internal immutable BASE_INDEX_SCALE;

    //Rewards stuff
    //Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    //Fees for the V3 pools if the supply is incentivized
    uint24 public compToEthFee;
    uint24 public ethToAssetFee;
    //Reward token
    address internal constant comp = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address internal constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    CometRewards public constant rewardsContract =
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40);

    Comet public immutable cToken;

    constructor(
        address _vault,
        string memory _name,
        Comet _cToken
    ) BaseStrategy(_vault, _name) {
        cToken = _cToken;
        require(cToken.baseToken() == IVault(vault).asset());

        BASE_MANTISSA = cToken.baseScale();
        BASE_INDEX_SCALE = cToken.baseIndexScale();

        compToEthFee = 3000;
        ethToAssetFee = 500;
    }

    function setUniFees(
        uint24 _compToEth,
        uint24 _ethToAsset
    ) external onlyOwner {
        compToEthFee = _compToEth;
        ethToAssetFee = _ethToAsset;
    }

    function _maxWithdraw(
        address owner
    ) internal view override returns (uint256) {
        // TODO: may not be accurate due to unaccrued balance in cToken
        return
            Math.min(IERC20(asset).balanceOf(address(cToken)), _totalAssets());
    }

    function _freeFunds(
        uint256 _amount
    ) internal returns (uint256 _amountFreed) {
        uint256 _idleAmount = balanceOfAsset();
        if (_amount <= _idleAmount) {
            // we have enough idle assets for the vault to take
            _amountFreed = _amount;
        } else {
            // NOTE: we need the balance updated
            cToken.accrueAccount(address(this));
            // We need to take from Aave enough to reach _amount
            // Balance of
            // We run with 'unchecked' as we are safe from underflow
            unchecked {
                _withdrawFromComet(
                    Math.min(_amount - _idleAmount, balanceOfCToken())
                );
            }
            _amountFreed = balanceOfAsset();
        }
    }

    function _withdraw(
        uint256 amount,
        address receiver,
        address owner
    ) internal override returns (uint256) {
        return _freeFunds(amount);
    }

    function _totalAssets() internal view override returns (uint256) {
        return balanceOfAsset() + balanceOfCToken();
    }

    function _invest() internal override {
        uint256 _availableToInvest = balanceOfAsset();
        _depositToComet(_availableToInvest);
    }

    function _withdrawFromComet(uint256 _amount) internal {
        cToken.withdraw(address(asset), _amount);
    }

    function _depositToComet(uint256 _amount) internal {
        Comet _cToken = cToken;
        _checkAllowance(address(_cToken), asset, _amount);
        _cToken.supply(address(asset), _amount);
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

    function balanceOfCToken() internal view returns (uint256) {
        return IERC20(cToken).balanceOf(address(this));
    }

    function balanceOfAsset() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function aprAfterDebtChange(int256 delta) external view returns (uint256) {
        uint256 borrows = cToken.totalBorrow();
        uint256 supply = cToken.totalSupply();

        uint256 newUtilization = (borrows * 1e18) /
            uint256(int256(supply) + delta);
        uint256 newSupplyRate = cToken.getSupplyRate(newUtilization) *
            SECONDS_PER_YEAR;
        uint256 rewardRate = getRewardAprForSupplyBase(delta);
        return newSupplyRate + rewardRate;
    }

    function getRewardAprForSupplyBase(
        int256 newAmount
    ) public view returns (uint256) {
        //SupplyRewardApr = (rewardTokenPriceInUsd * rewardToSupplierssPerDay / (baseTokenTotalSupply * baseTokenPriceInUsd)) * DAYS_PER_YEAR;
        unchecked {
            uint256 rewardToSuppliersPerDay = (cToken
                .baseTrackingSupplySpeed() *
                SECONDS_PER_DAY *
                BASE_INDEX_SCALE) / BASE_MANTISSA;
            if (rewardToSuppliersPerDay == 0) return 0;
            return
                ((getCompoundPrice(getPriceFeedAddress(comp)) *
                    rewardToSuppliersPerDay) /
                    (uint256(int256(cToken.totalSupply()) + newAmount) *
                        getCompoundPrice(cToken.baseTokenPriceFeed()))) *
                DAYS_PER_YEAR;
        }
    }

    function getPriceFeedAddress(
        address asset
    ) internal view returns (address) {
        return cToken.getAssetInfoByAddress(asset).priceFeed;
    }

    function getCompoundPrice(
        address singleAssetPriceFeed
    ) internal view returns (uint) {
        return cToken.getPrice(singleAssetPriceFeed);
    }

    function getRewardsOwed() public view returns (uint256) {
        CometStructs.RewardConfig memory config = rewardsContract.rewardConfig(
            address(cToken)
        );
        uint256 accrued = cToken.baseTrackingAccrued(address(this));
        if (config.shouldUpscale) {
            accrued *= config.rescaleFactor;
        } else {
            accrued /= config.rescaleFactor;
        }
        uint256 claimed = rewardsContract.rewardsClaimed(
            address(cToken),
            address(this)
        );

        return accrued > claimed ? accrued - claimed : 0;
    }

    /*
     * External function that Claims the reward tokens due to this contract address
     */
    function claimRewards() external onlyOwner {
        _claimRewards();
    }

    /*
     * Claims the reward tokens due to this contract address
     */
    function _claimRewards() internal {
        rewardsContract.claim(address(cToken), address(this), true);
    }

    //TODO add modifier for keepers
    function harvest() external onlyOwner {
        _claimRewards();

        _disposeOfComp();

        uint256 _availableToInvest = balanceOfAsset();
        if (_availableToInvest > 0) {
            _depositToComet(_availableToInvest);
        }
    }

    function _disposeOfComp() internal {
        uint256 _comp = IERC20(comp).balanceOf(address(this));

        if (_comp > 0) {
            _checkAllowance(address(router), comp, _comp);

            if (address(asset) == weth) {
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                    .ExactInputSingleParams(
                        comp, // tokenIn
                        address(asset), // tokenOut
                        compToEthFee, // comp-eth fee
                        address(this), // recipient
                        block.timestamp, // deadline
                        _comp, // amountIn
                        0, // amountOut
                        0 // sqrtPriceLimitX96
                    );

                router.exactInputSingle(params);
            } else {
                bytes memory path = abi.encodePacked(
                    comp, // comp-ETH
                    compToEthFee,
                    weth, // ETH-asset
                    ethToAssetFee,
                    address(asset)
                );

                // Proceeds from Comp are not subject to minExpectedSwapPercentage
                // so they could get sandwiched if we end up in an uncle block
                router.exactInput(
                    ISwapRouter.ExactInputParams(
                        path,
                        address(this),
                        block.timestamp,
                        _comp,
                        0
                    )
                );
            }
        }
    }
}
