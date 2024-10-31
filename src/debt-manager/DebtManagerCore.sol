// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DebtManagerStorage} from "./DebtManagerStorage.sol";
import {IPriceProvider} from "../interfaces/IPriceProvider.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IL2DebtManager} from "../interfaces/IL2DebtManager.sol";
import {AaveLib} from "../libraries/AaveLib.sol";

contract DebtManagerCore is DebtManagerStorage {
    using Math for uint256;
    using SafeERC20 for IERC20;

    function cashDataProvider() external view returns (address) {
        return address(_cashDataProvider);
    }

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

    function collateralTokenConfig(
        address collateralToken
    ) external view returns (CollateralTokenConfig memory) {
        return _collateralTokenConfig[collateralToken];
    }

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

    function getUserCollateralForToken(
        address user,
        address token
    ) external view returns (uint256, uint256) {
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();
        uint256 collateralTokenAmt = _userCollateral[user][token];
        uint256 collateralAmtInUsd = convertCollateralTokenToUsd(
            token,
            collateralTokenAmt
        );

        return (collateralTokenAmt, collateralAmtInUsd);
    }

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

            totalCollateralInUsd += convertCollateralTokenToUsd(
                collaterals[i].token,
                collaterals[i].amount
            );

            unchecked {
                ++i;
            }
        }

        return (collaterals, totalCollateralInUsd);
    }

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
            uint256 collateral = convertCollateralTokenToUsd(
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

            totalCollateralInUsd += convertCollateralTokenToUsd(
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

    function remainingBorrowingCapacityInUSD(
        address user
    ) public view returns (uint256) {
        uint256 maxBorrowingAmount = getMaxBorrowAmount(user, true);
        (, uint256 currentBorrowingWithInterest) = borrowingOf(user);

        return
            maxBorrowingAmount > currentBorrowingWithInterest
                ? maxBorrowingAmount - currentBorrowingWithInterest
                : 0;
    }

    function borrowApyPerSecond(
        address borrowToken
    ) external view returns (uint64) {
        return _borrowTokenConfig[borrowToken].borrowApy;
    }

    function borrowTokenMinShares(
        address borrowToken
    ) external view returns (uint128) {
        return _borrowTokenConfig[borrowToken].minShares;
    }

    function getCurrentState()
        public
        view
        returns (
            TokenData[] memory totalCollaterals,
            uint256 totalCollateralInUsd,
            TokenData[] memory borrowings,
            uint256 totalBorrowingsInUsd,
            TokenData[] memory totalLiquidCollateralAmounts,
            TokenData[] memory totalLiquidStableAmounts
        )
    {
        (totalCollaterals, totalCollateralInUsd) = totalCollateralAmounts();
        (borrowings, totalBorrowingsInUsd) = totalBorrowingAmounts();
        totalLiquidCollateralAmounts = _liquidCollateralAmounts();
        totalLiquidStableAmounts = _liquidStableAmounts();
    }

    function getUserCurrentState(address user)
        external
        view
        returns (
            TokenData[] memory totalCollaterals,
            uint256 totalCollateralInUsd,
            TokenData[] memory borrowings,
            uint256 totalBorrowings
        )
    {
        (totalCollaterals, totalCollateralInUsd) = collateralOf(user);
        (borrowings, totalBorrowings) = borrowingOf(user);
    }

    function supplierBalance(
        address supplier,
        address borrowToken
    ) public view returns (uint256) {
        if (_borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens == 0)
            return 0;

        return
            _sharesOfBorrowTokens[supplier][borrowToken].mulDiv(
                _getTotalBorrowTokenAmount(borrowToken),
                _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
                Math.Rounding.Floor
            );
    }

    function supplierBalance(
        address supplier
    ) public view returns (TokenData[] memory, uint256) {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory suppliesData = new TokenData[](len);
        uint256 amountInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            address borrowToken = _supportedBorrowTokens[i];
            uint256 amount = supplierBalance(supplier, borrowToken);
            amountInUsd += _convertToSixDecimals(borrowToken, amount);
            suppliesData[i] = TokenData({
                token: borrowToken,
                amount: amount
            });
            unchecked {
                ++i;
            }
        }

        return (suppliesData, amountInUsd);
    }

    function totalSupplies(address borrowToken) public view returns (uint256) {
        return _getTotalBorrowTokenAmount(borrowToken);
    }

    function totalSupplies() external view returns (TokenData[] memory, uint256) {
        uint256 len = _supportedBorrowTokens.length;
        TokenData[] memory suppliesData = new TokenData[](len);
        uint256 amountInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            address borrowToken = _supportedBorrowTokens[i];
            uint256 totalSupplied = totalSupplies(borrowToken);
            amountInUsd += _convertToSixDecimals(borrowToken, totalSupplied);

            suppliesData[i] = TokenData({
                token: borrowToken,
                amount: totalSupplied
            });
            unchecked {
                ++i;
            }
        }

        return (suppliesData, amountInUsd);
    }

    function convertUsdToCollateralToken(
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

    function convertCollateralTokenToUsd(
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

    function getCollateralValueInUsd(
        address user
    ) public view returns (uint256) {
        uint256 len = _supportedCollateralTokens.length;
        uint256 userCollateralInUsd = 0;

        for (uint256 i = 0; i < len; ) {
            userCollateralInUsd += convertCollateralTokenToUsd(
                _supportedCollateralTokens[i],
                _userCollateral[user][_supportedCollateralTokens[i]]
            );

            unchecked {
                ++i;
            }
        }

        return userCollateralInUsd;
    }
    function supply(
        address user,
        address borrowToken,
        uint256 amount
    ) external nonReentrant {
        if (!isBorrowToken(borrowToken)) revert UnsupportedBorrowToken();
        if (_cashDataProvider.isUserSafe(user)) revert UserSafeCannotSupplyDebtTokens();
        
        uint256 shares = _borrowTokenConfig[borrowToken]
            .totalSharesOfBorrowTokens == 0
            ? amount
            : amount.mulDiv(
                _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
                _getTotalBorrowTokenAmount(borrowToken),
                Math.Rounding.Floor
            );

        if (shares < _borrowTokenConfig[borrowToken].minShares)
            revert SharesCannotBeLessThanMinShares();

        _sharesOfBorrowTokens[user][borrowToken] += shares;
        _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens += shares;

        // Moving this before state update to prevent reentrancy
        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(msg.sender, user, borrowToken, amount);
    }
    
    function withdrawBorrowToken(address borrowToken, uint256 amount) external {
        uint256 totalBorrowTokenAmt = _getTotalBorrowTokenAmount(borrowToken);
        if (totalBorrowTokenAmt == 0) revert ZeroTotalBorrowTokens();

        uint256 shares = amount.mulDiv(
            _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens,
            totalBorrowTokenAmt,
            Math.Rounding.Ceil
        );

        if (shares == 0) revert SharesCannotBeZero();
        if (_sharesOfBorrowTokens[msg.sender][borrowToken] < shares) revert InsufficientBorrowShares();

        uint256 sharesLeft = _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens - shares;
        if (sharesLeft != 0 && sharesLeft < _borrowTokenConfig[borrowToken].minShares) revert SharesCannotBeLessThanMinShares();

        _sharesOfBorrowTokens[msg.sender][borrowToken] -= shares;
        _borrowTokenConfig[borrowToken].totalSharesOfBorrowTokens = sharesLeft;

        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit WithdrawBorrowToken(msg.sender, borrowToken, amount);
    }
    
    function depositCollateral(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant onlyUserSafe {
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();

        _totalCollateralAmounts[token] += amount;
        _userCollateral[user][token] += amount;

        if(_totalCollateralAmounts[token] > _collateralTokenConfig[token].supplyCap) 
            revert SupplyCapBreached();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit DepositedCollateral(msg.sender, user, token, amount);
    }

    function borrow(address token, uint256 amount) external onlyUserSafe {
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

    function repay(
        address user,
        address token,
        uint256 amount
    ) external nonReentrant {
        _updateBorrowings(user, token);

        uint256 repayDebtUsdcAmt = _convertToSixDecimals(token, amount);
        if (_userBorrowings[user][token] < repayDebtUsdcAmt) {
                repayDebtUsdcAmt = _userBorrowings[user][token];
                amount = _convertFromSixDecimals(token, repayDebtUsdcAmt);
        }
        if (repayDebtUsdcAmt == 0) revert RepaymentAmountIsZero();

        if (!isBorrowToken(token)) revert UnsupportedRepayToken();

        _repayWithBorrowToken(token, user, amount, repayDebtUsdcAmt);
    }

    function withdrawCollateral(address token, uint256 amount) external onlyUserSafe {
        _updateBorrowings(msg.sender);
        if (!isCollateralToken(token)) revert UnsupportedCollateralToken();

        _totalCollateralAmounts[token] -= amount;
        _userCollateral[msg.sender][token] -= amount;

        _ensureHealth(msg.sender);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit WithdrawCollateral(msg.sender, token, amount);
    }

    function closeAccount() external onlyUserSafe {
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

            _userCollateral[msg.sender][tokenData[i].token] -= tokenData[i].amount;
            _totalCollateralAmounts[tokenData[i].token] -= tokenData[i].amount;

            IERC20(tokenData[i].token).safeTransfer(msg.sender, tokenData[i].amount);
            
            unchecked {
                ++i;
            }
        }

        emit AccountClosed(msg.sender, tokenData);
    }

    // https://docs.aave.com/faq/liquidations    
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
        uint256 debtAmountToLiquidateInUsd = _userBorrowings[user][borrowToken].ceilDiv(2);
        _liquidate(user, borrowToken, collateralTokensPreference, debtAmountToLiquidateInUsd);

        if (liquidatable(user)) _liquidate(user, borrowToken, collateralTokensPreference, _userBorrowings[user][borrowToken]);
    }

    function _liquidate(
        address user,
        address borrowToken,
        address[] memory collateralTokensPreference,
        uint256 debtAmountToLiquidateInUsd
    ) internal {    
        uint256 beforeDebtAmount = _userBorrowings[user][borrowToken];
        if (debtAmountToLiquidateInUsd == 0) revert LiquidatableAmountIsZero();

        (LiquidationTokenData[] memory collateralTokensToSend, uint256 remainingDebt) = _getCollateralTokensForDebtAmount(
            user,
            debtAmountToLiquidateInUsd,
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

        uint256 liquidatedAmt = debtAmountToLiquidateInUsd - remainingDebt;
        _userBorrowings[user][borrowToken] -= liquidatedAmt;
        _borrowTokenConfig[borrowToken]
            .totalBorrowingAmount -= liquidatedAmt;

        IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), _convertFromSixDecimals(borrowToken, liquidatedAmt));

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
    function fundManagementOperation(
        uint8 marketOperationType,
        bytes calldata data
    ) external onlyRole(ADMIN_ROLE) {
        address aaveV3Adapter = _cashDataProvider.aaveAdapter();
        AaveLib.aaveOperation(aaveV3Adapter, marketOperationType, data);
    }

    /// Users repay the borrowed USDC in USDC
    function _repayWithBorrowToken(
        address token,
        address user,
        uint256 amount,
        uint256 repayDebtUsdcAmt
    ) internal {
        _userBorrowings[user][token] -= repayDebtUsdcAmt;
        _borrowTokenConfig[token].totalBorrowingAmount -= repayDebtUsdcAmt;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

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
            uint256 collateralAmountForDebt = convertUsdToCollateralToken(
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

                uint256 usdcValueOfCollateral = convertCollateralTokenToUsd(
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

    /**
     * @notice Function to fetch the liquid collateral amounts in the contract.
     * @notice Calculated as the collateral balance of the contract minus the total collateral amount in a token.
     * @return Liquid collateral amounts.
     */
    function _liquidCollateralAmounts() internal view returns (TokenData[] memory) {
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
     * @notice Function to fetch the liquid stable amounts in the contract.
     * @notice Calculated as the stable balances of the contract.
     * @return Liquid stable amounts in TokenData array format.
     */
    function _liquidStableAmounts() internal view returns (TokenData[] memory) {
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

    function _isUserSafe() internal view {
        if (!_cashDataProvider.isUserSafe(msg.sender)) revert OnlyUserSafe();
    }

    modifier onlyUserSafe() {
        _isUserSafe();
        _;
    }

    /**
     * @dev Falldown to the admin implementation
     * @notice This is a catch all for all functions not declared in core
     */
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        bytes32 slot = adminImplPosition;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(
                gas(),
                sload(slot),
                0,
                calldatasize(),
                0,
                0
            )

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }
}