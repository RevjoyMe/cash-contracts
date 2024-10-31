// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DebtManagerSetup} from "./DebtManagerSetup.t.sol";
import {IL2DebtManager} from "../../src/interfaces/IL2DebtManager.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DebtManagerWithdrawTest is DebtManagerSetup {
    using SafeERC20 for IERC20;

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

    function test_Withdraw() public {
        uint256 usdcAmt = debtManager.remainingBorrowingCapacityInUSD(alice);

        uint256 withdrawAmt;
        if (!isFork(chainId)) {
            withdrawAmt = (usdcAmt * 1e18) / mockWeETHPriceInUsd;
        } else {
            withdrawAmt =
                (usdcAmt * 1e18) /
                priceProvider.price(address(weETH));
        }

        uint256 aliceBalBefore = weETH.balanceOf(alice);
        uint256 aliceCollateralBefore = debtManager.getCollateralValueInUsd(
            alice
        );

        // Can easily withdraw the amount till liquidation threshold
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IL2DebtManager.WithdrawCollateral(
            alice,
            address(weETH),
            withdrawAmt
        );
        debtManager.withdrawCollateral(address(weETH), withdrawAmt);

        uint256 aliceBalAfter = weETH.balanceOf(alice);
        uint256 aliceCollateralAfter = debtManager.getCollateralValueInUsd(
            alice
        );

        assertEq(aliceBalAfter - aliceBalBefore, withdrawAmt);
        assertEq(aliceCollateralBefore - aliceCollateralAfter, usdcAmt);
    }

    function test_CannotWithdrawIfNotACollateralToken() public {
        vm.prank(alice);
        vm.expectRevert(IL2DebtManager.UnsupportedCollateralToken.selector);
        debtManager.withdrawCollateral(address(usdc), 1);
    }

    function test_CannotWithdrawIfDebtRatioBecomesUnhealthyAfterWithdrawal()
        public
    {
        uint256 unhealthyWithdrawAmt = (collateralAmount * 2) / 3;

        vm.prank(alice);
        vm.expectRevert(IL2DebtManager.AccountUnhealthy.selector);
        debtManager.withdrawCollateral(address(weETH), unhealthyWithdrawAmt);
    }
}
