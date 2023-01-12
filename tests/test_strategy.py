from ape import reverts, chain, Contract, accounts
import pytest
from utils.constants import REL_ERROR, MAX_INT, YEAR


def test_strategy_constructor(asset, vault, strategy):
    assert strategy.name() == "strategy_name"
    assert strategy.asset() == asset.address
    assert strategy.vault() == vault.address


def test_max_deposit(strategy, vault):
    assert strategy.maxDeposit(vault) == MAX_INT


@pytest.mark.parametrize("shares_amount", [10**6, 10**8, 10**12, 10**18])
def test_convert_to_assets(strategy, shares_amount):
    assert shares_amount == strategy.convertToAssets(shares_amount)


# @pytest.mark.parametrize("shares_amount", [10**6, 10**8, 10**12, 10**18])
# def test_convert_to_assets_with_supply(
#     asset,
#     create_vault_and_strategy,
#     gov,
#     amount,
#     shares_amount,
#     provide_strategy_with_debt,
# ):
#     vault, strategy = create_vault_and_strategy(gov, amount)
#     assert strategy.totalAssets() == 0
#
#     # let's provide strategy with assets
#     new_debt = amount // 2
#     provide_strategy_with_debt(gov, strategy, vault, new_debt)
#
#     assert strategy.convertToAssets(shares_amount) == shares_amount
#
#     # let´s change pps by transferring (not deposit) assets to strategy
#     asset.transfer(strategy, new_debt, sender=vault)
#
#     assert asset.balanceOf(strategy) == new_debt
#     assert strategy.convertToAssets(shares_amount) == pytest.approx(
#         2 * shares_amount, rel=REL_ERROR
#     )


@pytest.mark.parametrize("assets_amount", [10**6, 10**8, 10**12, 10**18])
def test_convert_to_shares(strategy, assets_amount):
    assert assets_amount == strategy.convertToShares(assets_amount)


# @pytest.mark.parametrize("assets_amount", [10**6, 10**8, 10**12, 10**18])
# def test_convert_to_shares_with_supply(
#     asset,
#     create_vault_and_strategy,
#     gov,
#     amount,
#     assets_amount,
#     provide_strategy_with_debt,
# ):
#     vault, strategy = create_vault_and_strategy(gov, amount)
#     assert strategy.totalAssets() == 0
#
#     # let's provide strategy with assets
#     new_debt = amount // 2
#     provide_strategy_with_debt(gov, strategy, vault, new_debt)
#
#     # pps == 1.0
#     assert strategy.convertToShares(assets_amount) == assets_amount
#
#     # let´s change pps by transferring (not deposit) assets to strategy
#     asset.transfer(strategy, new_debt, sender=vault)
#
#     assert asset.balanceOf(strategy) == new_debt
#     assert strategy.convertToShares(assets_amount) == pytest.approx(
#         assets_amount / 2, rel=REL_ERROR
#     )


