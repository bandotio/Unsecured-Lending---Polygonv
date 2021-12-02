//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library Types {
    /// The representation of the number one as a precise number as 10^12
    uint256 constant ONE = 10**12;
    uint256 constant ONE_PERCENTAGE = 10**10;

    uint256 constant ONE_YEAR = 365*24*60*60*1000; // year in milliseconds
    uint256 constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 50 * ONE_PERCENTAGE; // 50%
    uint256 constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = ONE;

    uint256 constant BASE_LIQUIDITY_RATE = 10 * ONE_PERCENTAGE; // 10% 
    uint256 constant BASE_BORROW_RATE = 18 * ONE_PERCENTAGE; // 18%
    uint256 constant BASE_LIQUIDITY_INDEX = ONE; // 1

    struct ReserveData {
        uint256 liquidityRate;
        uint256 borrowRate;
        address sTokenAddress;
        address debtTokenAddress;
        address oraclePriceAddress;
        uint256 ltv;
        uint256 liquidityThreshold;
        uint256 liquidityBonus;
        uint256 decimals;
        uint256 liquidityIndex;
        uint256 lastUpdatedTimestamp;
    }
    
    function newReserveData(
        address _sTokenAddress,
        address _debtTokenAddress,
        address _oraclePriceAddress,
        uint256 _ltv,
        uint256 _liquidityThreshold,
        uint256 _liquidityBonus
    ) public pure returns(ReserveData memory) {
        return ReserveData({
            liquidityRate: BASE_LIQUIDITY_RATE,
            borrowRate: BASE_BORROW_RATE,
            sTokenAddress: _sTokenAddress,
            debtTokenAddress: _debtTokenAddress,
            oraclePriceAddress: _oraclePriceAddress,
            ltv: _ltv * ONE_PERCENTAGE,
            liquidityThreshold: _liquidityThreshold * ONE_PERCENTAGE,
            liquidityBonus:_liquidityBonus * ONE_PERCENTAGE,
            decimals: 12,
            liquidityIndex: BASE_LIQUIDITY_INDEX,
            lastUpdatedTimestamp: 0
        });
    }

    struct InterestRateData {
        uint256 optimalUtilizationRate;
        uint256 excessUtilizationRate;
        uint256 rateSlope1;
        uint256 rateSlope2;
        uint256 utilizationRate;
    }
    
    function newInterestRateData(
        uint256 _optimalUtilization,
        uint256 _rateSlope1,
        uint256 _rateSlope2
    ) public pure returns(InterestRateData memory) {
        return InterestRateData({
            optimalUtilizationRate: _optimalUtilization * ONE_PERCENTAGE,
            excessUtilizationRate: ONE -  _optimalUtilization * ONE_PERCENTAGE,
            rateSlope1: _rateSlope1 * ONE_PERCENTAGE,
            rateSlope2: _rateSlope2 * ONE_PERCENTAGE,
            utilizationRate: 0
        });
    }

    struct UserReserveData {
        uint256 cumulatedLiquidityInterest;
        uint256 cumulatedBorrowInterest;
        uint256 lastUpdateTimestamp;
    }

    struct UserKycData {
        string name;
        string email;
    }

    function calculateHealthFactorFromBalance(
        uint256 totalCollateralInUsd, 
        uint256 totalDebtInUsd, 
        uint256 liquidationThreshold
    ) public pure returns(uint256) {
        if (totalDebtInUsd == 0) return 0;
        return totalCollateralInUsd * liquidationThreshold / totalDebtInUsd;
    }

    /**
    * @dev Checks if a specific balance decrease is allowed
    * (i.e. doesn't bring the user borrow position health factor under HEALTH_FACTOR_LIQUIDATION_THRESHOLD)
    * @param vars The data of all the reserves
    * @param user The address of the user
    * @param amount The amount to decrease
    * @return true if the decrease of the balance is allowed
    **/
    function balanceDecreaseAllowed(
        ReserveData memory vars, 
        address user,
        uint256 amount
    ) public view returns(bool) {
        IERC20 debtToken = IERC20(vars.debtTokenAddress);
        IERC20 sToken = IERC20(vars.sTokenAddress);
        if (debtToken.balanceOf(user) == 0) return true;
        if (vars.liquidityThreshold == 0) return true;

        AggregatorV3Interface oracle = AggregatorV3Interface(vars.oraclePriceAddress);
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        uint256 totalCollateralInUsd = unitPrice * sToken.balanceOf(user);
        uint256 totalDebtInUsd = unitPrice * debtToken.balanceOf(user);
        uint256 amountToDecreaseInUsd = unitPrice * amount;
        uint256 collateralBalanceAfterDecreaseInUsd = totalCollateralInUsd - amountToDecreaseInUsd;

        if (collateralBalanceAfterDecreaseInUsd == 0) return false;

        uint256 liquidityThresholdAfterDecrease = totalCollateralInUsd * vars.liquidityThreshold - 
            (amountToDecreaseInUsd * vars.liquidityThreshold) / collateralBalanceAfterDecreaseInUsd;
        uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalance(
            collateralBalanceAfterDecreaseInUsd,
            totalDebtInUsd,
            liquidityThresholdAfterDecrease
        );

        return healthFactorAfterDecrease >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    /**
   * @dev Calculates how much of a specific collateral can be liquidated, given
   * a certain amount of debt asset.
   * - This function needs to be called after all the checks to validate the liquidation have been performed,
   *   otherwise it might fail.
   * @param vars The data of the collateral reserve
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param userCollateralBalance The collateral balance for DOT of the user being liquidated
   * @return collateral_amount: The maximum amount that is possible to liquidate given all the liquidation constraints
   *                           (user balance, close factor)
   *         debt_amount_needed: The amount to repay with the liquidation
    **/
    function calculateAvailableCollateralToLiquidate(
        ReserveData memory vars,
        uint256 debtToCover, 
        uint256 userCollateralBalance
    ) public view returns(uint256, uint256) {
        uint256 collateralAmount; 
        uint256 debtAmountNeeded;

        AggregatorV3Interface oracle = AggregatorV3Interface(vars.oraclePriceAddress);
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        uint256 debtAssetPrice = 1;

        uint256 maxAmountCollateralToLiquidate = debtAssetPrice * debtToCover * vars.liquidityBonus / unitPrice;
        if (maxAmountCollateralToLiquidate > userCollateralBalance) {
            collateralAmount = userCollateralBalance;
            debtAmountNeeded = unitPrice * userCollateralBalance / debtAssetPrice / vars.liquidityBonus;
        } else {
            collateralAmount = maxAmountCollateralToLiquidate;
            debtAmountNeeded = debtToCover;
        }
        return (collateralAmount, debtAmountNeeded);
    }

    /**
   * @dev Calculates the interest rates depending on the reserve's state and configurations
   * @param reserve The address of the reserve
   * @param vars The interest rate data
   * @param liquidityAdded The liquidity added during the operation
   * @param liquidityTaken The liquidity taken during the operation
   * @param totalDebt The total borrowed from the reserve
   * @param borrowRate The borrow rate
   * @return The liquidity rate, the stable borrow rate and the variable borrow rate
**/
    function calculateInterestRates(
        ReserveData memory reserve,
        InterestRateData memory vars,
        uint256 liquidityAdded,
        uint256 liquidityTaken,
        uint256 totalDebt,
        uint256 borrowRate
    ) public view returns(uint256, uint256, uint256) {
        IERC20 sToken = IERC20(reserve.sTokenAddress);
        uint256 currentAvailableLiqudity = sToken.totalSupply() + liquidityAdded - liquidityTaken;
        uint256 currentLiquidityRate = reserve.liquidityRate;
        
        (uint256 utilizationRate, uint256 currentBorrowRate) = calculateUtilizationAndBorrowRate(
            reserve,
            vars,
            totalDebt,
            currentAvailableLiqudity
        );
        
        if (totalDebt != 0) {
            currentLiquidityRate = borrowRate  * utilizationRate;
        }
        else {
            currentLiquidityRate = 0;
        }
        return (currentLiquidityRate / 10**12, currentBorrowRate, utilizationRate);
    }

    function calculateUtilizationAndBorrowRate(
        ReserveData memory reserve,
        InterestRateData memory vars,
        uint256 totalDebt,
        uint256 currentAvailableLiqudity    
    ) internal pure returns(
        uint256 utilizationRate, 
        uint256 currentBorrowRate
    ) {
        if (totalDebt == 0) {
            utilizationRate = 0;
        } else {
            utilizationRate = (totalDebt * 10**12 + (currentAvailableLiqudity + totalDebt) /2) / (currentAvailableLiqudity + totalDebt);
        }
        if (utilizationRate > vars.optimalUtilizationRate) {
            uint256 excessUtilizationRateRatio = utilizationRate - vars.optimalUtilizationRate / vars.excessUtilizationRate;
            currentBorrowRate = reserve.borrowRate + vars.rateSlope1 + vars.rateSlope2 * excessUtilizationRateRatio;
        } else {
            currentBorrowRate = reserve.borrowRate + vars.rateSlope1 * (utilizationRate/ vars.optimalUtilizationRate);
        }
    }
} 