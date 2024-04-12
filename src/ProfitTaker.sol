// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ProfitTaker is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    event UpdateRecipient(address indexed newRecipient);
    event UpdateThreshold(uint256 newThreshold);
    event Rebalanced(uint256 needed, uint256 transferred);
    event Deposited(
        address indexed vault,
        address indexed depositor,
        uint256 amount
    );
    event Withdrawn(
        address indexed vault,
        address indexed manager,
        uint256 amount
    );

    event WithdrewAll(address indexed manager);

    // vault from where funds will be withdrawn
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

    // 100% in Basis Points
    uint256 public constant MAX_BPS = 10_000;

    function initialize(
        address _vault,
        address _recipient,
        address _manager,
        uint256 _threshold
    ) external {
        require(manager == address(0), "initialized");
        require(_manager != address(0), "ZERO_ADDRESS");
        require(_vault != address(0), "ZERO_ADDRESS");
        require(_recipient != address(0), "ZERO_ADDRESS");
        require(_threshold != 0, "zero threshold");

        manager = _manager;
        vault = IERC4626(_vault);
        recipient = _recipient;
        token = IERC20(vault.asset());
        threshold = _threshold;
        IERC20(token).safeApprove(address(vault), type(uint256).max);
    }

    function deposit(uint256 _amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        vault.deposit(_amount, address(this));

        emit Deposited(address(vault), msg.sender, _amount);
    }

    // Withdraws tokens from the contract to the manager
    function withdraw(uint256 _amount) external onlyManager nonReentrant {
        require(_amount > 0, "!_amount");

        uint256 _vaultBalance = vault.balanceOf(address(this));
        require(_vaultBalance > 0, "!_vaultAmount");

        vault.withdraw(_amount, manager, address(this));

        emit Withdrawn(address(vault), manager, _amount);
    }

    function withdrawAll() external onlyManager nonReentrant {
        // Redeem everything from the vault
        if (balanceOfUnderlying() > 0) {
            vault.redeem(
                vault.balanceOf(address(this)),
                address(this),
                address(this)
            );
        }

        // dust + prev redeem would be transfered out here
        uint256 _looseTokens = token.balanceOf(address(this));
        if (_looseTokens > 0) {
            IERC20(token).safeTransfer(manager, _looseTokens);
        }

        emit WithdrewAll(manager);
    }

    function rebalance() external nonReentrant {
        // only rebalance if threshold condition is met
        require(rebalanceTrigger(), "!trigger");
        uint256 _recipientTokenBalance = token.balanceOf(recipient);

        // Diff is ok to do since the trigger verifies it
        uint256 _desiredAmount = threshold - _recipientTokenBalance;

        uint256 _maxWithdraw = vault.maxWithdraw(address(this));
        uint256 _amountToWithdraw = Math.min(_desiredAmount, _maxWithdraw);
        vault.withdraw(_amountToWithdraw, recipient, address(this));

        emit Rebalanced(_desiredAmount, _amountToWithdraw);
    }

    function rebalanceTrigger() public view returns (bool) {
        return
            vault.balanceOf(address(this)) > 0 &&
            vault.maxWithdraw(address(this)) > 0 &&
            token.balanceOf(recipient) < threshold;
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

    function balanceOfUnderlying() public view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
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
