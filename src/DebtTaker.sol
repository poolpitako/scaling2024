// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
//import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {Maths} from "@ajna-core/libraries/internal/Maths.sol";
import {PoolCommons} from "@ajna-core/libraries/external/PoolCommons.sol";
import {COLLATERALIZATION_FACTOR} from "@ajna-core/libraries/helpers/PoolHelper.sol";

contract DebtTaker is ReentrancyGuard {
    event UpdateRecipient(address indexed newRecipient);
    event UpdateMaxBorrowingRate(uint256 newMaxBorrowingRate);
    event UpdateThreshold(uint256 newThreshold);
    event Rebalanced(uint256 needed, uint256 transferred);
    event DebtRepaid(uint256 amount);
    event Deposited(
        address indexed ajnaPool,
        address indexed depositor,
        uint256 amount
    );
    event Withdrawn(address indexed manager, uint256 amount);
    event WithdrewAll(address indexed manager);

    using SafeERC20 for IERC20;
    using Math for uint256;

    // vault used as collateral
    IERC4626 public vault;

    // recipient of withdrawn funds.
    // for gnosis pay should be the safe address
    address public recipient;

    // desired token/token to check balance on the recipient address
    IERC20 public token;

    // when balance of token in recipient address is below this threshold,
    // funds will be withdrawn from the vault
    uint256 public threshold;

    // address that will be allowed to change threshold and vault
    address public manager;

    // Address of the ajnaPool used to borrow token
    IERC20Pool public ajnaPool;

    // Max borrowing rate used to rebalance
    uint256 public maxBorrowingRate;

    function initialize(
        address _vault,
        address _recipient,
        address _manager,
        uint256 _threshold,
        address _ajnaPool,
        uint256 _maxBorrowingRate
    ) external {
        require(manager == address(0), "initialized");
        require(_manager != address(0), "ZERO_ADDRESS");
        require(_vault != address(0), "ZERO_ADDRESS");
        require(_recipient != address(0), "ZERO_ADDRESS");
        require(_threshold != 0, "zero threshold");
        require(_ajnaPool != address(0), "ZERO_ADDRESS");
        require(_maxBorrowingRate != 0, "zero borrowing rate");

        manager = _manager;
        vault = IERC4626(_vault);
        recipient = _recipient;
        token = IERC20(vault.asset());
        threshold = _threshold;

        // Approval for vault deposits
        IERC20(token).safeApprove(address(vault), type(uint256).max);

        ajnaPool = IERC20Pool(_ajnaPool);
        require(ajnaPool.collateralAddress() == _vault, "!ajna");
        require(ajnaPool.quoteTokenAddress() == address(token), "!ajna");
        maxBorrowingRate = _maxBorrowingRate;

        // Approval to deposit collateral
        IERC20(_vault).safeApprove(_ajnaPool, type(uint256).max);
        // Approval to repay debt
        IERC20(token).safeApprove(_ajnaPool, type(uint256).max);
    }

    function deposit(uint256 _amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _shares = IERC4626(vault).deposit(_amount, address(this));
        ajnaPool.drawDebt(address(this), 0, 0, _shares);

        emit Deposited(address(ajnaPool), msg.sender, _amount);
    }

    // Withdraws tokens from the contract to the manager
    // if there is debt, it might cause a liquidation
    function withdraw(uint256 _amount) external onlyManager nonReentrant {
        uint256 _shares = vault.convertToShares(_amount);
        ajnaPool.repayDebt(address(this), 0, _shares, address(this), 0);

        vault.withdraw(_amount, manager, address(this));
        emit Withdrawn(manager, _amount);
    }

    function withdrawAll() external onlyManager nonReentrant {
        // If there is collateral in ajna, try to withdraw
        (, uint256 _collateral, , ) = _positionInfo();
        if (_collateral > 0) {
            ajnaPool.repayDebt(address(this), 0, _collateral, address(this), 0);
        }

        // Withdraw underlying from vault
        uint256 _toRedeem = IERC20(vault).balanceOf(address(this));
        vault.redeem(_toRedeem, address(this), address(this));

        // dust + prev redeem would be transfered out here
        uint256 _looseTokens = token.balanceOf(address(this));
        if (_looseTokens > 0) {
            IERC20(token).safeTransfer(manager, _looseTokens);
        }

        emit WithdrewAll(manager);
    }

    function repayDebt(uint256 _amountToRepay) external nonReentrant {
        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            _amountToRepay
        );

        // TODO: check if 0 as limit works, if not, summer uses _lupIndex
        ajnaPool.repayDebt(address(this), _amountToRepay, 0, address(this), 0);

        emit DebtRepaid(_amountToRepay);
    }

    function rebalance() external nonReentrant {
        // only rebalance if threshold condition is met
        require(rebalanceTrigger(), "!trigger");
        uint256 _recipientTokenBalance = token.balanceOf(recipient);

        // Diff is ok to do since the trigger verifies it
        uint256 _desiredAmount = threshold - _recipientTokenBalance;
        uint256 _maxBorrowable = _availableTokenToBorrow();
        uint256 _amountToBorrow = Math.min(_desiredAmount, _maxBorrowable);

        ajnaPool.drawDebt(address(this), _amountToBorrow, _lupIndex(), 0);
        uint256 _amountToTransfer = token.balanceOf(address(this));
        token.safeTransfer(recipient, _amountToTransfer);

        emit Rebalanced(_desiredAmount, _amountToTransfer);
    }

    function _lupIndex() internal view returns (uint256) {
        (uint256 _debt, , , ) = ajnaPool.debtInfo();

        // If there is no debt, default to price = 1
        if (_debt == 0) {
            return 4156;
        }

        return ajnaPool.depositIndex(_debt);
    }

    function balanceOfUnderlying() public view returns (uint256) {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        uint256 _collateralValue = vault.convertToAssets(_collateral);

        if (_collateralValue > _debt) {
            return _collateralValue - _debt;
        }

        return 0;
    }

    /**************************************************
     *      MANUAL EXIT METHODS JUST IN CASE          *
     **************************************************/

    function ajnaRepayDebt(
        uint256 _amountToRepay,
        uint256 _collateralAmountToPull,
        uint256 _limitIndex
    ) external onlyManager {
        ajnaPool.repayDebt(
            address(this),
            _amountToRepay,
            _collateralAmountToPull,
            manager,
            _limitIndex
        );
    }

    function ajnaRemoveCollateral(
        uint256 _amount,
        uint256 _index
    ) external onlyManager {
        ajnaPool.removeCollateral(_amount, _index);
    }

    function ajnaRemoveQuoteToken(
        uint256 _amount,
        uint256 _index
    ) external onlyManager {
        ajnaPool.removeQuoteToken(_amount, _index);
    }

    function availableTokenToBorrow() external view returns (uint256 _amount) {
        return _availableTokenToBorrow();
    }

    /**
     *  @notice Returns the amount of quote token available for borrowing or removing from pool.
     *  @dev    Calculated as the difference between pool balance and escrowed amounts locked in
     *  pool (auction bonds + unclaimed reserves).
     *  @return _amount   The total quote token amount available to borrow or to be removed from pool, in `WAD` units.
     */
    function _availableTokenToBorrow() internal view returns (uint256 _amount) {
        (uint256 bondEscrowed, uint256 unclaimedReserve, , , ) = ajnaPool
            .reservesInfo();
        uint256 escrowedAmounts = bondEscrowed + unclaimedReserve;

        uint256 poolBalance = token.balanceOf(address(ajnaPool)) *
            ajnaPool.quoteTokenScale();

        if (poolBalance > escrowedAmounts) {
            _amount = poolBalance - escrowedAmounts;
        }
    }

    function positionInfo()
        external
        view
        returns (
            uint256 _debt,
            uint256 _collateral,
            uint256 _t0Np,
            uint256 _thresholdPrice
        )
    {
        return _positionInfo();
    }

    /**
     *  @notice Retrieves info related to our debt position
     *  @return _debt             Current debt owed (`WAD`).
     *  @return _collateral       Pledged collateral, including encumbered (`WAD`).
     *  @return _t0Np             `Neutral price` (`WAD`).
     *  @return _thresholdPrice   Borrower's `Threshold Price` (`WAD`).
     */
    function _positionInfo()
        internal
        view
        returns (
            uint256 _debt,
            uint256 _collateral,
            uint256 _t0Np,
            uint256 _thresholdPrice
        )
    {
        (uint256 inflator, uint256 lastInflatorUpdate) = ajnaPool
            .inflatorInfo();

        (uint256 interestRate, ) = ajnaPool.interestRateInfo();

        uint256 pendingInflator = PoolCommons.pendingInflator(
            inflator,
            lastInflatorUpdate,
            interestRate
        );

        uint256 t0Debt;
        uint256 npTpRatio;
        (t0Debt, _collateral, npTpRatio) = ajnaPool.borrowerInfo(address(this));

        _t0Np = _collateral == 0
            ? 0
            : Math.mulDiv(
                Maths.wmul(t0Debt, COLLATERALIZATION_FACTOR),
                npTpRatio,
                _collateral
            );
        _debt = Maths.ceilWmul(t0Debt, pendingInflator);
        _thresholdPrice = _collateral == 0
            ? 0
            : Maths.wmul(
                Maths.wdiv(_debt, _collateral),
                COLLATERALIZATION_FACTOR
            );
    }

    function rebalanceTrigger() public view returns (bool) {
        // Rebalance not needed
        if (token.balanceOf(recipient) >= threshold) {
            return false;
        }

        // If no collateral, it would be impossible to borrow
        (, uint256 _collateral, , ) = _positionInfo();
        if (_collateral == 0) {
            return false;
        }

        // There needs to be quote token to borrow in the pool
        if (_availableTokenToBorrow() == 0) return false;

        // Check that the interest rate is below the maxBorrowing rate
        (uint256 interestRate, ) = ajnaPool.interestRateInfo();
        if (interestRate >= maxBorrowingRate) {
            return false;
        }

        return true;
    }

    // update threshold
    function setMaxBorrowingRate(
        uint256 _maxBorrowingRate
    ) external onlyManager {
        require(maxBorrowingRate != 0, "zero borrowing rate");

        maxBorrowingRate = _maxBorrowingRate;

        emit UpdateMaxBorrowingRate(_maxBorrowingRate);
    }

    // update threshold
    function setThreshold(uint256 _threshold) external onlyManager {
        require(_threshold != 0, "zero threshold");

        threshold = _threshold;

        emit UpdateThreshold(_threshold);
    }

    // update recipient
    function setRecipient(address _recipient) external onlyManager {
        require(_recipient != address(0), "ZERO_ADDRESS");

        recipient = _recipient;

        emit UpdateRecipient(_recipient);
    }

    // sweep functions in case of airdrops or sending an undesired token
    function sweep(
        address[] calldata _tokens,
        uint256[] calldata _amounts
    ) external onlyManager {
        uint256 _size = _tokens.length;
        require(_size == _amounts.length);

        for (uint256 i = 0; i < _size; i++) {
            if (_tokens[i] == address(0)) {
                _safeTransferETH(manager, _amounts[i]);
            } else {
                _safeTransfer(_tokens[i], manager, _amounts[i]);
            }
        }
    }

    /// @dev Wrapper around a call to the ERC20 function `transfer` that reverts
    /// also when the token returns `false`.
    function _safeTransfer(
        address _token,
        address _to,
        uint256 _value
    ) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(
                freeMemoryPointer,
                0xa9059cbb00000000000000000000000000000000000000000000000000000000
            )
            mstore(
                add(freeMemoryPointer, 4),
                and(_to, 0xffffffffffffffffffffffffffffffffffffffff)
            )
            mstore(add(freeMemoryPointer, 36), _value)

            if iszero(call(gas(), _token, 0, freeMemoryPointer, 68, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        require(getLastTransferResult(_token), "!transfer");
    }

    /// @dev Verifies that the last return was a successful `transfer*` call.
    /// This is done by checking that the return data is either empty, or
    /// is a valid ABI encoded boolean.
    function getLastTransferResult(
        address _token
    ) private view returns (bool success) {
        // NOTE: Inspecting previous return data requires assembly. Note that
        // we write the return data to memory 0 in the case where the return
        // data size is 32, this is OK since the first 64 bytes of memory are
        // reserved by Solidy as a scratch space that can be used within
        // assembly blocks.
        // <https://docs.soliditylang.org/en/v0.7.6/internals/layout_in_memory.html>
        // solhint-disable-next-line no-inline-assembly
        assembly {
            /// @dev Revert with an ABI encoded Solidity error with a message
            /// that fits into 32-bytes.
            ///
            /// An ABI encoded Solidity error has the following memory layout:
            ///
            /// ------------+----------------------------------
            ///  byte range | value
            /// ------------+----------------------------------
            ///  0x00..0x04 |        selector("Error(string)")
            ///  0x04..0x24 |      string offset (always 0x20)
            ///  0x24..0x44 |                    string length
            ///  0x44..0x64 | string value, padded to 32-bytes
            function revertWithMessage(length, message) {
                mstore(0x00, "\x08\xc3\x79\xa0")
                mstore(0x04, 0x20)
                mstore(0x24, length)
                mstore(0x44, message)
                revert(0x00, 0x64)
            }

            switch returndatasize()
            // Non-standard ERC20 transfer without return.
            case 0 {
                // NOTE: When the return data size is 0, verify that there
                // is code at the address. This is done in order to maintain
                // compatibility with Solidity calling conventions.
                // <https://docs.soliditylang.org/en/v0.7.6/control-structures.html#external-function-calls>
                if iszero(extcodesize(_token)) {
                    revertWithMessage(20, "!contract")
                }

                success := 1
            }
            // Standard ERC20 transfer returning boolean success value.
            case 32 {
                returndatacopy(0, 0, returndatasize())

                // NOTE: For ABI encoding v1, any non-zero value is accepted
                // as `true` for a boolean. In order to stay compatible with
                // OpenZeppelin's `SafeERC20` library which is known to work
                // with the existing ERC20 implementation we care about,
                // make sure we return success for any non-zero return value
                // from the `transfer*` call.
                success := iszero(iszero(mload(0)))
            }
            default {
                revertWithMessage(31, "malformed") // malformed transfer result
            }
        }
    }

    function _safeTransferETH(address _to, uint256 _amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), _to, _amount, 0, 0, 0, 0)
        }

        require(success, "!stETH");
    }

    // `fallback` is called when msg.data is not empty
    fallback() external payable {}

    // `receive` is called when msg.data is empty
    receive() external payable {}

    modifier onlyManager() {
        require(msg.sender == manager, "!manager");
        _; // Continue executing the function code here
    }
}
