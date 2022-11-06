// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "./interfaces/IVault.sol";
import "./BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ILenderStrategy {
    function aprAfterDebtChange(
        uint256 _delta
    ) external view returns (uint256 _apr);
}

contract LenderDebtManager is Ownable {
    IVault public vault;
    IERC20 public asset;
    address[] public strategies;

    uint256 public lastBlockUpdate;

    constructor(IVault _vault) {
        vault = _vault;
        asset = IERC20(_vault.asset());
    }

    function addStrategy(address _strategy) external {
        // NOTE: if the strategy is added to the vault, it should be added here, so no need for authorizing
        require(vault.strategies(_strategy).activation != 0);

        for (uint256 i = 0; i < strategies.length; ++i) {
            if (strategies[i] == _strategy) return;
        }

        strategies.push(_strategy);
    }

    function removeStrategy(address _strategy) external {
        // TODO: replace with a query to the vault to see if the account is allowed
        bool _isManager = msg.sender == owner();
        // Strategy can't be active but an authorized account can force deletion if still active
        require(vault.strategies(_strategy).activation == 0 || _isManager);

        uint256 strategyCount = strategies.length;
        for (uint256 i = 0; i < strategyCount; ++i) {
            if (strategies[i] == _strategy) {
                // if not last element
                if (i != strategyCount - 1) {
                    strategies[i] = strategies[strategyCount - 1];
                }
                strategies.pop();
                return;
            }
        }
    }

    function updateAllocations() public {
        (uint256 _lowest, , uint256 _highest, ) = estimateAdjustPosition();

        require(_lowest != _highest); // dev: no debt changes

        address _lowestStrategy = strategies[_lowest];
        address _highestStrategy = strategies[_highest];
        uint256 _lowestCurrentDebt = vault.strategies(_lowestStrategy).current_debt;
        uint256 _highestCurrentDebt = vault.strategies(_highestStrategy).current_debt;

        vault.update_debt(_lowestStrategy, 0);
        vault.update_debt(_highestStrategy, _lowestCurrentDebt + _highestCurrentDebt);
    }

    //estimates highest and lowest apr lenders. Public for debugging purposes but not much use to general public
    function estimateAdjustPosition()
        public
        view
        returns (
            uint256 _lowest,
            uint256 _lowestApr,
            uint256 _highest,
            uint256 _potential
        )
    {
        uint256 strategyCount = strategies.length;
        if (strategyCount == 0) {
            return (type(uint256).max, 0, type(uint256).max, 0);
        }

        if (strategyCount == 1) {
            ILenderStrategy _strategy = ILenderStrategy(strategies[0]);
            uint256 apr = _strategy.aprAfterDebtChange(0);
            return (0, apr, 0, apr);
        }

        //all loose assets are to be invested
        uint256 looseAssets = vault.total_idle();

        // our simple algo
        // get the lowest apr strat
        // cycle through and see who could take its funds plus want for the highest apr
        _lowestApr = type(uint256).max;
        _lowest = 0;
        uint256 lowestCurrentDebt = 0;
        for (uint256 i = 0; i < strategyCount; ++i) {
            ILenderStrategy _strategy = ILenderStrategy(strategies[i]);
            uint256 _strategyCurrentDebt = vault
                .strategies(address(_strategy))
                .current_debt;
            if (_strategyCurrentDebt > 0) {
                uint256 apr = _strategy.aprAfterDebtChange(0);
                if (apr < _lowestApr) {
                    _lowestApr = apr;
                    _lowest = i;
                    lowestCurrentDebt = _strategyCurrentDebt;
                }
            }
        }

        uint256 toAdd = lowestCurrentDebt + looseAssets;

        uint256 highestApr = 0;
        _highest = 0;

        for (uint256 i = 0; i < strategyCount; ++i) {
            uint256 apr;
            ILenderStrategy _strategy = ILenderStrategy(strategies[i]);
            apr = _strategy.aprAfterDebtChange(toAdd);

            if (apr > highestApr) {
                highestApr = apr;
                _highest = i;
                _potential = apr;
            }
        }
    }
}
