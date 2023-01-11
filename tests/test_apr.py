from ape import Contract
import pytest


def test_apr(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
    aave_lending_pool,
    aave_protocol_provider,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    expected_apr = strategy.aprAfterDebtChange(amount)

    # calculate aave supply rate after supplying amount
    interest_rate_contract = Contract(aave_lending_pool.getReserveData(asset)[10])
    pool_data = aave_protocol_provider.getReserveData(asset)
    reserve_factor = aave_protocol_provider.getReserveConfigurationData(asset)[4]
    aave_supply_rate = interest_rate_contract.calculateInterestRates(
        asset,
        pool_data[0] + amount,
        pool_data[1],
        pool_data[2],
        pool_data[6],
        reserve_factor
    )[0] / 1e9

    # expected apr must at least as in aave
    assert int(expected_apr / 10) >= int(aave_supply_rate / 10)

    provide_strategy_with_debt(gov, strategy, vault, amount)
    current_apr = strategy.aprAfterDebtChange(0)

    # strategy calculates lowest apr so we don't check upper bound
    assert current_apr >= expected_apr


def test_apr_after_asset_deposit(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
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
    whale,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    provide_strategy_with_debt(gov, strategy, vault, amount)

    withdraw_amount = int(amount / 2)
    withdraw_expected_apr = strategy.aprAfterDebtChange(withdraw_amount)
    vault.withdraw(withdraw_amount, whale, whale, [strategy], sender=whale)
    withdraw_real_apr = strategy.aprAfterDebtChange(0)

    assert  withdraw_real_apr >= withdraw_real_apr
