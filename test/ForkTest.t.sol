// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, stdError} from "forge-std/Test.sol";
import {Utils, ChainConfig} from "../script/user-safe/Utils.sol";
import {DebtManagerCore} from "../src/debt-manager/DebtManagerCore.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract ForkTest is Utils {
    using stdJson for string;

    address user = 0x2F9e38E716AD75B6f8005C65BD727183137393F1;
    address borrowToken = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    uint256 withdrawAmt = 10000000;
    DebtManagerCore debtManager;
    
    function setUp() public {
        vm.createSelectFork("https://1rpc.io/scroll");
        
        string memory deployments = readDeploymentFile();
        debtManager = DebtManagerCore(stdJson.readAddress(
                deployments,
                string.concat(".", "addresses", ".", "debtManagerProxy")
            )
        );
    }
    
    // function test_Withdraw() public {
    //     vm.prank(user);
    //     debtManager.withdrawBorrowToken(borrowToken, withdrawAmt);
    // }
}
