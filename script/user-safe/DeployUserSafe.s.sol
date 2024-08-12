// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Utils, ChainConfig} from "./Utils.sol";
import {UserSafeFactory} from "../../src/user-safe/UserSafeFactory.sol";
import {UserSafe} from "../../src/user-safe/UserSafe.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract DeployUserSafe is Utils {
    address owner;
    uint256 ownerKey;
    UserSafeFactory userSafeFactory;
    UserSafe ownerSafe;
    uint256 defaultSpendingLimit = 10000e6;
    uint256 collateralLimit = 10000e6;

    function run() public {
        // Pulling deployer info from the environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // Start broadcast with deployer as the signer
        vm.startBroadcast(deployerPrivateKey);

        (owner, ownerKey) = makeAddrAndKey("owner");

        string memory deployments = readDeploymentFile();

        userSafeFactory = UserSafeFactory(
            stdJson.readAddress(
                deployments,
                string.concat(".", "addresses", ".", "userSafeFactory")
            )
        );

        ownerSafe = UserSafe(
            userSafeFactory.createUserSafe(
                abi.encodeWithSelector(
                    // initialize(bytes,uint256, uint256)
                    0x32b218ac,
                    abi.encode(owner),
                    defaultSpendingLimit,
                    collateralLimit
                )
            )
        );

        string memory parentObject = "parent object";
        string memory deployedAddresses = "addresses";

        vm.serializeUint(deployedAddresses, "ownerPK", ownerKey);
        vm.serializeAddress(deployedAddresses, "owner", address(owner));
        string memory addressOutput = vm.serializeAddress(
            deployedAddresses,
            "safe",
            address(ownerSafe)
        );

        // serialize all the data
        string memory finalJson = vm.serializeString(
            parentObject,
            deployedAddresses,
            addressOutput
        );

        writeUserSafeDeploymentFile(finalJson);
        vm.stopBroadcast();
    }
}
