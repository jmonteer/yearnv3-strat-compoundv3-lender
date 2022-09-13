from ape import reverts
import pytest
from utils.constants import REL_ERROR


def test_strategy_constructor(asset, vault, strategy):
    assert strategy.name() == "strategy_name"
    assert strategy.symbol() == "strategy_symbol"
    assert strategy.asset() == asset.address
    assert strategy.vault() == vault.address


def test_withdrawable_only_with_assets(
    gov, asset, create_vault_and_strategy, provide_strategy_with_debt, amount
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.maxWithdraw(vault) == 0

    # let's provide strategy with assets
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert strategy.maxWithdraw(vault) == new_debt
    assert asset.balanceOf(vault) == amount - new_debt
    assert asset.balanceOf(strategy) == new_debt


def test_total_assets(
    gov, asset, create_vault_and_strategy, provide_strategy_with_debt, amount
):
    vault, strategy = create_vault_and_strategy(gov, amount)

    assert strategy.totalAssets() == 0

    # let's provide strategy with assets
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert strategy.totalAssets() == new_debt
    assert asset.balanceOf(vault) == amount - new_debt
    assert asset.balanceOf(strategy) == new_debt

    # let´s invest them
    strategy.invest(sender=gov)

    # total assets should remain as it takes into consideration invested assets
    assert pytest.approx(strategy.totalAssets(), rel=REL_ERROR) == new_debt


def test_invest(
    asset,
    atoken,
    create_vault_and_strategy,
    gov,
    deposit_into_vault,
    provide_strategy_with_debt,
    amount,
):
    vault, strategy = create_vault_and_strategy(gov, amount)

    with reverts("no funds to invest"):
        strategy.invest(sender=gov)

    # let's provide strategy with assets
    deposit_into_vault(vault, amount)
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    total_assets = strategy.totalAssets()
    assert asset.balanceOf(strategy) == total_assets
    assert atoken.balanceOf(strategy) == 0

    strategy.invest(sender=gov)

    assert asset.balanceOf(strategy) == 0
    assert atoken.balanceOf(strategy) == total_assets


def test_free_funds_idle_asset(
    asset, atoken, create_vault_and_strategy, gov, provide_strategy_with_debt, amount
):
    vault, strategy = create_vault_and_strategy(gov, amount)

    # let's provide strategy with assets
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert asset.balanceOf(strategy) == new_debt
    assert strategy.totalAssets() == new_debt
    assert atoken.balanceOf(strategy) == 0
    vault_balance = asset.balanceOf(vault)

    strategy.freeFunds(9 ** 6, sender=vault)

    assert asset.balanceOf(strategy) == new_debt
    assert strategy.totalAssets() == new_debt
    assert asset.balanceOf(vault) == vault_balance


def test_withdrawable_with_assets_and_atokens(
    asset, create_vault_and_strategy, gov, provide_strategy_with_debt, atoken, amount
):
    vault_balance = amount
    vault, strategy = create_vault_and_strategy(gov, vault_balance)

    assert strategy.maxWithdraw(vault) == 0

    # let´s provide strategy with assets
    new_debt = vault_balance // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    # let´s invest them
    strategy.invest(sender=gov)

    assert pytest.approx(strategy.maxWithdraw(vault), rel=REL_ERROR) == new_debt
    assert asset.balanceOf(vault) == vault_balance - new_debt
    assert asset.balanceOf(strategy) == 0
    assert atoken.balanceOf(strategy) == new_debt

    # Update with more debt without investing
    new_new_debt = new_debt + vault_balance // 4
    provide_strategy_with_debt(gov, strategy, vault, new_new_debt)

    # strategy has already made some small profit
    assert (
        pytest.approx(strategy.maxWithdraw(vault), rel=REL_ERROR)
        == vault_balance // 2 + vault_balance // 4
    )
    assert asset.balanceOf(vault) == vault_balance - new_new_debt
    assert asset.balanceOf(strategy) == new_new_debt - new_debt
    assert atoken.balanceOf(strategy) >= new_debt


def test_free_funds_atokens(
    asset,
    atoken,
    create_vault_and_strategy,
    gov,
    provide_strategy_with_debt,
    user_interaction,
    amount,
):
    vault, strategy = create_vault_and_strategy(gov, amount)

    # let's provide strategy with assets
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert asset.balanceOf(strategy) == new_debt
    assert atoken.balanceOf(strategy) == 0
    assert strategy.totalAssets() == new_debt

    strategy.invest(sender=gov)

    assert asset.balanceOf(strategy) == 0
    assert pytest.approx(atoken.balanceOf(strategy), rel=REL_ERROR) == new_debt
    assert pytest.approx(strategy.totalAssets(), rel=REL_ERROR) == new_debt
    vault_balance = asset.balanceOf(vault)

    # Let´s force Aave pool to update
    user_interaction()

    funds_to_free = 9 * 10 ** 11
    strategy.freeFunds(funds_to_free, sender=vault)

    assert asset.balanceOf(strategy) == funds_to_free
    # There should be some more atokens than expected due to profit
    assert atoken.balanceOf(strategy) > new_debt - funds_to_free
    assert strategy.totalAssets() >= new_debt
    assert asset.balanceOf(vault) == vault_balance