def test_total_assets(
    create_vault_and_strategy, provide_strategy_with_debt, gov, asset, amount
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.totalAssets() == 0

    # let's provide strategy with assets
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert pytest.approx(new_debt, REL_ERROR) == strategy.totalAssets()
    assert asset.balanceOf(vault) == amount - new_debt
    assert asset.balanceOf(strategy) == 0
    assert pytest.approx(new_debt, REL_ERROR) == strategy.underlyingBalance()[2]


def test_balance_of(create_vault_and_strategy, gov, amount, provide_strategy_with_debt):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.totalAssets() == 0

    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert pytest.approx(strategy.balanceOf(vault), 1e-4) == new_debt

    new_new_debt = amount // 4
    provide_strategy_with_debt(gov, strategy, vault, new_debt + new_new_debt)

    assert pytest.approx(new_debt + new_new_debt, 1e-4) == strategy.balanceOf(vault)


def test_deposit_no_vault__reverts(create_vault_and_strategy, gov, amount, user):
    vault, strategy = create_vault_and_strategy(gov, amount)
    with reverts("not vault"):
        strategy.deposit(100, user, sender=user)

    # will revert due to lack of allowance
    with reverts():
        strategy.deposit(100, user, sender=vault)


def test_deposit(
    asset, create_vault_and_strategy, gov, amount, provide_strategy_with_debt
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.totalAssets() == 0

    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert pytest.approx(strategy.balanceOf(vault), 1e-5) == new_debt

    assert asset.balanceOf(vault) == amount // 2
    # get's reinvested directly
    assert asset.balanceOf(strategy) == 0
    assert pytest.approx(new_debt, REL_ERROR) == strategy.underlyingBalance()[2]


def test_max_withdraw(
    asset, create_vault_and_strategy, gov, amount, provide_strategy_with_debt
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.maxWithdraw(vault) == 0

    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert pytest.approx(new_debt, REL_ERROR) == strategy.maxWithdraw(vault)


def test_max_withdraw_no_liquidity(
    asset,
    atoken,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    assert strategy.maxWithdraw(vault) == 0

    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert pytest.approx(new_debt, REL_ERROR) == strategy.maxWithdraw(vault)

    # let's drain atoken contract
    asset.transfer(
        user, asset.balanceOf(atoken) - 10 ** vault.decimals(), sender=atoken
    )

    assert strategy.maxWithdraw(vault) == strategy.totalAssets()


def test_withdraw_no_owner__reverts(create_vault_and_strategy, gov, amount, user):
    vault, strategy = create_vault_and_strategy(gov, amount)
    with reverts("not vault"):
        strategy.withdraw(100, user, user, sender=user)


def test_withdraw_above_max__reverts(create_vault_and_strategy, gov, amount, user):
    vault, strategy = create_vault_and_strategy(gov, amount)
    with reverts("withdraw more than max"):
        strategy.withdraw(100, vault, vault, sender=vault)


def test_withdraw_more_than_max(
    asset, create_vault_and_strategy, gov, amount, provide_strategy_with_debt
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    with reverts("withdraw more than max"):
        strategy.withdraw(
            strategy.maxWithdraw(vault) + 10 ** vault.decimals(),
            vault,
            vault,
            sender=vault,
        )


def test_withdraw(
    asset, create_vault_and_strategy, gov, amount, provide_strategy_with_debt
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    new_debt = amount // 2
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert asset.balanceOf(strategy) == 0
    assert asset.balanceOf(vault) == amount // 2
    assert pytest.approx(new_debt, REL_ERROR) == strategy.underlyingBalance()[2]

    strategy.withdraw(strategy.maxWithdraw(vault), vault, vault, sender=vault)

    assert pytest.approx(0, abs=1e4) == strategy.balanceOf(vault)
    assert asset.balanceOf(strategy) == 0
    assert pytest.approx(amount, REL_ERROR) == asset.balanceOf(vault)
    assert pytest.approx(0, abs=1e4) == strategy.underlyingBalance()[2]


def test_withdraw_low_liquidity(
    asset,
    user,
    create_vault_and_strategy,
    gov,
    amount,
    provide_strategy_with_debt,
    atoken,
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    assert asset.balanceOf(strategy) == 0
    assert asset.balanceOf(vault) == 0
    assert pytest.approx(new_debt, REL_ERROR) == strategy.underlyingBalance()[2]

    # let's drain atoken contract
    asset.transfer(
        user, asset.balanceOf(atoken) - 10 ** vault.decimals(), sender=atoken
    )

    strategy.withdraw(strategy.maxWithdraw(vault), vault, vault, sender=vault)

    assert strategy.underlyingBalance()[2] == strategy.balanceOf(vault)
    assert asset.balanceOf(strategy) == 0
    assert pytest.approx(10 ** vault.decimals(), REL_ERROR) == asset.balanceOf(vault)
    assert (
        pytest.approx(new_debt - 10 ** vault.decimals(), rel=1e-5)
        == strategy.underlyingBalance()[2]
    )


def test_withdraw_mev_bot(
    asset, user, create_vault_and_strategy, gov, amount, provide_strategy_with_debt
):
    vault, strategy = create_vault_and_strategy(gov, amount)
    new_debt = amount
    provide_strategy_with_debt(gov, strategy, vault, new_debt)

    with reverts("not vault"):
        strategy.withdraw(strategy.maxWithdraw(vault), user, user, sender=user)
