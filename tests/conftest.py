import pytest
from ape import Contract, accounts, project
from utils.constants import MAX_INT, WEEK, ROLES

# this should be the address of the ERC-20 used by the strategy/vault
ASSET_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"  # USDC
CASSET_ADDRESS = "0xc3d688B66703497DAA19211EEdff47f25384cdc3"  # cUSDCv3
ASSET_WHALE_ADDRESS = "0x0A59649758aa4d66E25f08Dd01271e891fe52199"  # USDC WHALE


@pytest.fixture(scope="session")
def gov(accounts):
    # TODO: can be changed to actual governance
    return accounts[0]


@pytest.fixture(scope="session")
def strategist(accounts):
    return accounts[1]


@pytest.fixture(scope="session")
def user(accounts):
    return accounts[9]


@pytest.fixture(scope="session")
def asset():
    yield Contract(ASSET_ADDRESS)


@pytest.fixture(scope="session")
def amount(asset):
    # Use 1M
    return 1_000_000 * 10 ** asset.decimals()


@pytest.fixture(scope="session")
def ctoken():
    # NOTE: adding default contract type because it's not verified
    return Contract(CASSET_ADDRESS, project.Comet.contract_type)


@pytest.fixture(scope="session")
def create_vault(project, gov):
    def create_vault(
        asset,
        governance=gov,
        deposit_limit=MAX_INT,
        max_profit_locking_time=WEEK,
    ):
        vault = gov.deploy(
            project.dependencies["yearn-vaults"]["master"].VaultV3,
            asset,
            "VaultV3",
            "AV",
            governance,
            max_profit_locking_time,
        )
        # set up fee manager
        # vault.set_fee_manager(fee_manager.address, sender=gov)

        vault.set_role(
            gov.address,
            ROLES.STRATEGY_MANAGER | ROLES.DEBT_MANAGER | ROLES.ACCOUNTING_MANAGER,
            sender=gov,
        )
        # set vault deposit
        vault.set_deposit_limit(deposit_limit, sender=gov)

        return vault

    yield create_vault


@pytest.fixture(scope="function")
def vault(gov, asset, create_vault):
    vault = create_vault(asset)
    yield vault


@pytest.fixture
def create_strategy(project, strategist):
    def create_strategy(vault):
        strategy = strategist.deploy(
            project.Strategy, vault.address, "strategy_name", CASSET_ADDRESS
        )
        return strategy

    yield create_strategy


@pytest.fixture(scope="function")
def strategy(vault, create_strategy):
    strategy = create_strategy(vault)
    yield strategy


@pytest.fixture(scope="function")
def create_vault_and_strategy(strategy, vault, deposit_into_vault):
    def create_vault_and_strategy(account, amount_into_vault):
        deposit_into_vault(vault, amount_into_vault)
        vault.add_strategy(strategy.address, sender=account)
        return vault, strategy

    yield create_vault_and_strategy


@pytest.fixture(scope="function")
def deposit_into_vault(asset, gov):
    def deposit_into_vault(vault, amount_to_deposit):
        whale = accounts[ASSET_WHALE_ADDRESS]
        asset.approve(vault.address, amount_to_deposit, sender=whale)
        vault.deposit(amount_to_deposit, whale.address, sender=whale)

    yield deposit_into_vault


@pytest.fixture(scope="function")
def provide_strategy_with_debt():
    def provide_strategy_with_debt(account, strategy, vault, target_debt: int):
        vault.update_max_debt_for_strategy(
            strategy.address, target_debt, sender=account
        )
        vault.update_debt(strategy.address, target_debt, sender=account)

    return provide_strategy_with_debt


@pytest.fixture
def user_interaction(strategy, vault, deposit_into_vault):
    def user_interaction():
        return

    yield user_interaction
