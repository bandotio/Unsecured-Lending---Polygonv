//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "hardhat/console.sol";

library Types {
    // Decimals adjusted for MATIC/USD pair on Chainlink
    uint8 constant DECIMALS = 8;
    /// The representation of the number one as a precise number as 10^12
    uint256 constant ONE = 10**DECIMALS;
    uint256 constant ONE_PERCENTAGE = ONE / 100;

    uint256 constant ONE_YEAR = 365 days;
    uint256 constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 50 * ONE_PERCENTAGE; // 50%
    uint256 constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = ONE;

    // @audit-issue causes non-zero interest calculation even when no borrowers present
    // Possible solution: set to 0 at deployment. Original commented below:
    uint256 constant BASE_LIQUIDITY_RATE = 0 * ONE_PERCENTAGE; // 10% 
    // uint256 constant BASE_LIQUIDITY_RATE = 10 * ONE_PERCENTAGE; // 10% 

    uint256 constant BASE_BORROW_RATE = 18 * ONE_PERCENTAGE; // 18%
    uint256 constant BASE_LIQUIDITY_INDEX = ONE; // 1
    uint256 constant BASE_BORROW_INDEX = ONE; // 1

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
        uint256 borrowIndex;
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
            decimals: DECIMALS,
            liquidityIndex: BASE_LIQUIDITY_INDEX,
            lastUpdatedTimestamp: 0,
            borrowIndex: BASE_BORROW_INDEX
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
        uint256 lastUpdatedTimestamp;
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
        require(amount <= sToken.balanceOf(user), "amount > balanceOf(user)");

        if (debtToken.balanceOf(user) == 0) return true;
        if (vars.liquidityThreshold == 0) return true;

        // @audit-info unitPrice is redundant  as of now
        AggregatorV3Interface oracle = AggregatorV3Interface(vars.oraclePriceAddress);
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        uint256 totalCollateralInUsd = unitPrice * sToken.balanceOf(user) / Types.ONE;
        uint256 totalDebtInUsd = unitPrice * debtToken.balanceOf(user) / Types.ONE;
        uint256 amountToDecreaseInUsd = unitPrice * amount / Types.ONE;
        uint256 collateralBalanceAfterDecreaseInUsd = totalCollateralInUsd - amountToDecreaseInUsd;

        if (collateralBalanceAfterDecreaseInUsd == 0) return false;

        // @audit-info -up different from AAVE's implementation but works for values tested
        uint256 liquidityThresholdAfterDecrease = totalCollateralInUsd * vars.liquidityThreshold / collateralBalanceAfterDecreaseInUsd;
        // ORIGINAL
        // uint256 liquidityThresholdAfterDecrease = (totalCollateralInUsd * vars.liquidityThreshold - 
        //     (amountToDecreaseInUsd * vars.liquidityThreshold)) / collateralBalanceAfterDecreaseInUsd;
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
   * @param userCollateralBalance The collateral balance for MATIC of the user being liquidated
   * // TODO correct NatSpec for return 
   * return (uint, uint) collateralAmount: The maximum amount that is possible to liquidate given all the liquidation constraints
   *                           (user balance, close factor)
   *         debtAmountNeeded: The amount to repay with the liquidation
    **/
    function calculateAvailableCollateralToLiquidate(
        ReserveData memory vars,
        uint256 debtToCover, 
        uint256 userCollateralBalance
    ) public pure returns(
        uint256 collateralAmount, 
        uint256 debtAmountNeeded
    ) {
        // AggregatorV3Interface oracle = AggregatorV3Interface(vars.oraclePriceAddress);
        // (, int256 result, , , ) = oracle.latestRoundData();
        // uint256 unitPrice = uint256(result);
        // @audit-info no accompanied decimal data
        uint256 debtAssetPrice = 1;

        // @note in the rust contracts, debtToCover is in USD while userCollateralBalance is in tokens
        uint256 maxAmountCollateralToLiquidate = debtAssetPrice * debtToCover * vars.liquidityBonus; // / unitPrice;
        if (maxAmountCollateralToLiquidate > userCollateralBalance) {
            collateralAmount = userCollateralBalance;
            debtAmountNeeded = userCollateralBalance * Types.ONE / debtAssetPrice / vars.liquidityBonus;
        } else {
            collateralAmount = maxAmountCollateralToLiquidate;
            debtAmountNeeded = debtToCover;
        }
    }

   /**
   * @dev Calculates the interest rates depending on the reserve's state and configurations
   * @param reserve The address of the reserve
   * @param vars The interest rate data
   * @param liquidityAdded The liquidity added during the operation
   * @param liquidityTaken The liquidity taken during the operation
   * @param borrowRate The borrow rate
   * @return The liquidity rate, the stable borrow rate and the variable borrow rate
    **/
    function calculateInterestRates(
        ReserveData memory reserve,
        InterestRateData memory vars,
        uint256 liquidityAdded,
        uint256 liquidityTaken,
        uint256 borrowRate
    ) public view returns(uint256, uint256, uint256) {
        uint256 totalCollateral = IERC20(reserve.sTokenAddress).totalSupply();
        uint256 totalDebt = IERC20(reserve.debtTokenAddress).totalSupply();

        console.log(totalCollateral, liquidityAdded, liquidityTaken);
        uint256 currentAvailableLiqudity = totalCollateral + liquidityAdded - liquidityTaken;
        uint256 currentLiquidityRate = reserve.liquidityRate;
        
        (uint256 utilizationRate, uint256 currentBorrowRate) = calculateUtilizationAndBorrowRate(
            reserve,
            vars,
            totalDebt,
            currentAvailableLiqudity
        );
        
        currentLiquidityRate = borrowRate  * utilizationRate / ONE;
    
        return (currentLiquidityRate, currentBorrowRate, utilizationRate);
    }

    // for use with only calculateInterestRates. seperated due to Solidity's 
    // restrictions on number of local vars
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
            utilizationRate = totalDebt * ONE / (currentAvailableLiqudity + totalDebt);
        }
        // @follow-up 
        if (utilizationRate > vars.optimalUtilizationRate) {
            uint256 excessUtilizationRateRatio = utilizationRate - vars.optimalUtilizationRate / vars.excessUtilizationRate;
            currentBorrowRate = reserve.borrowRate + vars.rateSlope1 + vars.rateSlope2 * excessUtilizationRateRatio;
        } else {
            currentBorrowRate = reserve.borrowRate + vars.rateSlope1 * (utilizationRate/ vars.optimalUtilizationRate);
        }
    }
} 