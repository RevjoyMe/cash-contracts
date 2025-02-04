// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICashDataProvider {
    struct InitData {
        address owner;
        uint64 delay;
        address etherFiWallet;
        address settlementDispatcher;
        address etherFiCashDebtManager;
        address priceProvider;
        address swapper;
        address userSafeFactory;
        address userSafeEventEmitter;
        address cashbackDispatcher;
        address userSafeLens;
        address etherFiRecoverySigner;
        address thirdPartyRecoverySigner;
    } 

    enum UserSafeTiers {
        None,
        Whale,
        Chad,
        Wojak,
        Pepe
    }

    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event SettlementDispatcherUpdated(address oldDispatcher, address newDispatcher);
    event CashDebtManagerUpdated(
        address oldDebtManager,
        address newDebtManager
    );
    event PriceProviderUpdated(
        address oldPriceProvider,
        address newPriceProvider
    );
    event SwapperUpdated(address oldSwapper, address newSwapper);
    event UserSafeFactoryUpdated(address oldFactory, address newFactory);
    event UserSafeEventEmitterUpdated(address oldEventEmitter, address newEventEmitter);
    event EtherFiRecoverySignerUpdated(address oldSigner, address newSigner);
    event ThirdPartyRecoverySignerUpdated(address oldSigner, address newSigner);
    event CashbackDispatcherUpdated(address oldDispatcher, address newDispatcher);
    event UserSafeLensUpdated(address oldLens, address newLens);
    event UserSafeTierSet(address indexed userSafe, UserSafeTiers indexed oldTier, UserSafeTiers indexed newTier);
    event TierCashbackPercentageSet(UserSafeTiers[] tiers, uint256[] cashbackPercentages);
    event UserSafeWhitelisted(address userSafe);
    event EtherFiWalletAdded(address wallet);
    event EtherFiWalletRemoved(address wallet);

    error InvalidValue();
    error OnlyUserSafeFactory();
    error AlreadyAWhitelistedEtherFiWallet();
    error NotAWhitelistedEtherFiWallet();
    error RecoverySignersCannotBeSame();
    error NotAUserSafe();
    error TierCannotBeNone();
    error AlreadyInSameTier();
    error ArrayLengthMismatch();
    error CashbackPercentageGreaterThanMaxAllowed();

    /**
     * @notice Function to fetch the timelock delay for tokens from User Safe
     * @return Timelock delay in seconds
     */
    function delay() external view returns (uint64);

    /**
     * @notice Function to check whether a wallet has the ETHER_FI_WALLET_ROLE
     * @return bool suggesting whether it is an EtherFi Wallet
     */
    function isEtherFiWallet(address wallet) external view returns (bool);

    /**
     * @notice Function to fetch the address of the Settlement Dispatcher contract
     * @return Settlement Dispatcher contract address
     */
    function settlementDispatcher() external view returns (address);

    /**
     * @notice Function to fetch the address of the EtherFi Cash Debt Manager contract
     * @return EtherFi Cash Debt Manager contract address
     */
    function etherFiCashDebtManager() external view returns (address);

    /**
     * @notice Function to fetch the address of the Price Provider contract
     * @return Price Provider contract address
     */
    function priceProvider() external view returns (address);

    /**
     * @notice Function to fetch the address of the Swapper contract
     * @return Swapper contract address
     */
    function swapper() external view returns (address);

    /**
     * @notice Function to fetch the address of the user safe factory
     * @return Address of the user safe factory
     */
    function userSafeFactory() external view returns (address);

    /**
     * @notice Function to fetch the address of the user safe event emitter
     * @return Address of the user safe event emitter
     */
    function userSafeEventEmitter() external view returns (address);

    /**
     * @notice Function to fetch the address of the cashback dispatcher
     * @return Address of the cashback dispatcher
     */
    function cashbackDispatcher() external view returns (address);

    /**
     * @notice Function to fetch the address of the user safe lens
     * @return Address of the user safe lens
     */
    function userSafeLens() external view returns (address);

    /**
     * @notice Function to fetch the address of the EtherFi recovery signerr
     * @return Address of the EtherFi recovery signer
     */
    function etherFiRecoverySigner() external view returns (address);
    
    /**
     * @notice Function to fetch the address of the third party recovery signerr
     * @return Address of the third party recovery signer
     */
    function thirdPartyRecoverySigner() external view returns (address);

    /**
     * @notice Function to check if an account is a user safe
     * @param account Address of the account
     * @return isUserSafe 
     */
    function isUserSafe(address account) external view returns (bool);

    /**
     * @notice Function to get the user safe tier
     * @param safe Address of the user safe
     * @return Tier for the user
     */
    function getUserSafeTier(address safe) external view returns (UserSafeTiers);

    /**
     * @notice Function to get the cashback percentage for the user safe
     * @return Cashback percentage for the user
     */
    function getUserSafeCashbackPercentage(address safe) external view returns (uint256);

    /**
     * @notice Function to get the cashback percentage for a tier
     * @return Tier cashback percentage
     */
    function getTierCashbackPercentage(UserSafeTiers tier) external view returns (uint256);

    /**
     * @notice Function to set the timelock delay for tokens from User Safe
     * @dev Can only be called by the admin of the contract
     * @param delay Timelock delay in seconds
     */
    function setDelay(uint64 delay) external;

    /**
     * @notice Function to grant ETHER_FI_WALLER_ROLE to an address
     * @dev Can only be called by the admin of the contract
     * @param wallet EtherFi Cash wallet address
     */
    function grantEtherFiWalletRole(address wallet) external;
    
    /**
     * @notice Function to revoke ETHER_FI_WALLER_ROLE to an address
     * @dev Can only be called by the admin of the contract
     * @param wallet EtherFi Cash wallet address
     */
    function revokeEtherFiWalletRole(address wallet) external;

    /**
     * @notice Function to set the address of the Settlement Dispatcher contract
     * @dev Can only be called by the admin of the contract
     * @param dispatcher Settlement Dispatcher contract address
     */
    function setSettlementDispatcher(address dispatcher) external;

    /**
     * @notice Function to set the address of the EtherFi Cash Debt Manager contract
     * @dev Can only be called by the admin of the contract
     * @param cashDebtManager EtherFi Cash Debt Manager contract address
     */
    function setEtherFiCashDebtManager(address cashDebtManager) external;

    /**
     * @notice Function to set the address of PriceProvider contract
     * @dev Can only be called by the admin of the contract
     * @param priceProvider PriceProvider contract address
     */
    function setPriceProvider(address priceProvider) external;

    /**
     * @notice Function to set the address of Swapper contract
     * @dev Can only be called by the admin of the contract
     * @param swapper Swapper contract address
     */
    function setSwapper(address swapper) external;

    /**
     * @notice Function to set the address of the user safe factory
     * @param factory Address of the new factory
     */
    function setUserSafeFactory(address factory) external;
    
    /**
     * @notice Function to set the address of the user safe event emitter
     * @param eventEmitter Address of the new event emitter
     */
    function setUserSafeEventEmitter(address eventEmitter) external;

    /**
     * @notice Function to set the address of the cashback dispatcher
     * @param dispatcher Address of the new cashback dispatcher
     */
    function setCashbackDispatcher(address dispatcher) external;
    
    /**
     * @notice Function to set the address of the user safe lens
     * @param lens Address of the new user safe lens
     */
    function setUserSafeLens(address lens) external;

    
    /**
     * @notice Function to set the address of the EtherFi recovery signer
     * @param recoverySigner Address of the EtherFi recovery signer
     */
    function setEtherFiRecoverySigner(address recoverySigner) external;
    
    /**
     * @notice Function to set the address of the third party recovery signer
     * @param recoverySigner Address of the third party recovery signer
     */
    function setThirdPartyRecoverySigner(address recoverySigner) external;

    /**
     * @notice Function to whitelist user safes
     * @notice Can only be called by the user safe factory
     * @param safe Address of the safe
     */
    function whitelistUserSafe(address safe) external; 

    /**
     * @notice Function to set user safe tiers
     * @param safes Address of the user safes
     * @param tiers Tier of the user safes
     */
    function setUserSafeTier(address[] memory safes, UserSafeTiers[] memory tiers) external;   

    /**
     * @notice Function to set cashback percentages for different tiers
     * @param tiers Tiers array
     * @param cashbackPercentages Cashback percentages in bps 
     */
    function setTierCashbackPercentage(UserSafeTiers[] memory tiers, uint256[] memory cashbackPercentages) external;
}