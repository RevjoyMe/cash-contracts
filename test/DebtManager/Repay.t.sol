// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DebtManagerSetup} from "./DebtManagerSetup.t.sol";
import {IL2DebtManager} from "../../src/interfaces/IL2DebtManager.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract DebtManagerRepayTest is DebtManagerSetup {
    using SafeERC20 for IERC20;
    using stdStorage for StdStorage;

    uint256 collateralAmount = 0.01 ether;
    uint256 collateralValueInUsdc;
    uint256 borrowAmt;

    function setUp() public override {
        super.setUp();

        collateralValueInUsdc = debtManager.convertCollateralTokenToUsd(
            address(weETH),
            collateralAmount
        );

        deal(address(usdc), alice, 1 ether);
        deal(address(weETH), alice, 1000 ether);
        // so that debt manager has funds for borrowings
        deal(address(usdc), address(debtManager), 1 ether);

        vm.startPrank(alice);
        IERC20(address(weETH)).safeIncreaseAllowance(address(debtManager), collateralAmount);
        debtManager.depositCollateral(address(weETH), alice, collateralAmount);

        borrowAmt = debtManager.remainingBorrowingCapacityInUSD(alice) / 2;

        debtManager.borrow(address(usdc), borrowAmt);
        vm.stopPrank();
    }

    function test_RepayWithUsdc() public {
        uint256 debtAmtBefore = debtManager.borrowingOf(alice, address(usdc));
        assertGt(debtAmtBefore, 0);

        uint256 repayAmt = debtAmtBefore;

        vm.startPrank(alice);
        IERC20(address(usdc)).forceApprove(address(debtManager), repayAmt);
        debtManager.repay(alice, address(usdc), repayAmt);
        vm.stopPrank();

        uint256 debtAmtAfter = debtManager.borrowingOf(alice, address(usdc));
        assertEq(debtAmtBefore - debtAmtAfter, repayAmt);
    }

    function test_RepayAfterSomeTimeIncursInterestOnTheBorrowings() public {
        uint256 timeElapsed = 10;

        vm.warp(block.timestamp + timeElapsed);
        uint256 expectedInterest = (borrowAmt *
            borrowApyPerSecond *
            timeElapsed) / 1e20;

        uint256 debtAmtBefore = borrowAmt + expectedInterest;
        console.log(debtAmtBefore);

        assertEq(debtManager.borrowingOf(alice, address(usdc)), debtAmtBefore);
        uint256 repayAmt = debtAmtBefore;

        vm.startPrank(alice);
        IERC20(address(usdc)).forceApprove(address(debtManager), repayAmt);
        debtManager.repay(alice, address(usdc), repayAmt);
        vm.stopPrank();

        uint256 debtAmtAfter = debtManager.borrowingOf(alice, address(usdc));
        console.log(debtAmtAfter);
        assertEq(debtAmtBefore - debtAmtAfter, repayAmt);
    }

    function test_CannotRepayWithUsdcIfAllowanceIsInsufficient() public {
        vm.startPrank(alice);
        IERC20(address(usdc)).forceApprove(address(debtManager), 0);

        if (!isFork(chainId))
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector,
                    address(debtManager),
                    0,
                    1
                )
            );
        else vm.expectRevert("ERC20: transfer amount exceeds allowance");

        debtManager.repay(alice, address(usdc), 1);
        vm.stopPrank();
    }

    function test_CannotRepayWithUsdcIfBalanceIsInsufficient() public {
        deal(address(usdc), alice, 0);

        vm.startPrank(alice);
        IERC20(address(usdc)).forceApprove(address(debtManager), 1);

        if (!isFork(chainId))
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector,
                    alice,
                    0,
                    1
                )
            );
        else vm.expectRevert("ERC20: transfer amount exceeds balance");
        debtManager.repay(alice, address(usdc), 1);
        vm.stopPrank();
    }

    function test_CanRepayForOtherUser() public {
        uint256 debtAmtBefore = debtManager.borrowingOf(alice, address(usdc));
        assertGt(debtAmtBefore, 0);

        uint256 repayAmt = debtAmtBefore;

        vm.startPrank(notOwner);
        deal(address(usdc), notOwner, repayAmt);
        IERC20(address(usdc)).forceApprove(address(debtManager), repayAmt);
        debtManager.repay(alice, address(usdc), repayAmt);
        vm.stopPrank();

        uint256 debtAmtAfter = debtManager.borrowingOf(alice, address(usdc));
        assertEq(debtAmtBefore - debtAmtAfter, repayAmt);
    }
}
