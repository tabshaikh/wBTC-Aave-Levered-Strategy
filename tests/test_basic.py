from config import (
    BADGER_DEV_MULTISIG,
    WANT,
    REWARD_TOKEN,
    DEFAULT_GOV_PERFORMANCE_FEE,
    DEFAULT_PERFORMANCE_FEE,
    DEFAULT_WITHDRAWAL_FEE,
)

from brownie import address


def test_deploy_settings(deployed, aave):
    """
    Verifies that you set up the Strategy properly
    """
    strategy = deployed.strategy

    protected_tokens = strategy.getProtectedTokens()

    ## NOTE: Change based on how you set your contract
    assert protected_tokens[0] == WANT
    assert protected_tokens[1] == REWARD_TOKEN
    assert protected_tokens[2] == aave

    assert strategy.governance() == BADGER_DEV_MULTISIG

    assert strategy.performanceFeeGovernance() == DEFAULT_GOV_PERFORMANCE_FEE
    assert strategy.performanceFeeStrategist() == DEFAULT_PERFORMANCE_FEE
    assert strategy.withdrawalFee() == DEFAULT_WITHDRAWAL_FEE
