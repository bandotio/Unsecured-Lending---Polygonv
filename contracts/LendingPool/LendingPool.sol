//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";
import {Types} from "./Types.sol";

contract LendingPool {
    using Types for *;
    
    /**
     * @dev Emitted on Deposit()
     * @param user The address initiating the deposit
     * @param onBehalfOf The beneficiary of the deposit, receiving the sTokens
     * @param amount The amount deposited
     **/
    event Deposit(address indexed user, address onBehalfOf, uint256 amount);
    /**
     * @dev Emitted on Withdraw()
     * @param user The address initiating the withdrawal, owner of sTokens
     * @param to Address that will receive the underlying
     * @param amount The amount to be withdrawn
     **/
    event Withdraw(address user, address to, uint256 amount);
    /**
     * @dev Emitted on Borrow() when debt needs to be opened
     * @param user The address of the user initiating the borrow(), receiving the funds on borrow()
     * @param onBehalfOf The address that will be getting the debt
     * @param amount The amount borrowed out
     **/ 
     event Borrow(address user, address onBehalfOf, uint256 amount);
     /**
     * @dev Emitted on Repay()
     * @param receiver The beneficiary of the repayment, getting his debt reduced
     * @param repayer The address of the user initiating the repay(), providing the funds
     * @param amount The amount repaid
     **/ 
     event Repay(address receiver, address repayer, uint256 amount);
     /**
     * @dev emitted on Delegate()
     * @param delegator  who have money and allow delegatee use it as collateral
     * @param delegatee who can borrow money from pool without collateral
     * @param amount the amount
     **/ 
     event Delegate(address delegator, address delegatee, uint256 amount);
     /**
     * @dev emitted on Liquidation() when a borrower is liquidated.
     * @param liquidator The address of the liquidator
     * @param liquidatee The address of the borrower getting liquidated
     * @param amountToRecover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receivedAmount The amount of collateral received by the liiquidator     
     **/
     event Liquidation(address liquidator, address liquidatee, uint256 amountToRecover, uint256 receivedAmount);

    Types.ReserveData public reserve;
    mapping(address => Types.UserReserveData) public usersData;
    mapping(address => mapping(address => uint256)) public delegateAllowance;
    mapping(address => Types.UserKycData) usersKycData;
    Types.InterestRateData public interestSetting;
    mapping(address => bool) users;
    mapping(address=>mapping(address => uint256)) public borrowStatus;
    uint256 public paratest;

    IERC20 sToken;
    IERC20 debtToken;

    constructor(
        address _sToken,
        address _debtToken,
        address oraclePriceAddress,
        uint256 ltv,
        uint256 liquidityThreshold,
        uint256 liquidityBonus,
        uint256 optimalUtilizationRate,
        uint256 rateSlope1, uint256 rateSlope2
    ) {
        reserve = Types.newReserveData(
            _sToken, 
            _debtToken, 
            oraclePriceAddress, 
            ltv, 
            liquidityThreshold, 
            liquidityBonus
        );
        interestSetting = Types.newInterestRateData(
            optimalUtilizationRate, 
            rateSlope1, 
            rateSlope2
        );

        debtToken = IERC20(_debtToken);
        sToken = IERC20(_sToken);
    }

    //when the contract init, the reserve.last_update_timestamp is 0, so need
    //test only
    function updateTimestampWhenInit() public {
        reserve.lastUpdatedTimestamp = block.timestamp;
    }

    //test only
    function setTimestampForTest(uint256 time) public {
        reserve.lastUpdatedTimestamp = time;
    }

    /**
    * @dev Deposits an `amount` of underlying asset into the reserve, receiving in return overlying sTokens.
    * - E.g. User deposits 100 MATIC and gets in return 100 sMATIC
    * @param onBehalfOf The address that will receive the sTokens, same as msg.sender if the user
    *   wants to receive them on his own wallet, or a different address if the beneficiary of sTokens
    *   is a different wallet
    **/
    function deposit(address onBehalfOf) public payable {
        address sender = msg.sender;
        address receiver = sender;
        if (onBehalfOf != address(0))
            receiver = onBehalfOf;
        
        uint256 amount = msg.value;
        require(amount != 0, "Invalid amount sent");

        updatePoolState(amount, 0);

        Types.UserReserveData memory userReserveData;
        // Replicating or_insert using lastUpdateTimestamp as proof of init
        if (usersData[receiver].lastUpdateTimestamp != 0)
            userReserveData = usersData[receiver];
        userReserveData.lastUpdateTimestamp = block.timestamp;
        sToken.mint(receiver, amount);
        users[receiver] = true;

        emit Deposit(sender, receiver, amount);
    }

    function getBlockTimestamp() public view returns(uint256) {
        return block.timestamp;
    }

    function getNormalizedIncome(uint256 timestamp) public view returns(uint256) {
        if (timestamp == block.timestamp)
            return reserve.liquidityIndex;
        return calculateLinearInterest(timestamp) * reserve.liquidityIndex / Types.ONE;
    }

    function getNormalizedDebt(uint256 timestamp) public view returns(uint256) {    
        if (timestamp == block.timestamp)
            return 0;
        uint256 stableBorrowRate = reserve.borrowRate;
        return calculateCompoundedInterest(stableBorrowRate,timestamp);
    }

    function calculateLinearInterest(uint256 lastUpdatedTimestamp) public view returns(uint256) {
        uint256 timeDifference = block.timestamp - lastUpdatedTimestamp;
        return reserve.liquidityRate / Types.ONE_YEAR * timeDifference + Types.ONE;
    }

    function calculateCompoundedInterest(uint256 rate, uint256 lastUpdateTimestamp) public view returns(uint256) {
        uint256 timeDifference = block.timestamp - lastUpdateTimestamp;
        if (timeDifference == 0) 
            return 0;
        uint256 timeDifferenceMinusOne = timeDifference - 1;
        uint256 timeDifferenceMinusTwo;
        if (timeDifference > 2) {
            timeDifferenceMinusTwo = timeDifference - 2;
        } else {
            timeDifferenceMinusTwo = 0;
        }

        uint256 ratePerSecond = rate / Types.ONE_YEAR;
        uint256 basePowerTwo = ratePerSecond**2 ;
        uint256 basePowerThree = ratePerSecond**3;
        uint256 secondTerm = timeDifference * timeDifferenceMinusOne * basePowerTwo / (Types.ONE_YEAR * 2);
        uint256 thirdTerm = timeDifference * timeDifferenceMinusOne * timeDifferenceMinusTwo * basePowerThree / (Types.ONE_PERCENTAGE**2 * 6);
        return ratePerSecond * timeDifference + secondTerm + thirdTerm;
    }

    function updatePoolState(uint256 liquidityAdded, uint256 liquidityTaken) internal {
        uint256 currentLiquidityRate = reserve.liquidityRate;
        uint256 cumulatedLiquidityInterest = 0;
        if (currentLiquidityRate > 0) {
            cumulatedLiquidityInterest = calculateLinearInterest(reserve.lastUpdatedTimestamp);
        }
        uint256 totalDebt = debtToken.totalSupply();
        (
            uint256 newLiquidityRate, 
            uint256 newBorrowRate, 
            uint256 utilizationRate
        ) = Types.calculateInterestRates(
            reserve, 
            interestSetting, 
            liquidityAdded, 
            liquidityTaken, 
            totalDebt, 
            reserve.borrowRate
        );

        reserve.liquidityIndex = Types.ONE;
        reserve.lastUpdatedTimestamp = block.timestamp;
        reserve.liquidityRate = newLiquidityRate;
        reserve.borrowRate = newBorrowRate;
        interestSetting.utilizationRate = utilizationRate;
    }

    function getNewReserveRates(uint256 liquidityAdded, uint256 liquidityTaken) public view returns(uint256, uint256, uint256) {
        uint256 totalDebt = debtToken.totalSupply();
        return Types.calculateInterestRates(reserve, interestSetting, liquidityAdded, liquidityTaken, totalDebt, reserve.borrowRate);
    }

    /**
    * @dev Withdraws an `amount` of underlying asset from the reserve, burning the equivalent sTokens owned
    * E.g. User has 100 sMATIC, calls withdraw() and receives 100 MATIC, burning the 100 sMATIC
    * @param amount The underlying amount to be withdrawn
    *   - Send the value in order to withdraw the whole sToken balance
    * @param to Address that will receive the underlying, same as msg.sender if the user
    *   wants to receive it on his own wallet, or a different address if the beneficiary is a
    *   different wallet
    **/
    function withdraw(uint256 amount, address to) public {
        require(amount != 0, "Invalid amount set");
        address sender = msg.sender;
        address payable receiver = payable(sender);
        if (to != address(0)) {
            receiver = payable(to);
        }
        
        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) /  Types.ONE * sToken.balanceOf(sender) / Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) / Types.ONE_PERCENTAGE * debtToken.balanceOf(sender) / Types.ONE;
        Types.UserReserveData memory reserveData = usersData[sender];
        require(reserveData.lastUpdateTimestamp > 0, "user config does not exist");

        if (interest > 0) {
            reserveData.cumulatedLiquidityInterest += interest;
            reserveData.cumulatedBorrowInterest += debtInterest;
        }
        uint256 availableUserBalance = sToken.balanceOf(sender) / Types.ONE  - debtToken.balanceOf(sender) / Types.ONE  + reserveData.cumulatedLiquidityInterest + reserveData.cumulatedBorrowInterest;
        require(
            amount / Types.ONE <= availableUserBalance,
            "Not enough available user balance"
        );

        if (amount / Types.ONE <= reserveData.cumulatedLiquidityInterest) {
            reserveData.cumulatedLiquidityInterest -= amount / Types.ONE;
        } else {
            uint256 rest = amount / Types.ONE - reserveData.cumulatedLiquidityInterest;
            reserveData.cumulatedLiquidityInterest = 0;
            // TODO check if this burn will be error free
            sToken.burn(sender, rest*Types.ONE); //.expect("sToken burn failed");
        }
        reserveData.lastUpdateTimestamp = block.timestamp;

        updatePoolState(0, amount);

        receiver.transfer(amount); 
        emit Withdraw(sender, receiver, amount);
    }
}
