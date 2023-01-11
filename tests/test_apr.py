from ape import reverts, chain, Contract, accounts
import pytest
from utils.constants import REL_ERROR, MAX_INT


def test_apr(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
    aave_lending_pool,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    # get aave supply rates in RAY, downscale to WAD
    current_real_apr = aave_lending_pool.getReserveData(asset)[3] / 1e9
    current_expected_apr = strategy.aprAfterDebtChange(0)

    # strategy calculates lower bound of apr so we don't check upper bound
    assert current_real_apr >= current_expected_apr


def test_apr_after_asset_deposit(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
    aave_lending_pool,
    whale,
):
    amount_to_deposit = int(amount / 2)
    vault, strategy = create_vault_and_strategy(gov, amount_to_deposit)
    provide_strategy_with_debt(gov, strategy, vault, amount)
    
    deposit_expected_apr = strategy.aprAfterDebtChange(amount_to_deposit)
    asset.approve(vault.address, amount_to_deposit, sender=whale)
    vault.deposit(amount_to_deposit, whale.address, sender=whale)
    deposit_real_apr = strategy.aprAfterDebtChange(0)

    assert deposit_real_apr >= deposit_expected_apr


def test_apr_after_asset_withdraw(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
    aave_lending_pool,
    whale,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    provide_strategy_with_debt(gov, strategy, vault, amount)

    withdraw_amount = int(amount / 2)
    withdraw_expected_apr = strategy.aprAfterDebtChange(withdraw_amount)
    vault.withdraw(withdraw_amount, whale, whale, [strategy], sender=whale)
    withdraw_real_apr = strategy.aprAfterDebtChange(0)

    assert  withdraw_real_apr >= withdraw_real_apr
