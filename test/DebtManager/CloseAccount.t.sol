// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DebtManagerSetup} from "./DebtManagerSetup.t.sol";
import {IL2DebtManager} from "../../src/interfaces/IL2DebtManager.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DebtManagerCloseAccountTest is DebtManagerSetup {
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
        vm.stopPrank();
    }

    function test_CloseAccount() public {
        IL2DebtManager.TokenData[]
            memory tokenData = new IL2DebtManager.TokenData[](1);
        tokenData[0] = IL2DebtManager.TokenData({
            token: address(weETH),
            amount: collateralAmount
        });

        uint256 aliceCollateralBefore = debtManager.getCollateralValueInUsd(
            alice
        );

        // Can easily withdraw the amount till liquidation threshold
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit IL2DebtManager.AccountClosed(alice, tokenData);
        debtManager.closeAccount();
        vm.stopPrank();

        uint256 aliceCollateralAfter = debtManager.getCollateralValueInUsd(
            alice
        );
        assertEq(
            aliceCollateralBefore,
            debtManager.convertCollateralTokenToUsd(
                address(weETH),
                collateralAmount
            )
        );
        assertEq(aliceCollateralAfter, 0);
    }

    function test_CannotCloseAccountIfNotUserSafe() public {
        vm.expectRevert(IL2DebtManager.OnlyUserSafe.selector);
        debtManager.closeAccount();
    }
}
