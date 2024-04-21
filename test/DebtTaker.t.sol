// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;
import "forge-std/console.sol";

import "forge-std/Test.sol";
import "../src/DebtTaker.sol";
import "../utils/vyperDeployer.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";

interface IDebtTakerFactory {
    function newDebtTaker(
        address vault,
        address recipient,
        address manager,
        uint256 threshold,
        address ajnaPool,
        uint256 maxBorrowingRate
    ) external returns (DebtTaker);
}

contract DebtTakerTest is Test {
    VyperDeployer deployer = new VyperDeployer();
    DebtTaker public originalDebtTaker;
    DebtTaker public debtTaker;
    IDebtTakerFactory public debtTakerFactory;
    IERC4626 public vault =
        IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA); //sDAI
    address public dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IERC20Pool public ajnaPool =
        IERC20Pool(0x7491D5e4CfF624eaA047eaB115ad2Ca7541D3ed5); // sDAI/DAI pool in ajna
    address public recipient = vm.addr(2);
    address public manager = vm.addr(3);
    address public lender = vm.addr(4);
    address public borrower = vm.addr(5);
    address public angel = vm.addr(6);
    uint256 public threshold = 100 ether;
    uint256 public maxBorrowingRate = 0.1 ether; // 10%

    function setUp() public {
        originalDebtTaker = new DebtTaker();
        debtTakerFactory = IDebtTakerFactory(
            deployer.deployContract(
                "DebtTakerFactory",
                abi.encode(originalDebtTaker)
            )
        );
        debtTaker = debtTakerFactory.newDebtTaker(
            address(vault),
            recipient,
            manager,
            threshold,
            address(ajnaPool),
            maxBorrowingRate
        );

        // Deposit 100k in the pool to borrow
        deal(dai, lender, 100_000 ether);
        vm.startPrank(lender);
        IERC20(dai).approve(address(ajnaPool), type(uint256).max);
        ajnaPool.addQuoteToken(100_000 ether, 4156, block.timestamp);
        vm.stopPrank();
    }

    function testChangeRecipient() public {
        vm.prank(manager);
        debtTaker.setRecipient(manager);
        assertEq(debtTaker.recipient(), address(manager));
    }

    function testSetMaxBorrowingRate() public {
        assertEq(debtTaker.maxBorrowingRate(), 0.1 ether);
        vm.prank(manager);
        debtTaker.setMaxBorrowingRate(1 ether);
        assertEq(debtTaker.maxBorrowingRate(), 1 ether);
    }

    function testSetThreshold() public {
        assertEq(debtTaker.threshold(), 100 ether);
        vm.prank(manager);
        debtTaker.setThreshold(200 ether);
        assertEq(debtTaker.threshold(), 200 ether);
    }

    function testDepositAsset() public {
        deal(dai, manager, 1_000 ether);
        vm.startPrank(manager);
        IERC20(dai).approve(address(debtTaker), type(uint256).max);
        assertEq(IERC20(dai).balanceOf(address(debtTaker)), 0);
        debtTaker.deposit(1_000 ether);
        assertEq(IERC20(dai).balanceOf(address(debtTaker)), 0);
        assertEq(IERC20(vault).balanceOf(address(debtTaker)), 0);

        (uint256 _debt, uint256 _collat, , ) = debtTaker.positionInfo();
        assertEq(_debt, 0);
        assertGe(vault.convertToAssets(_collat) + 10, 1_000 ether);
        vm.stopPrank();

        // current balance of desired token is 0 in the recipient contract
        assertEq(IERC20(debtTaker.token()).balanceOf(address(recipient)), 0);

        // Not really needed
        skip(1 days);
        vm.roll(block.number + 1);

        // this function could be called by anyone
        debtTaker.rebalance();

        assertEq(
            IERC20(debtTaker.token()).balanceOf(address(recipient)),
            100 ether
        );
        (_debt, _collat, , ) = debtTaker.positionInfo();
        assertGe(_debt, 100 ether);
    }

    function testDepositRebalanceAndWithdraw() public {
        testDepositAsset();

        // An angel pays for the debt :)
        deal(dai, angel, 100_000 ether);
        (uint256 _debt, , , ) = debtTaker.positionInfo();
        vm.startPrank(angel);
        IERC20(dai).approve(address(debtTaker), type(uint256).max);
        debtTaker.repayDebt(_debt);
        vm.stopPrank();

        // There shouldn't be more debt
        (_debt, , , ) = debtTaker.positionInfo();
        assertEq(_debt, 0);

        // Check that the manager can withdraw all
        assertEq(IERC20(dai).balanceOf(manager), 0);
        vm.startPrank(manager);
        debtTaker.withdrawAll();
        assertGe(IERC20(dai).balanceOf(manager) + 10, 1_000 ether);
        vm.stopPrank();
    }

    function _borrowerBorrows() internal {
        // Someone else borrows
        deal(address(vault), borrower, 1_000 ether);
        vm.startPrank(address(borrower));
        IERC20(vault).approve(address(ajnaPool), type(uint256).max);
        ajnaPool.drawDebt(
            address(borrower),
            100 ether,
            debtTaker.lupIndex(),
            1_000 ether
        );
        vm.stopPrank();
        assertGe(IERC20(dai).balanceOf(borrower), 100 ether);
    }

    function testDepositRebalanceThenBorrowerBorrowsAndUserWithdraw() public {
        // User deposits and borrows
        testDepositAsset();

        // Borrower borrows
        _borrowerBorrows();

        // An angel pays for the debt :)
        deal(dai, angel, 100_000 ether);
        (uint256 _debt, , , ) = debtTaker.positionInfo();
        vm.startPrank(angel);
        IERC20(dai).approve(address(debtTaker), type(uint256).max);
        debtTaker.repayDebt(_debt);
        vm.stopPrank();

        // There shouldn't be more debt
        (_debt, , , ) = debtTaker.positionInfo();
        assertEq(_debt, 0);

        // Check that the manager can withdraw all
        assertEq(IERC20(dai).balanceOf(manager), 0);
        vm.startPrank(manager);
        debtTaker.withdrawAll();
        assertGe(IERC20(dai).balanceOf(manager) + 10, 1_000 ether);
        vm.stopPrank();
    }

    function testBorrowerBorrowsThenUserDepositRebalanceThenAndUserWithdraw()
        public
    {
        // Borrower borrows
        _borrowerBorrows();

        // User deposits and borrows
        testDepositAsset();

        // An angel pays for the debt :)
        deal(dai, angel, 100_000 ether);
        (uint256 _debt, , , ) = debtTaker.positionInfo();
        vm.startPrank(angel);
        IERC20(dai).approve(address(debtTaker), type(uint256).max);
        debtTaker.repayDebt(_debt);
        vm.stopPrank();

        // There shouldn't be more debt
        (_debt, , , ) = debtTaker.positionInfo();
        assertEq(_debt, 0);

        // Check that the manager can withdraw all
        assertEq(IERC20(dai).balanceOf(manager), 0);
        vm.startPrank(manager);
        debtTaker.withdrawAll();
        assertGe(IERC20(dai).balanceOf(manager) + 10, 1_000 ether);
        vm.stopPrank();
    }

    function testBalanceOfUnderlying() public {
        deal(dai, manager, 1_000 ether);
        vm.startPrank(manager);
        IERC20(dai).approve(address(debtTaker), type(uint256).max);
        assertEq(IERC20(dai).balanceOf(address(debtTaker)), 0);
        debtTaker.deposit(1_000 ether);
        vm.stopPrank();

        // Without debt it should be almost the same amount
        assertGe(debtTaker.balanceOfUnderlying() + 10, 1_000 ether);

        debtTaker.rebalance();

        // After a rebalance the amount should be the 1k - debt
        (uint256 _debt, , , ) = debtTaker.positionInfo();
        assertGe(_debt, 0);

        assertGe(debtTaker.balanceOfUnderlying() + 10, 1_000 ether - _debt);
    }

    function testWithdrawAll() public {
        assertEq(IERC20(dai).balanceOf(manager), 0);

        deal(dai, address(debtTaker), 1 ether);
        deal(address(vault), address(debtTaker), 2 ether);

        // Deposit collateral into the ajna pool to test it's withdrawal
        vm.prank(address(debtTaker));
        ajnaPool.drawDebt(address(debtTaker), 0, 0, 1 ether);
        uint256 _expectedAmount = 1 ether + vault.convertToAssets(2 ether);

        vm.prank(manager);
        debtTaker.withdrawAll();

        assertGe(IERC20(dai).balanceOf(manager), _expectedAmount);
    }

    function testSweep() public {
        IERC20 ajna = IERC20(0x9a96ec9B57Fb64FbC60B423d1f4da7691Bd35079);
        IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(ajna.balanceOf(manager), 0);
        assertEq(weth.balanceOf(manager), 0);

        deal(address(ajna), address(debtTaker), 1 ether);
        deal(address(weth), address(debtTaker), 1 ether);

        address[] memory tokens = new address[](2);
        uint256[] memory balances = new uint256[](2);

        tokens[0] = address(ajna);
        tokens[1] = address(weth);
        balances[0] = ajna.balanceOf(address(debtTaker));
        balances[1] = weth.balanceOf(address(debtTaker));

        vm.prank(manager);
        debtTaker.sweep(tokens, balances);

        assertGe(ajna.balanceOf(manager), 1 ether);
        assertGe(weth.balanceOf(manager), 1 ether);
    }
}
