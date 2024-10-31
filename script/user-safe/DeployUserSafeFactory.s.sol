// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Utils, ChainConfig} from "./Utils.sol";
import {UserSafeFactory} from "../../src/user-safe/UserSafeFactory.sol";
import {UserSafe} from "../../src/user-safe/UserSafe.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UUPSProxy} from "../../src/UUPSProxy.sol";

contract DeployUserSafeFactory is Utils {
    using stdJson for string;

    UserSafeFactory userSafeFactory;
    address userSafeImpl;
    address cashDataProvider;
    address owner;

    function run() public {
        // Pulling deployer info from the environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Start broadcast with deployer as the signer
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        owner = deployer;
        userSafeImpl = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "userSafeImpl")
        );

        cashDataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "cashDataProviderProxy")
        );

        address factoryImpl = address(new UserSafeFactory());
    
        userSafeFactory = UserSafeFactory(
            address(new UUPSProxy(
                factoryImpl, 
                abi.encodeWithSelector(
                    UserSafeFactory.initialize.selector, 
                    address(userSafeImpl), 
                    owner, 
                    address(cashDataProvider)
                ))
            )
        );

        vm.stopBroadcast();
    }
}
