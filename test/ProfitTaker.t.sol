// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/ProfitTaker.sol";
import "../utils/vyperDeployer.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IProfitTakerFactory {
    function newProfitTaker(
        address vault,
        address recipient,
        address manager,
        uint256 threshold
    ) external returns (ProfitTaker);
}

contract ProfitTakerTest is Test {
    VyperDeployer deployer = new VyperDeployer();
    ProfitTaker public originalProfitTaker;
    ProfitTaker public profitTaker;
    IProfitTakerFactory public profitTakerFactory;
    IERC4626 public vault =
        IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA); //sDAI
    address public dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public recipient = vm.addr(2);
    address public manager = vm.addr(3);
    uint256 public threshold = 100 ether;

    function setUp() public {
        originalProfitTaker = new ProfitTaker();
        profitTakerFactory = IProfitTakerFactory(
            deployer.deployContract(
                "ProfitTakerFactory",
                abi.encode(originalProfitTaker)
            )
        );
        profitTaker = profitTakerFactory.newProfitTaker(
            address(vault),
            recipient,
            manager,
            threshold
        );
    }

    function testChangeRecipient() public {
        vm.prank(manager);
        profitTaker.setRecipient(manager);
        assertEq(profitTaker.recipient(), address(manager));
    }

    function testSetThreshold() public {
        assertEq(profitTaker.threshold(), 100 ether);
        vm.prank(manager);
        profitTaker.setThreshold(200 ether);
        assertEq(profitTaker.threshold(), 200 ether);
    }

    function testDepositAsset() public {
        deal(dai, manager, 1_000 ether);
        vm.startPrank(manager);
        IERC20(dai).approve(address(profitTaker), type(uint256).max);
        assertEq(IERC20(dai).balanceOf(address(profitTaker)), 0);
        profitTaker.deposit(1_000 ether);
        assertEq(IERC20(dai).balanceOf(address(profitTaker)), 0);

        uint256 vaultBalance = vault.balanceOf(address(profitTaker));

        // +10 to avoid might be rounding errors
        assertGe(vault.convertToAssets(vaultBalance) + 10, 1_000 ether);
        vm.stopPrank();

        // current balance of desired token is 0 in the recipient contract
        assertEq(IERC20(profitTaker.token()).balanceOf(address(recipient)), 0);
        skip(1 days);
        vm.roll(block.number + 1);

        // this function could be called by anyone
        profitTaker.rebalance();

        assertEq(
            IERC20(profitTaker.token()).balanceOf(address(recipient)),
            100 ether
        );
    }

    function testDepositRebalanceAndWithdraw() public {
        testDepositAsset();
        vm.startPrank(manager);

        uint256 previousBalance = profitTaker.balanceOfUnderlying();
        profitTaker.withdraw(profitTaker.balanceOfUnderlying());

        assertEq(vault.balanceOf(address(profitTaker)), 0);
        assertEq(
            IERC20(profitTaker.token()).balanceOf(address(manager)),
            previousBalance
        );
        vm.stopPrank();
    }

    function testRebalanceWithoutEnoughAssets() public {
        vm.startPrank(manager);
        profitTaker.setThreshold(1_000 ether);
        uint256 depositAmount = 500 ether;
        deal(dai, manager, depositAmount);

        assertEq(vault.balanceOf(address(profitTaker)), 0);
        IERC20(dai).approve(address(profitTaker), type(uint256).max);
        profitTaker.deposit(depositAmount);
        assertGe(
            vault.convertToAssets(vault.balanceOf(address(profitTaker))) + 10,
            depositAmount
        );

        vm.stopPrank();

        // current balance of desired token is 0 in the recipient contract
        assertEq(IERC20(profitTaker.token()).balanceOf(address(recipient)), 0);
        //skip(1 days);
        //vm.roll(block.number + 1);

        // this function could be called by anyone
        assertTrue(profitTaker.rebalanceTrigger());
        profitTaker.rebalance();

        assertEq(vault.balanceOf(address(profitTaker)), 0);
        assertGe(
            IERC20(profitTaker.token()).balanceOf(address(recipient)) + 10,
            500 ether
        );

        assertFalse(profitTaker.rebalanceTrigger());
    }

    function testWithdrawAll() public {
        assertEq(IERC20(dai).balanceOf(manager), 0);

        deal(dai, address(profitTaker), 1 ether);
        deal(address(vault), address(profitTaker), 1 ether);
        uint256 _expectedAmount = 1 ether + vault.convertToAssets(1 ether);

        vm.prank(manager);
        profitTaker.withdrawAll();

        assertGe(IERC20(dai).balanceOf(manager), _expectedAmount);
    }

    function testSweep() public {
        IERC20 ajna = IERC20(0x9a96ec9B57Fb64FbC60B423d1f4da7691Bd35079);
        IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(ajna.balanceOf(manager), 0);
        assertEq(weth.balanceOf(manager), 0);

        deal(address(ajna), address(profitTaker), 1 ether);
        deal(address(weth), address(profitTaker), 1 ether);

        address[] memory tokens = new address[](2);
        uint256[] memory balances = new uint256[](2);

        tokens[0] = address(ajna);
        tokens[1] = address(weth);
        balances[0] = ajna.balanceOf(address(profitTaker));
        balances[1] = weth.balanceOf(address(profitTaker));

        vm.prank(manager);
        profitTaker.sweep(tokens, balances);

        assertGe(ajna.balanceOf(manager), 1 ether);
        assertGe(weth.balanceOf(manager), 1 ether);
    }
}
