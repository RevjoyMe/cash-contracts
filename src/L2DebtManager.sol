// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICashDataProvider} from "./interfaces/ICashDataProvider.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {UUPSUpgradeable, Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IL2DebtManager} from "./interfaces/IL2DebtManager.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {IEtherFiCashAaveV3Adapter} from "./interfaces/IEtherFiCashAaveV3Adapter.sol";
import {ICashDataProvider} from "./interfaces/ICashDataProvider.sol";
import {AaveLib} from "./libraries/AaveLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransientUpgradeable} from "./utils/ReentrancyGuardTransientUpgradeable.sol";

/**
 * @title L2 Debt Manager
 * @author @seongyun-ko @shivam-ef
 * @notice Contract to manage lending and borrowing for Cash protocol
 */
contract L2DebtManager is
    IL2DebtManager,
    Initializable,
    UUPSUpgradeable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant HUNDRED_PERCENT = 100e18;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SIX_DECIMALS = 1e6;

    ICashDataProvider private immutable _cashDataProvider;

    address[] private _supportedCollateralTokens;
    address[] private _supportedBorrowTokens;
    mapping(address token => uint256 index)
        private _collateralTokenIndexPlusOne;
    mapping(address token => uint256 index) private _borrowTokenIndexPlusOne;
    mapping(address borrowToken => BorrowTokenConfig config)
        private _borrowTokenConfig;

    // Collateral held by the user
    mapping(address user => mapping(address token => uint256 amount))
        private _userCollateral;
    // Total collateral held by the users with the contract
    mapping(address token => uint256 amount) private _totalCollateralAmounts;
    mapping(address token => CollateralTokenConfig config)
        private _collateralTokenConfig;

    // Borrowings is in USD with 6 decimals
    mapping(address user => mapping(address borrowToken => uint256 borrowing))
        private _userBorrowings;
    // Snapshot of user's interests already paid
    mapping(address user => mapping(address borrowToken => uint256 interestSnapshot))
        private _usersDebtInterestIndexSnapshots;

    // Shares have 18 decimals
    mapping(address supplier => mapping(address borrowToken => uint256 shares))
        private _sharesOfBorrowTokens;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address __cashDataProvider) {
        _cashDataProvider = ICashDataProvider(__cashDataProvider);
        _disableInitializers();
    }

    function initialize(
        address __owner,
        uint48 __defaultAdminDelay,
        address[] calldata __supportedCollateralTokens,
        CollateralTokenConfig[] calldata __collateralTokenConfigs,
        address[] calldata __supportedBorrowTokens,
        BorrowTokenConfigData[] calldata __borrowTokenConfig
    ) external initializer {
        _init(__owner, __defaultAdminDelay);
        _initCollateralTokens(
            __supportedCollateralTokens,
            __collateralTokenConfigs
        );
        _initBorrowTokens(__supportedBorrowTokens, __borrowTokenConfig);
    }

    // This function was added to avoid stack too deep error
    function _init(address __owner, uint48 __defaultAdminDelay) internal {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init_unchained();
        __AccessControlDefaultAdminRules_init(__defaultAdminDelay, __owner);
        _grantRole(ADMIN_ROLE, __owner);
    }

    function _initCollateralTokens(
        address[] calldata __supportedCollateralTokens,
        CollateralTokenConfig[] calldata __collateralTokenConfigs
    ) internal {
        uint256 len = __supportedCollateralTokens.length;
        if (len != __collateralTokenConfigs.length)
            revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len; ) {
            _supportCollateralToken(__supportedCollateralTokens[i]);
            _setCollateralTokenConfig(
                __supportedCollateralTokens[i],
                __collateralTokenConfigs[i]
            );

            unchecked {
                ++i;
            }
        }
    }

    function _initBorrowTokens(
        address[] calldata __supportedBorrowTokens,
        BorrowTokenConfigData[] calldata __borrowTokenConfig
    ) internal {
        uint256 len = __supportedBorrowTokens.length;
        if (len != __borrowTokenConfig.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len; ) {
            _supportBorrowToken(__supportedBorrowTokens[i]);
            _setBorrowTokenConfig(
                __supportedBorrowTokens[i],
                __borrowTokenConfig[i].borrowApy,
                __borrowTokenConfig[i].minSharesToMint
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function cashDataProvider() external view returns (address) {
        return address(_cashDataProvider);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrowTokenConfig(
        address borrowToken
    ) public view returns (BorrowTokenConfig memory) {
        BorrowTokenConfig memory config = _borrowTokenConfig[borrowToken];
        config.totalBorrowingAmount = _getAmountWithInterest(
            borrowToken,
            config.totalBorrowingAmount,
            config.interestIndexSnapshot
        );

        return config;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function collateralTokenConfig(
        address collateralToken
    ) external view returns (CollateralTokenConfig memory) {
        return _collateralTokenConfig[collateralToken];
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function getCollateralTokens() public view returns (address[] memory) {
        uint256 len = _supportedCollateralTokens.length;
        address[] memory tokens = new address[](len);

        for (uint256 i = 0; i < len; ) {
            tokens[i] = _supportedCollateralTokens[i];
            unchecked {
                ++i;
            }
        }

        return tokens;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function getBorrowTokens() public view returns (address[] memory) {
        uint256 len = _supportedBorrowTokens.length;
        address[] memory tokens = new address[](len);

        for (uint256 i = 0; i < len; ) {
            tokens[i] = _supportedBorrowTokens[i];
            unchecked {
                ++i;
            }
        }

        return tokens;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function isCollateralToken(address token) public view returns (bool) {
        return _collateralTokenIndexPlusOne[token] != 0;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function isBorrowToken(address token) public view returns (bool) {
        return _borrowTokenIndexPlusOne[token] != 0;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function getUserCollateralForToken(
        address user,
        address token
    ) external view returns (uint256, uint256) {
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();
        uint256 collateralTokenAmt = _userCollateral[user][token];
        uint256 collateralAmtInUsd = convertCollateralTokenToUsdc(
            token,
            collateralTokenAmt
        );

        return (collateralTokenAmt, collateralAmtInUsd);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function totalBorrowingAmount(
        address borrowToken
    ) public view returns (uint256) {
        return
            _getAmountWithInterest(
                borrowToken,
                _borrowTokenConfig[borrowToken].totalBorrowingAmount,
                _borrowTokenConfig[borrowToken].interestIndexSnapshot
            );
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function totalBorrowingAmounts()
        public
        view
        returns (TokenData[] memory, uint256)
    {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory tokenData = new TokenData[](len);
        uint256 totalBorrowingAmt = 0;

        for (uint256 i = 0; i < len; ) {
            BorrowTokenConfig memory config = borrowTokenConfig(
                _supportedBorrowTokens[i]
            );

            tokenData[i] = TokenData({
                token: _supportedBorrowTokens[i],
                amount: config.totalBorrowingAmount
            });

            totalBorrowingAmt += config.totalBorrowingAmount;

            unchecked {
                ++i;
            }
        }

        return (tokenData, totalBorrowingAmt);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrowingOf(
        address user,
        address borrowToken
    ) public view returns (uint256) {
        return
            _getAmountWithInterest(
                borrowToken,
                _userBorrowings[user][borrowToken],
                _usersDebtInterestIndexSnapshots[user][borrowToken]
            );
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrowingOf(
        address user
    ) public view returns (TokenData[] memory, uint256) {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory borrowTokenData = new TokenData[](len);
        uint256 totalBorrowingInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            address borrowToken = _supportedBorrowTokens[i];
            uint256 amount = borrowingOf(user, borrowToken);
            totalBorrowingInUsd += amount;

            borrowTokenData[i] = TokenData({
                token: borrowToken,
                amount: amount
            });
            unchecked {
                ++i;
            }
        }

        return (borrowTokenData, totalBorrowingInUsd);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function totalCollateralAmounts()
        public
        view
        returns (TokenData[] memory, uint256)
    {
        uint256 len = _supportedCollateralTokens.length;
        TokenData[] memory collaterals = new TokenData[](len);
        uint256 totalCollateralInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            collaterals[i] = TokenData({
                token: _supportedCollateralTokens[i],
                amount: _totalCollateralAmounts[_supportedCollateralTokens[i]]
            });

            totalCollateralInUsd += convertCollateralTokenToUsdc(
                collaterals[i].token,
                collaterals[i].amount
            );

            unchecked {
                ++i;
            }
        }

        return (collaterals, totalCollateralInUsd);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function liquidatable(address user) public view returns (bool) {
        (, uint256 userBorrowing) = borrowingOf(user);
        // Total borrowing in USDC > total max borrowing of the user
        return userBorrowing > getMaxBorrowAmount(user, false);
    }

    function getMaxBorrowAmount(
        address user,
        bool forLtv
    ) public view returns (uint256) {
        uint256 len = _supportedCollateralTokens.length;
        uint256 totalMaxBorrow = 0;

        for (uint256 i = 0; i < len; ) {
            uint256 collateral = convertCollateralTokenToUsdc(
                _supportedCollateralTokens[i],
                _userCollateral[user][_supportedCollateralTokens[i]]
            );

            if (forLtv)
                // user collateral for token in USDC * 100 / liquidation threshold
                totalMaxBorrow += collateral.mulDiv(
                    _collateralTokenConfig[_supportedCollateralTokens[i]].ltv,
                    HUNDRED_PERCENT,
                    Math.Rounding.Floor
                );
            else
                totalMaxBorrow += collateral.mulDiv(
                    _collateralTokenConfig[_supportedCollateralTokens[i]]
                        .liquidationThreshold,
                    HUNDRED_PERCENT,
                    Math.Rounding.Floor
                );

            unchecked {
                ++i;
            }
        }

        return totalMaxBorrow;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function collateralOf(
        address user
    ) public view returns (TokenData[] memory, uint256) {
        uint256 len = _supportedCollateralTokens.length;
        TokenData[] memory collaterals = new TokenData[](len);
        uint256 totalCollateralInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            collaterals[i] = TokenData({
                token: _supportedCollateralTokens[i],
                amount: _userCollateral[user][_supportedCollateralTokens[i]]
            });

            totalCollateralInUsd += convertCollateralTokenToUsdc(
                collaterals[i].token,
                collaterals[i].amount
            );

            unchecked {
                ++i;
            }
        }

        return (collaterals, totalCollateralInUsd);
    }

    // if user borrowings is greater than they can borrow as per LTV, revert
    function _ensureHealth(address user) public view {
        (, uint256 totalBorrowings) = borrowingOf(user);
        if (totalBorrowings > getMaxBorrowAmount(user, true))
            revert AccountUnhealthy();
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function remainingBorrowingCapacityInUSDC(
        address user
    ) public view returns (uint256) {
        uint256 maxBorrowingAmount = getMaxBorrowAmount(user, true);
        (, uint256 currentBorrowingWithInterest) = borrowingOf(user);

        return
            maxBorrowingAmount > currentBorrowingWithInterest
                ? maxBorrowingAmount - currentBorrowingWithInterest
                : 0;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrowApyPerSecond(
        address borrowToken
    ) external view returns (uint64) {
        return _borrowTokenConfig[borrowToken].borrowApy;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrowTokenMinSharesToMint(
        address borrowToken
    ) external view returns (uint128) {
        return _borrowTokenConfig[borrowToken].minSharesToMint;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function getCurrentState()
        public
        view
        returns (
            TokenData[] memory totalCollaterals,
            uint256 totalCollateralInUsdc,
            TokenData[] memory borrowings,
            uint256 totalBorrowings,
            TokenData[] memory totalLiquidCollateralAmounts,
            TokenData[] memory totalLiquidStableAmounts
        )
    {
        (totalCollaterals, totalCollateralInUsdc) = totalCollateralAmounts();
        (borrowings, totalBorrowings) = totalBorrowingAmounts();
        totalLiquidCollateralAmounts = liquidCollateralAmounts();
        totalLiquidStableAmounts = liquidStableAmount();
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function liquidCollateralAmounts()
        public
        view
        returns (TokenData[] memory)
    {
        uint256 len = _supportedCollateralTokens.length;
        TokenData[] memory collaterals = new TokenData[](len);

        for (uint256 i = 0; i < len; ) {
            uint256 balance = IERC20(_supportedCollateralTokens[i]).balanceOf(
                address(this)
            );
            if (
                balance > _totalCollateralAmounts[_supportedCollateralTokens[i]]
            )
                collaterals[i] = TokenData({
                    token: _supportedCollateralTokens[i],
                    amount: balance -
                        _totalCollateralAmounts[_supportedCollateralTokens[i]]
                });
            else
                collaterals[i] = TokenData({
                    token: _supportedCollateralTokens[i],
                    amount: 0
                });

            unchecked {
                ++i;
            }
        }

        return collaterals;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function liquidStableAmount() public view returns (TokenData[] memory) {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory tokenData = new TokenData[](len);

        uint256 totalStableBalances = 0;
        for (uint256 i = 0; i < len; ) {
            uint256 bal = IERC20(_supportedBorrowTokens[i]).balanceOf(
                address(this)
            );
            tokenData[i] = TokenData({
                token: _supportedBorrowTokens[i],
                amount: bal
            });
            totalStableBalances += bal;

            unchecked {
                ++i;
            }
        }

        return tokenData;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function withdrawableBorrowToken(
        address supplier,
        address borrowToken
    ) external view returns (uint256) {
        if (_borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens == 0)
            return 0;

        return
            _sharesOfBorrowTokens[supplier][borrowToken].mulDiv(
                _getTotalBorrowTokenAmount(borrowToken),
                _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
                Math.Rounding.Floor
            );
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function convertUsdcToCollateralToken(
        address collateralToken,
        uint256 debtUsdcAmount
    ) public view returns (uint256) {
        if (!isCollateralToken(collateralToken))
            revert UnsupportedCollateralToken();
        return
            (debtUsdcAmount * 10 ** _getDecimals(collateralToken)) /
            IPriceProvider(_cashDataProvider.priceProvider()).price(
                collateralToken
            );
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function convertCollateralTokenToUsdc(
        address collateralToken,
        uint256 collateralAmount
    ) public view returns (uint256) {
        if (!isCollateralToken(collateralToken))
            revert UnsupportedCollateralToken();

        return
            (collateralAmount *
                IPriceProvider(_cashDataProvider.priceProvider()).price(
                    collateralToken
                )) / 10 ** _getDecimals(collateralToken);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function getCollateralValueInUsdc(
        address user
    ) public view returns (uint256) {
        uint256 len = _supportedCollateralTokens.length;
        uint256 userCollateralInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            userCollateralInUsd += convertCollateralTokenToUsdc(
                _supportedCollateralTokens[i],
                _userCollateral[user][_supportedCollateralTokens[i]]
            );

            unchecked {
                ++i;
            }
        }

        return userCollateralInUsd;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function debtInterestIndexSnapshot(
        address borrowToken
    ) public view returns (uint256) {
        return
            _borrowTokenConfig[borrowToken].interestIndexSnapshot +
            (block.timestamp -
                _borrowTokenConfig[borrowToken].lastUpdateTimestamp) *
            _borrowTokenConfig[borrowToken].borrowApy;
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function supportCollateralToken(
        address token,
        CollateralTokenConfig calldata config
    ) external onlyRole(ADMIN_ROLE) {
        _supportCollateralToken(token);
        _setCollateralTokenConfig(token, config);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function unsupportCollateralToken(
        address token
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidValue();
        if (_totalCollateralAmounts[token] != 0)
            revert TotalCollateralAmountNotZero();

        uint256 indexPlusOneForTokenToBeRemoved = _collateralTokenIndexPlusOne[
            token
        ];
        if (indexPlusOneForTokenToBeRemoved == 0) revert NotACollateralToken();

        uint256 len = _supportedCollateralTokens.length;
        if (len == 1) revert NoCollateralTokenLeft();

        _collateralTokenIndexPlusOne[
            _supportedCollateralTokens[len - 1]
        ] = indexPlusOneForTokenToBeRemoved;

        _supportedCollateralTokens[
            indexPlusOneForTokenToBeRemoved - 1
        ] = _supportedCollateralTokens[len - 1];

        _supportedCollateralTokens.pop();
        delete _collateralTokenIndexPlusOne[token];

        CollateralTokenConfig memory config;
        _setCollateralTokenConfig(token, config);

        emit CollateralTokenRemoved(token);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function supportBorrowToken(
        address token,
        uint64 borrowApy,
        uint128 minSharesToMint
    ) external onlyRole(ADMIN_ROLE) {
        _supportBorrowToken(token);
        _setBorrowTokenConfig(token, borrowApy, minSharesToMint);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function unsupportBorrowToken(address token) external onlyRole(ADMIN_ROLE) {
        uint256 indexPlusOneForTokenToBeRemoved = _borrowTokenIndexPlusOne[
            token
        ];
        if (indexPlusOneForTokenToBeRemoved == 0) revert NotABorrowToken();

        if (_getTotalBorrowTokenAmount(token) != 0)
            revert BorrowTokenStillInTheSystem();

        uint256 len = _supportedBorrowTokens.length;
        if (len == 1) revert NoBorrowTokenLeft();

        _borrowTokenIndexPlusOne[
            _supportedBorrowTokens[len - 1]
        ] = indexPlusOneForTokenToBeRemoved;

        _supportedBorrowTokens[
            indexPlusOneForTokenToBeRemoved - 1
        ] = _supportedBorrowTokens[len - 1];

        _supportedBorrowTokens.pop();
        delete _borrowTokenIndexPlusOne[token];
        delete _borrowTokenConfig[token];

        emit BorrowTokenRemoved(token);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function setCollateralTokenConfig(
        address __collateralToken,
        CollateralTokenConfig memory __config
    ) external onlyRole(ADMIN_ROLE) {
        _setCollateralTokenConfig(__collateralToken, __config);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function setBorrowApy(
        address token,
        uint64 apy
    ) external onlyRole(ADMIN_ROLE) {
        _setBorrowApy(token, apy);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function setMinBorrowTokenSharesToMint(
        address token,
        uint128 shares
    ) external onlyRole(ADMIN_ROLE) {
        _setMinBorrowTokenSharesToMint(token, shares);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function supply(
        address user,
        address borrowToken,
        uint256 amount
    ) external {
        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();
        uint256 shares = _borrowTokenConfig[borrowToken]
            .totalSharesOfBorrowTokens == 0
            ? amount
            : amount.mulDiv(
                _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
                _getTotalBorrowTokenAmount(borrowToken),
                Math.Rounding.Floor
            );

        if (shares < _borrowTokenConfig[borrowToken].minSharesToMint)
            revert SharesCannotBeLessThanMinSharesToMint();

        // Moving this before state update to prevent reentrancy
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        _sharesOfBorrowTokens[user][borrowToken] += shares;
        _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens += shares;

        emit Supplied(msg.sender, user, borrowToken, amount);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function withdrawBorrowToken(address borrowToken, uint256 amount) external {
        uint256 totalBorrowTokenAmt = _getTotalBorrowTokenAmount(borrowToken);
        if (totalBorrowTokenAmt == 0) revert ZeroTotalBorrowTokens();

        uint256 shares = amount.mulDiv(
            _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
            totalBorrowTokenAmt,
            Math.Rounding.Ceil
        );

        if (shares == 0) revert SharesCannotBeZero();

        if (_sharesOfBorrowTokens[msg.sender][borrowToken] < shares)
            revert InsufficientBorrowShares();

        _sharesOfBorrowTokens[msg.sender][borrowToken] -= shares;
        _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens -= shares;

        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit WithdrawBorrowToken(msg.sender, borrowToken, amount);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function depositCollateral(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();

        _totalCollateralAmounts[token] += amount;
        _userCollateral[user][token] += amount;

        if(_totalCollateralAmounts[token] > _collateralTokenConfig[token].supplyCap) 
            revert SupplyCapBreached();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit DepositedCollateral(msg.sender, user, token, amount);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function borrow(address token, uint256 amount) external {
        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();
        _updateBorrowings(msg.sender, token);

        // Convert amount to 6 decimals before adding to borrowings
        uint256 borrowAmt = _convertToSixDecimals(token, amount);
        if (borrowAmt == 0) revert BorrowAmountZero();

        _userBorrowings[msg.sender][token] += borrowAmt;
        _borrowTokenConfig[token].totalBorrowingAmount += borrowAmt;

        _ensureHealth(msg.sender);

        if (IERC20(token).balanceOf(address(this)) < amount)
            revert InsufficientLiquidity();

        IERC20(token).safeTransfer(
            _cashDataProvider.etherFiCashMultiSig(),
            amount
        );

        emit Borrowed(msg.sender, token, amount);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function repay(
        address user,
        address token,
        uint256 repayDebtUsdcAmt
    ) external {
        _updateBorrowings(user, token);
        if (_userBorrowings[user][token] < repayDebtUsdcAmt)
            repayDebtUsdcAmt = _userBorrowings[user][token];
        if (repayDebtUsdcAmt == 0) revert RepaymentAmountIsZero();

        if (!isBorrowToken(token)) revert UnsupportedRepayToken();

        _repayWithBorrowToken(token, user, repayDebtUsdcAmt);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function withdrawCollateral(address token, uint256 amount) external {
        _updateBorrowings(msg.sender);
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();

        _totalCollateralAmounts[token] -= amount;
        _userCollateral[msg.sender][token] -= amount;

        _ensureHealth(msg.sender);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, token, amount);
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function closeAccount() external {
        _updateBorrowings(msg.sender);
        (, uint256 userBorrowing) = borrowingOf(msg.sender);
        if (userBorrowing != 0) revert TotalBorrowingsForUserNotZero();

        (TokenData[] memory tokenData, ) = collateralOf(msg.sender);
        uint256 len = tokenData.length;

        for (uint256 i = 0; i < len; ) {
            if (
                IERC20(tokenData[i].token).balanceOf(address(this)) <
                tokenData[i].amount
            ) revert InsufficientLiquidityPleaseTryAgainLater();

            _userCollateral[msg.sender][tokenData[i].token] -= tokenData[i]
                .amount;
            _totalCollateralAmounts[tokenData[i].token] -= tokenData[i].amount;

            IERC20(tokenData[i].token).safeTransfer(
                msg.sender,
                tokenData[i].amount
            );

            unchecked {
                ++i;
            }
        }

        emit AccountClosed(msg.sender, tokenData);
    }

    // https://docs.aave.com/faq/liquidations
    /**
     * @inheritdoc IL2DebtManager
     */
    function liquidate(
        address user,
        address borrowToken,
        address[] memory collateralTokensPreference
    ) external nonReentrant {
        _updateBorrowings(user);
        if (!liquidatable(user)) revert CannotLiquidateYet();
        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();

        _liquidateUser(user, borrowToken, collateralTokensPreference);
    }

    function _liquidateUser(
        address user,
        address borrowToken,
        address[] memory collateralTokensPreference
    ) internal {
        uint256 debtAmountToLiquidateInUsdc = _userBorrowings[user][borrowToken].ceilDiv(2);
        _liquidate(user, borrowToken, collateralTokensPreference, debtAmountToLiquidateInUsdc);

        if (liquidatable(user)) _liquidate(user, borrowToken, collateralTokensPreference, _userBorrowings[user][borrowToken]);
    }

    function _liquidate(
        address user,
        address borrowToken,
        address[] memory collateralTokensPreference,
        uint256 debtAmountToLiquidateInUsdc
    ) internal {    
        uint256 beforeDebtAmount = _userBorrowings[user][borrowToken];
        if (debtAmountToLiquidateInUsdc == 0) revert LiquidatableAmountIsZero();

        (LiquidationTokenData[] memory collateralTokensToSend, uint256 remainingDebt) = _getCollateralTokensForDebtAmount(
            user,
            debtAmountToLiquidateInUsdc,
            collateralTokensPreference
        );

        (TokenData[] memory beforeCollateralAmounts, ) = collateralOf(user);

        uint256 len = collateralTokensToSend.length;

        for (uint256 i = 0; i < len; ) {
            if (collateralTokensToSend[i].amount > 0) {
                _userCollateral[user][
                    collateralTokensToSend[i].token
                ] -= collateralTokensToSend[i].amount;
                _totalCollateralAmounts[
                    collateralTokensToSend[i].token
                ] -= collateralTokensToSend[i].amount;

                IERC20(collateralTokensToSend[i].token).safeTransfer(
                    msg.sender,
                    collateralTokensToSend[i].amount
                );
            }

            unchecked {
                ++i;
            }
        }

        uint256 liquidatedAmt = debtAmountToLiquidateInUsdc - remainingDebt;
        _userBorrowings[user][borrowToken] -= liquidatedAmt;
        _borrowTokenConfig[borrowToken]
            .totalBorrowingAmount -= liquidatedAmt;

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), liquidatedAmt);

        emit Liquidated(
            msg.sender,
            user,
            borrowToken,
            beforeCollateralAmounts,
            collateralTokensToSend,
            beforeDebtAmount,
            liquidatedAmt
        );
    }

    /**
     * @inheritdoc IL2DebtManager
     */
    function fundManagementOperation(
        uint8 marketOperationType,
        bytes calldata data
    ) external onlyRole(ADMIN_ROLE) {
        address aaveV3Adapter = _cashDataProvider.aaveAdapter();
        AaveLib.aaveOperation(aaveV3Adapter, marketOperationType, data);
    }

    function _setCollateralTokenConfig(
        address collateralToken,
        CollateralTokenConfig memory config
    ) internal {
        if (config.ltv > config.liquidationThreshold)
            revert LtvCannotBeGreaterThanLiquidationThreshold();
        
        if (config.liquidationBonus > HUNDRED_PERCENT) revert InvalidValue();

        emit CollateralTokenConfigSet(
            collateralToken,
            _collateralTokenConfig[collateralToken],
            config
        );

        _collateralTokenConfig[collateralToken] = config;
    }

    function _setBorrowTokenConfig(
        address borrowToken,
        uint64 borrowApy,
        uint128 minSharesToMint
    ) internal {
        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();
        if (_borrowTokenConfig[borrowToken].lastUpdateTimestamp != 0)
            revert BorrowTokenConfigAlreadySet();

        if (borrowApy == 0 || minSharesToMint == 0) revert InvalidValue();

        BorrowTokenConfig memory cfg = BorrowTokenConfig({
            interestIndexSnapshot: 0,
            totalBorrowingAmount: 0,
            totalSharesOfBorrowTokens: 0,
            lastUpdateTimestamp: uint64(block.timestamp),
            borrowApy: borrowApy,
            minSharesToMint: minSharesToMint
        });

        _borrowTokenConfig[borrowToken] = cfg;
        emit BorrowTokenConfigSet(borrowToken, cfg);
    }

    /// Users repay the borrowed USDC in USDC
    function _repayWithBorrowToken(
        address token,
        address user,
        uint256 repayDebtUsdcAmt
    ) internal {
        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            _convertFromSixDecimals(token, repayDebtUsdcAmt)
        );

        _userBorrowings[user][token] -= repayDebtUsdcAmt;
        _borrowTokenConfig[token].totalBorrowingAmount -= repayDebtUsdcAmt;

        emit Repaid(user, msg.sender, token, repayDebtUsdcAmt);
    }

    function _getCollateralTokensForDebtAmount(
        address user,
        uint256 repayDebtUsdcAmt,
        address[] memory collateralTokenPreference
    ) internal view returns (LiquidationTokenData[] memory, uint256 remainingDebt) {
        uint256 len = collateralTokenPreference.length;
        LiquidationTokenData[] memory collateral = new LiquidationTokenData[](len);

        for (uint256 i = 0; i < len; ) {
            address collateralToken = collateralTokenPreference[i];
            uint256 collateralAmountForDebt = convertUsdcToCollateralToken(
                collateralToken,
                repayDebtUsdcAmt
            );
            uint256 totalCollateral = _userCollateral[user][collateralToken];
            uint256 maxBonus = (
                totalCollateral * 
                _collateralTokenConfig[collateralToken].liquidationBonus
            ) / HUNDRED_PERCENT;

            if (
                totalCollateral - maxBonus < collateralAmountForDebt
            ) {
                uint256 liquidationBonus = maxBonus;
                collateral[i] = LiquidationTokenData({
                    token: collateralToken,
                    amount: totalCollateral, 
                    liquidationBonus: liquidationBonus
                });

                uint256 usdcValueOfCollateral = convertCollateralTokenToUsdc(
                    collateralToken,
                    totalCollateral - liquidationBonus
                );

                repayDebtUsdcAmt -= usdcValueOfCollateral;
            } else {
                uint256 liquidationBonus = 
                    (collateralAmountForDebt * _collateralTokenConfig[collateralToken].liquidationBonus) / HUNDRED_PERCENT;

                collateral[i] = LiquidationTokenData({
                    token: collateralToken,
                    amount: collateralAmountForDebt + liquidationBonus,
                    liquidationBonus: liquidationBonus
                });

                repayDebtUsdcAmt = 0;
            }

            if (repayDebtUsdcAmt == 0) {
                uint256 arrLen = i + 1;
                assembly {
                    mstore(collateral, arrLen)
                }

                break;
            }

            unchecked {
                ++i;
            }
        }

        return (collateral, repayDebtUsdcAmt);
    }

    function _supportCollateralToken(address token) internal {
        if (token == address(0)) revert InvalidValue();

        if (_collateralTokenIndexPlusOne[token] != 0)
            revert AlreadyCollateralToken();

        uint256 price = IPriceProvider(_cashDataProvider.priceProvider()).price(
            token
        );
        if (price == 0) revert OraclePriceZero();

        _supportedCollateralTokens.push(token);
        _collateralTokenIndexPlusOne[token] = _supportedCollateralTokens.length;

        emit CollateralTokenAdded(token);
    }

    function _supportBorrowToken(address token) internal {
        if (token == address(0)) revert InvalidValue();

        if (_borrowTokenIndexPlusOne[token] != 0) revert AlreadyBorrowToken();

        _supportedBorrowTokens.push(token);
        _borrowTokenIndexPlusOne[token] = _supportedBorrowTokens.length;

        emit BorrowTokenAdded(token);
    }

    function _setBorrowApy(address token, uint64 apy) internal {
        if (apy == 0) revert InvalidValue();
        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();

        _updateBorrowings(address(0));
        emit BorrowApySet(token, _borrowTokenConfig[token].borrowApy, apy);
        _borrowTokenConfig[token].borrowApy = apy;
    }

    function _setMinBorrowTokenSharesToMint(
        address token,
        uint128 shares
    ) internal {
        if (shares == 0) revert InvalidValue();
        if (!isBorrowToken(token)) revert UnsupportedBorrowToken();

        _updateBorrowings(address(0));
        emit MinSharesOfBorrowTokenToMintSet(
            token,
            _borrowTokenConfig[token].minSharesToMint,
            shares
        );
        _borrowTokenConfig[token].minSharesToMint = shares;
    }

    function _getAmountWithInterest(
        address borrowToken,
        uint256 amountBefore,
        uint256 accInterestAlreadyAdded
    ) internal view returns (uint256) {
        return
            ((PRECISION *
                (amountBefore *
                    (debtInterestIndexSnapshot(borrowToken) -
                        accInterestAlreadyAdded))) /
                HUNDRED_PERCENT +
                PRECISION *
                amountBefore) / PRECISION;
    }

    function _getTotalBorrowTokenAmount(
        address borrowToken
    ) internal view returns (uint256) {
        return
            totalBorrowingAmount(borrowToken) +
            IERC20(borrowToken).balanceOf(address(this));
    }

    function _updateBorrowings(address user) internal {
        uint256 len = _supportedBorrowTokens.length;
        for (uint256 i = 0; i < len; ) {
            _updateBorrowings(user, _supportedBorrowTokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _updateBorrowings(address user, address borrowToken) internal {
        uint256 totalBorrowingAmtBeforeInterest = _borrowTokenConfig[
            borrowToken
        ].totalBorrowingAmount;

        _borrowTokenConfig[borrowToken]
            .interestIndexSnapshot = debtInterestIndexSnapshot(borrowToken);
        _borrowTokenConfig[borrowToken]
            .totalBorrowingAmount = totalBorrowingAmount(borrowToken);
        _borrowTokenConfig[borrowToken].lastUpdateTimestamp = uint64(
            block.timestamp
        );

        if (
            totalBorrowingAmtBeforeInterest !=
            _borrowTokenConfig[borrowToken].totalBorrowingAmount
        )
            emit TotalBorrowingUpdated(
                borrowToken,
                totalBorrowingAmtBeforeInterest,
                _borrowTokenConfig[borrowToken].totalBorrowingAmount
            );

        if (user != address(0)) {
            uint256 userBorrowingsBefore = _userBorrowings[user][borrowToken];
            _userBorrowings[user][borrowToken] = borrowingOf(user, borrowToken);
            _usersDebtInterestIndexSnapshots[user][
                borrowToken
            ] = _borrowTokenConfig[borrowToken].interestIndexSnapshot;

            if (userBorrowingsBefore != _userBorrowings[user][borrowToken])
                emit UserInterestAdded(
                    user,
                    userBorrowingsBefore,
                    _userBorrowings[user][borrowToken]
                );
        }
    }

    function _getDecimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    function _convertToSixDecimals(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        uint8 tokenDecimals = _getDecimals(token);
        return
            tokenDecimals == 6
                ? amount
                : amount.mulDiv(SIX_DECIMALS, 10 ** tokenDecimals, Math.Rounding.Ceil);
    }

    function _convertFromSixDecimals(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        uint8 tokenDecimals = _getDecimals(token);
        return
            tokenDecimals == 6
                ? amount
                : amount.mulDiv(10 ** tokenDecimals, SIX_DECIMALS, Math.Rounding.Floor);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
