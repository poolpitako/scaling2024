# @version 0.3.7

interface IProfitTaker:
    def initialize(
        vault: address,
        recipient: address,
        manager: address,
        threshold: uint256,
    ): nonpayable

event NewProfitTaker:
    profit_taker: indexed(address)
    recipient: indexed(address)
    manager: indexed(address)
    vault: address
    treshold: uint256

# The address that all newly deployed profit takers are based from.
ORIGINAL: public(immutable(address))

@external
def __init__(original: address):
    ORIGINAL = original

@external
def newProfitTaker(
    vault: address,
    recipient: address,
    manager: address,
    threshold: uint256
) -> address:

    # Clone a new version of the profit taker
    new_profit_taker: address = create_minimal_proxy_to(
            ORIGINAL, 
            value=0
        )

    IProfitTaker(new_profit_taker).initialize(vault, recipient, manager, threshold)
        
    log NewProfitTaker(new_profit_taker, recipient, manager, vault, threshold)
    return new_profit_taker