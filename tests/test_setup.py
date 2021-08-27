from brownie import *

"""
Given the Vault for wBTC
Does it automatically set up with the tokens we expect?
"""


def test_setup_address(deployed, borrowed, tokens):

    strategy = deployed.strategy

    assert strategy.vToken() == borrowed
    assert strategy.DECIMALS() == Contract(tokens[0]).decimals()

    address_provider = Contract.from_explorer(strategy.ADDRESS_PROVIDER())

    assert strategy.LENDING_POOL() == address_provider.getLendingPool()
