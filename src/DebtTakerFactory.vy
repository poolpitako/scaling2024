# @version 0.3.7

interface IDebtTaker:
    def initialize(
        vault: address,
        recipient: address,
        manager: address,
        threshold: uint256,
        ajnaPool: address,
        maxBorrowingRate: uint256
    ): nonpayable

event NewDebtTaker:
    debt_taker: indexed(address)
    recipient: indexed(address)
    manager: indexed(address)
    vault: address
    treshold: uint256
    ajnaPool: address
    maxBorrowingRate: uint256

# The address that all newly deployed profit takers are based from.
ORIGINAL: public(immutable(address))

@external
def __init__(original: address):
    ORIGINAL = original

@external
def newDebtTaker(
    vault: address,
    recipient: address,
    manager: address,
    threshold: uint256,
    ajnaPool: address,
    maxBorrowingRate: uint256
) -> address:

    # Clone a new version of the profit taker
    new_debt_taker: address = create_minimal_proxy_to(
            ORIGINAL,
            value=0
        )

    IDebtTaker(new_debt_taker).initialize(vault, recipient, manager, threshold, ajnaPool, maxBorrowingRate)

    log NewDebtTaker(new_debt_taker, recipient, manager, vault, threshold, ajnaPool, maxBorrowingRate)
    return new_debt_taker
