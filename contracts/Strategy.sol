// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20, BaseStrategy, SafeERC20} from "BaseStrategy.sol";

import "interfaces/IVault.sol";
import {Comet, CometStructs, CometRewards} from "interfaces/CompoundV3.sol";
import {ITradeFactory} from "interfaces/ySwaps/ITradeFactory.sol";
import {ISwapRouter} from "interfaces/univ3/ISwapRouter.sol";

contract Strategy is BaseStrategy, Ownable {
    using SafeERC20 for IERC20;

    Comet public immutable cToken;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant DAYS_PER_YEAR = 365;
    uint256 internal constant SECONDS_PER_DAY = 60 * 60 * 24;


    //Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    uint24 public compToEthFee;
    uint24 public ethToWantFee;

    address internal constant comp = 
        0xc00e94Cb662C3520282E6f5717214004A7f26888;

    address internal constant weth = 
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public tradeFactory;

    CometRewards public constant rewardsContract = 
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40);

    uint internal immutable BASE_MANTISSA;
    uint internal immutable BASE_INDEX_SCALE;

    uint256 public minCompToSell;
    uint256 public minRewardToHarvest;

    constructor(
        address _vault,
        string memory _name,
        Comet _cToken
    ) BaseStrategy(_vault, _name) {
        cToken = _cToken;
        require(cToken.baseToken() == IVault(vault).asset());

        BASE_MANTISSA = cToken.baseScale();
        BASE_INDEX_SCALE = cToken.baseIndexScale();

        minCompToSell = 0.05 ether;
        minRewardToHarvest = 10 ether;
    }

    //These will default to 0.
    //Will need to be manually set if asset is incentized before any harvests
    function setUniFees(uint24 _compToEth, uint24 _ethToWant) external onlyOwner {
        compToEthFee = _compToEth;
        ethToWantFee = _ethToWant;
    }

    function setMinRewardAmounts(uint256 _minCompToSell, uint256 _minRewardToHavest) external onlyOwner{
        minCompToSell = _minCompToSell;
        minRewardToHarvest = _minRewardToHavest;
    }

    function _maxWithdraw(
        address
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
        if (_availableToInvest == 0) {
            return;
        }

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

        uint rewardRate = getRewardAprForSupplyBase(getPriceFeedAddress(comp), delta);

        return newSupplyRate + rewardRate;
    }

    function getRewardsOwed() public view returns (uint) {
        CometStructs.RewardConfig memory config = rewardsContract.rewardConfig(address(cToken));
        uint256 accrued = cToken.baseTrackingAccrued(address(this));
        if (config.shouldUpscale) {
            accrued *= config.rescaleFactor;
        } else {
            accrued /= config.rescaleFactor;
        }
        uint256 claimed = rewardsContract.rewardsClaimed(address(cToken), address(this));

        return accrued > claimed ? accrued - claimed : 0;
    }

    function _tend() internal override {
        // claim rewards, sell rewards, reinvest rewards
        _claimCometRewards();
        _sellRewards();
        _invest();
    }

    function _tendTrigger() internal override view returns(bool) {
        if(!isBaseFeeAcceptable()) return false;

        if(getRewardsOwed() + IERC20(comp).balanceOf(address(this)) > minRewardToHarvest) return true;

    }

    function _claimCometRewards() internal {
        rewardsContract.claim(address(cToken), address(this), true);
    }

    function _sellRewards() internal {
        //check for Trade Factory implementation or that Uni fees are not set
        if(tradeFactory != address(0) || compToEthFee == 0) return;

        uint256 _comp = IERC20(comp).balanceOf(address(this));

        if (_comp > minCompToSell) {
            _checkAllowance(address(router), comp, _comp);
            if(address(asset) == weth) {
                ISwapRouter.ExactInputSingleParams memory params =
                    ISwapRouter.ExactInputSingleParams(
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
                bytes memory path =
                    abi.encodePacked(
                        comp, // comp-ETH
                        compToEthFee,
                        weth, // ETH-asset
                        ethToWantFee,
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

    /*
    * Get the current reward for supplying APR in Compound III
    * @param rewardTokenPriceFeed The address of the reward token (e.g. COMP) price feed
    * @param newAmount Any amount that will be added to the total supply in a deposit
    * @return The reward APR in USD as a decimal scaled up by 1e18
    */
    function getRewardAprForSupplyBase(address rewardTokenPriceFeed, int newAmount) public view returns (uint) {
        uint rewardToSuppliersPerDay = cToken.baseTrackingSupplySpeed() * SECONDS_PER_DAY * BASE_INDEX_SCALE / BASE_MANTISSA;
        if(rewardToSuppliersPerDay == 0) return 0;

        uint rewardTokenPriceInUsd = getCompoundPrice(rewardTokenPriceFeed);
        uint assetPriceInUsd = getCompoundPrice(cToken.baseTokenPriceFeed());
        uint assetTotalSupply = uint256(int256(cToken.totalSupply()) + newAmount);
        return rewardTokenPriceInUsd * rewardToSuppliersPerDay / (assetTotalSupply * assetPriceInUsd) * DAYS_PER_YEAR;
    }

    function getPriceFeedAddress(address asset) public view returns (address) {
        if(asset == cToken.baseToken()) {
            return cToken.baseTokenPriceFeed();
        }
        return cToken.getAssetInfoByAddress(asset).priceFeed;
    }

    function getCompoundPrice(address singleAssetPriceFeed) public view returns (uint) {
        return cToken.getPrice(singleAssetPriceFeed);
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------
    // potential to rug
    function setTradeFactory(address _tradeFactory) external onlyOwner {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        ITradeFactory tf = ITradeFactory(_tradeFactory);

        IERC20(comp).safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(comp, address(asset));
        
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyOwner {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(comp).safeApprove(tradeFactory, 0);
        ITradeFactory(tradeFactory).disable(comp, address(asset));
        tradeFactory = address(0);
    }
}
