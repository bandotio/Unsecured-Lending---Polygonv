//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library Types {
    /// The representation of the number one as a precise number as 10^12
    uint128 constant ONE = 10**12;
    uint128 constant ONE_PERCENTAGE = 10**10;

    uint128 constant ONE_YEAR = 365*24*60*60*60*1000; // year in millisecond
    uint128 constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 50 * ONE_PERCENTAGE; // 50%
    uint128 constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = ONE;

    uint128 constant BASE_LIQUIDITY_RATE = 10 * ONE_PERCENTAGE; // 10% 
    uint128 constant BASE_BORROW_RATE = 18 * ONE_PERCENTAGE; // 18%
    uint128 constant BASE_LIQUIDITY_INDEX = ONE; // 1

    struct ReserveData {
        uint128 liquidityRate;
        uint128 borrowRate;
        address sTokenAddress;
        address debtTokenAddress;
        address oraclePriceAddress;
        uint128 ltv;
        uint128 liquidityThreshold;
        uint128 liquidityBonus;
        uint128 decimals;
        uint128 liquidityIndex;
        uint64 lastUpdatedTimestamp;
    }
    
    function newReserveData(
        address _sTokenAddress,
        address _debtTokenAddress,
        address _oraclePriceAddress,
        uint128 _ltv,
        uint128 _liquidityThreshold,
        uint128 _liquidityBonus
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
        uint128 optimalUtilizationRate;
        uint128 excessUtilizationRate;
        uint128 rateSlope1;
        uint128 rateSlope2;
        uint128 utilizationRate;
    }
    
    function newInterestRateData(
        uint128 _optimalUtilization,
        uint128 _rateSlope1,
        uint128 _rateSlope2
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
        uint128 cumulatedLiquidityInterest;
        uint128 cumulatedBorrowInterest;
        uint64 lastUpdateTimestamp;
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

    function balanceDecreaseAllowed(
        ReserveData memory vars, 
        address user,
        uint256 amount
    ) public view returns(bool) {
        IERC20 debtToken = IERC20(vars.debtTokenAddress);
        IERC20 sToken = IERC20(vars.sTokenAddress);
        if (debtToken.balanceOf(user) == 0) return true;
        if (vars.liquidityThreshold == 0) return true;

        // TODO add oracle
        uint256 unitPrice = 1; // TEMPORARY
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
} 