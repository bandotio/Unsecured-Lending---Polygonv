//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
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
        address DebtToken,
        address oraclePriceAddress,
        uint256 ltv,
        uint256 liquidityThreshold,
        uint256 liquidityBonus,
        uint256 optimalUtilizationRate,
        uint256 rateSlope1, uint256 rateSlope2
    ) {
        reserve = Types.newReserveData(
            _sToken, 
            DebtToken, 
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

        debtToken = IERC20(DebtToken);
        sToken = IERC20(_sToken);
    }

    //when the contract init, the reserve.lastUpdateTimestamp is 0, so need
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

        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "Failed to send Ether");
        emit Withdraw(sender, receiver, amount);
    }

    /**
    * @dev Allows users to borrow a specific `amount` of the reserve underlying asset, provided that the borrower
    * was given enough allowance by a credit delegator on the
    * corresponding debt token
    * - E.g. User borrows 100 DOT passing as `onBehalfOf` his own address, receiving the 100 DOT in his wallet
    *   and 100 debt tokens
    * @param amount The amount to be borrowed
    * @param onBehalfOf Address of the user who will receive the debt. Should be the address of the borrower itself
    * calling the function if he wants to borrow against his own collateral, or the address of the credit delegator
    * if he has been given credit delegation allowance
    **/ 
    function borrow(uint256 amount, address onBehalfOf) public {
        require(amount != 0, "Invalid amount");

        paratest = amount;
        address sender = msg.sender;
        address receiver = onBehalfOf;

        uint256 creditBalance = delegateAllowance[receiver][sender];
        require(
            amount <= creditBalance, 
            "Not enough available user balance"
        );       
        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) /Types.ONE * sToken.balanceOf(receiver)/Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) / Types.ONE_PERCENTAGE * debtToken.balanceOf(receiver)/Types.ONE;
        Types.UserReserveData memory reserveData = usersData[receiver];
        require(reserveData.lastUpdateTimestamp > 0, "user config does not exist");
        if (interest > 0) {
            reserveData.cumulatedLiquidityInterest += interest;
            reserveData.cumulatedBorrowInterest += debtInterest;
        }        
        uint256 _creditBalance = sToken.balanceOf(receiver) /Types.ONE - debtToken.balanceOf(receiver)/Types.ONE + reserveData.cumulatedLiquidityInterest  - reserveData.cumulatedBorrowInterest ;
        require(
            amount/ Types.ONE <= _creditBalance, 
            "Not enough available user balance"
        );
        reserveData.lastUpdateTimestamp = block.timestamp;

        delegateAllowance[receiver][sender] = creditBalance - amount;
        debtToken.mint(receiver, amount);
        borrowStatus[sender][receiver] += amount;        

        (bool sent, ) = sender.call{value: amount}("");
        require(sent, "transfer failed");

        updatePoolState(0, amount);

        emit Borrow(sender, onBehalfOf, amount);
    }

    /**
    * @notice Repays a borrowed `amount` on a specific reserve, burning the equivalent debt tokens owned
    * - E.g. User repays 100 DOT, burning 100 debt tokens of the `onBehalfOf` address
    * - Send the value in order to repay the debt for `asset`
    * @param onBehalfOf Address of the user who will get his debt reduced/removed. Should be the address of the
    * user calling the function if he wants to reduce/remove his own debt, or the address of any other
    * other borrower whose debt should be removed
    **/   
    function repay(address onBehalfOf) public payable {
        address sender = msg.sender;
        address receiver = onBehalfOf;
        uint256 amount = msg.value;
        require(amount != 0, "Invalid amount");

        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) / Types.ONE * sToken.balanceOf(receiver)/ Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) / Types.ONE_PERCENTAGE * debtToken.balanceOf(receiver)/ Types.ONE;
        Types.UserReserveData memory reserveDataSender = usersData[receiver];
        require(reserveDataSender.lastUpdateTimestamp > 0, "you have not borrowed any dot");

        if (interest > 0) {
            reserveDataSender.cumulatedLiquidityInterest += interest;
            reserveDataSender.cumulatedBorrowInterest += debtInterest;
        }
        if (amount / Types.ONE <= reserveDataSender.cumulatedBorrowInterest) {
            reserveDataSender.cumulatedBorrowInterest -= amount/Types.ONE;
            
        } else {
            uint256 rest = amount/Types.ONE - reserveDataSender.cumulatedBorrowInterest;
            reserveDataSender.cumulatedBorrowInterest = 0;
            debtToken.burn(receiver, rest*Types.ONE);
            borrowStatus[sender][receiver] -= rest;
        }
        reserveDataSender.lastUpdateTimestamp = block.timestamp;
        
        updatePoolState(amount,0);

        emit Repay(onBehalfOf, sender, amount);
    }

    /**
    optimalUtilizationRate,excessUtilizationRate,rateSlope1,rateSlope2,utilizationRate
    **/
    function getInterestRateData() public view returns(uint256, uint256, uint256, uint256, uint256) {
        return (
            interestSetting.optimalUtilizationRate, 
            interestSetting.excessUtilizationRate, 
            interestSetting.rateSlope1, 
            interestSetting.rateSlope2, 
            interestSetting.utilizationRate
        );
    } 

    /**
    * @dev delgator can delegate some their own credits which get by deposit funds to delegatee
    * @param delegatee who can borrow without collateral
    * @param amount placeholder
    */ 
    function delegate(address delegatee, uint256 amount) public {
        address delegator = msg.sender;
        delegateAllowance[delegator][delegatee] = amount;
    }

    function delegateAmount(address delegator, address delegatee) public view returns(uint256) {
        return delegateAllowance[delegator][delegatee];
    }

    // // TODO do delegateFrom
    // struct Delegator {
    //     address delegator;
    //     uint256 amount;
    // }
    // function delegateFrom(address user) public returns(address, uint256) {
    //     address delegatee = msg.sender;
    //     address delegators = vec![];
    //     for v in delegate_allowance.iter() {
    //         if v.0 .1 == delegatee {
    //             delegators.push((v.0 .0, *v.1))
    //         }
    //     }
    //     delegators
    // }

    // // TODO delegate_to
    // pub fn delegate_to(&self, user: AccountId) -> Vec<(AccountId, Balance)> {
    //     let delegator = env().caller();
    //     let mut delegatees = vec![];
    //     for v in delegate_allowance.iter() {
    //         if v.0 .0 == delegator {
    //             delegatees.push((v.0 .1, *v.1))
    //         }
    //     }
    //     delegatees
    // }

    /**
    * @dev Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
    * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
    *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
    * @param borrower The address of the borrower getting liquidated
    * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
    * @param receiveSToken `true` if the liquidators wants to receive the collateral sTokens, `false` if he wants
    * to receive the underlying collateral asset directly
    **/  
    function liquidationCall(address borrower, uint256 debtToCover, bool receiveSToken) public {
        address payable liquidator = payable(msg.sender);
        
        AggregatorV3Interface oracle = AggregatorV3Interface(reserve.oraclePriceAddress);
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);
        uint256 borrowerTotalDebtInUsd = debtToken.balanceOf(borrower) / Types.ONE* unitPrice; 
        uint256 borrowerTotalBalanceInusd = sToken.balanceOf(borrower)/ Types.ONE * unitPrice;
        uint256 healthFactor = Types.calculateHealthFactorFromBalance(borrowerTotalBalanceInusd, borrowerTotalDebtInUsd, reserve.liquidityThreshold);
        require(
            healthFactor <= Types.HEALTH_FACTOR_LIQUIDATION_THRESHOLD, 
            "LPCM Health factor not below threshold"
        );
        require(
            borrowerTotalDebtInUsd > 0, 
            "LPCM specified currency not borrowed by user"
        );
        uint256 maxLiquidatableDebt = borrowerTotalDebtInUsd * Types.LIQUIDATION_CLOSE_FACTOR_PERCENT;
        (uint256 actualDebtToLiquidate, uint256 maxCollateralToLiquidate) = calculateDebtAndCollateralToLiquidate(borrower, debtToCover, maxLiquidatableDebt);
 
        if (!receiveSToken) {
            uint256 availableDot = address(this).balance; 
            require(
                // TODO Replace DOT references with MATIC
                availableDot > maxCollateralToLiquidate, 
                "LPCM not enough liquidity to liquidate"
            );
        } 
        debtToken.burn(borrower, actualDebtToLiquidate);

        updatePoolState(actualDebtToLiquidate, 0);

        if (receiveSToken) {
            require(sToken.transferFrom(borrower, liquidator, maxCollateralToLiquidate), "transferFrom failed");                   
        } else {
            updatePoolState(0, maxCollateralToLiquidate);

            sToken.burn(borrower, maxCollateralToLiquidate);
            (bool sent, ) = liquidator.call{value: maxCollateralToLiquidate}("");
            require(sent, "transfer failed");
        }

        Types.UserReserveData memory borrowerData = usersData[borrower];
        require(borrowerData.lastUpdateTimestamp > 0, "user config does not exist");
        borrowerData.lastUpdateTimestamp = block.timestamp;
        emit Liquidation(liquidator, borrower, actualDebtToLiquidate, maxCollateralToLiquidate);
    }

    function calculateDebtAndCollateralToLiquidate(address borrower, uint256 debtToCover, uint256 maxLiquidatableDebt) internal view returns(uint256, uint256) {
        uint256 actualDebtToLiquidate;
        if (debtToCover > maxLiquidatableDebt) {
            actualDebtToLiquidate = maxLiquidatableDebt;
        } else {
            actualDebtToLiquidate = debtToCover;
        }

        (uint256 maxCollateralToLiquidate, uint256 debtAmountNeeded) = Types.calculateAvailableCollateralToLiquidate(reserve, actualDebtToLiquidate, sToken.balanceOf(borrower)/ Types.ONE);
        if (debtAmountNeeded < actualDebtToLiquidate) {
            actualDebtToLiquidate = debtAmountNeeded;
        }

        return (actualDebtToLiquidate, maxCollateralToLiquidate);
    }
    
    // //#[ink(message)]
    // pub fn is_user_reserve_healthy(&self, user: AccountId) -> uint256{
    //     let debtToken: IERC20 =  FromAccountId::from_account_id(reserve.debt_token_address);
    //     let sToken: IERC20 = FromAccountId::from_account_id(reserve.stoken_address);
    //     let mut oracle: Price = FromAccountId::from_account_id(reserve.oracle_price_address);
    //     oracle.update().expect("Failed to update price");
    //     let unitPrice = oracle.get();
    //     //if user not exist should return 0
    //     if !usersData.get(&user).is_some(){
    //         return 0;
    //     };
    //     let _total_collateral_in_usd = unitPrice * sToken.balanceOf(user)/ Types.ONE;
    //     let _totalDebt_in_usd = unitPrice * debtToken.balanceOf(user)/ Types.ONE;
    //     let healthFactor = calculateHealthFactorFromBalance(_total_collateral_in_usd, _totalDebt_in_usd, reserve.liquidityThreshold);
    //     healthFactor
    // }

    // #[ink(message)]
    // pub fn oracel_test(&self,a:u64) -> uint256{
    //     let mut oracle: Price = FromAccountId::from_account_id(reserve.oracle_price_address);
    //     //oracle.update().expect("Failed to update price");
    //     let unitPrice = oracle.get();
    //     unitPrice
    // }

    // /**
    // * Get reserve data * total market supply * available liquidity 
    // * total lending * utilization rate 
    // **/
    // #[ink(message)]
    // pub fn get_reserveData_ui(&self) -> (uint256, uint256, uint256, uint256){
    //     let debtToken: IERC20 =  FromAccountId::from_account_id(reserve.debt_token_address);
    //     let sToken: IERC20 = FromAccountId::from_account_id(reserve.stoken_address);
    //     let total_stoken: Balance = sToken.total_supply();
    //     let totalDtoken: Balance = debtToken.total_supply();
    //     let available_liquidity = total_stoken - totalDtoken;
    //     //todo
    //     let utilizationRate = totalDtoken * 1000_000_000 / total_stoken  * 100 ;
    //     (total_stoken, available_liquidity, totalDtoken, utilizationRate)
    // }

    // /**
    // * liquidity_rate * borrow_rate * ltv * liquidityThreshold
    // * liquidity_bonus * decimals * lastUpdatedTimestamp*liquidity_index
    // **/
    // #[ink(message)]
    // pub fn get_reserveData(&self) -> (uint256, uint256, uint256, uint256, uint256, uint256, u64,uint256){
    //     return (
    //         reserve.liquidity_rate, reserve.borrow_rate,
    //         reserve.ltv, reserve.liquidityThreshold, 
    //         reserve.liquidity_bonus, reserve.decimals, 
    //         reserve.lastUpdatedTimestamp,reserve.liquidity_index
    //     )
    // } 

    // /**
    // * Get user reserve data * total deposit * total borrow * deposit interest
    // * borrow interest *current timestamp 
    // **/        
    // #[ink(message)]
    // pub fn get_user_reserveData_ui(&self, user: AccountId) -> (uint256, uint256, uint256, uint256, u64) {
    //     let sToken: IERC20 = FromAccountId::from_account_id(reserve.stoken_address);
    //     let debtToken: IERC20 = FromAccountId::from_account_id(reserve.debt_token_address);
    //     //带有12个0的精度
    //     let user_stoken: Balance = sToken.balanceOf(user)/ Types.ONE;
    //     let userDtoken: Balance = debtToken.balanceOf(user)/ Types.ONE;
    //     uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) / Types.ONE * user_stoken;
    //     let debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) /ONE_PERCENTAGE * userDtoken;
    //     let data = usersData.get(&user);
    //     match data {
    //         None => return (0, 0, 0, 0, 0),
    //         Some(someData) => {
    //             let cumulatedLiquidityInterest = someData.cumulatedLiquidityInterest + interest;
    //             let cumulatedBorrowInterest = someData.cumulatedBorrowInterest + debtInterest;
    //             let current_timestamp = Self::env().block_timestamp();
    //             return (user_stoken, cumulatedLiquidityInterest, userDtoken, cumulatedBorrowInterest, current_timestamp);
    //         },
    //     }
    // }

    // //should removew the user para to protect other user privacy
    // #[ink(message)]
    // pub fn get_user_borrow_status(&self, user: AccountId)-> Vec<(AccountId,Balance)>{
    //     let sender = env().caller();
    //     let mut result = Vec::new();
    //     for ((borrower,owner),value) in borrowStatus.iter(){
    //         if *borrower == sender{
    //             result.push((*owner,*value));
    //         }
    //     }
    //     result
    // }

    // //暂不开放
    // pub fn set_reserve_configuration(&mut self, ltv: uint256, liquidityThreshold: uint256, liquidity_bonus: uint256){
    //     reserve.ltv = ltv;
    //     reserve.liquidityThreshold = liquidityThreshold;
    //     reserve.liquidity_bonus = liquidity_bonus;
    // }
    // //暂不开放
    // pub fn set_interest_rateData(
    //     &mut self, optimalUtilizationRate:uint256, 
    //     rateSlope1: uint256, rateSlope2:uint256)
    //     {
    //         interestSetting.optimalUtilizationRate = optimalUtilizationRate;
    //         interestSetting.rateSlope1 = rateSlope1;
    //         interestSetting.rateSlope2 = rateSlope2;                
    // }
    // //暂不开放
    // pub fn set_kycData(&mut self, name: Option<String>, email: Option<String>) {
    //     let user = env().caller();
    //     let entry = users_kycData.entry(user);
    //     let kycData = entry.or_insert(Default::default());
    //     if let Some(user_name) = name {
    //         kycData.name = user_name;
    //     }
    //     if let Some(user_email) = email {
    //         kycData.email = user_email;
    //     }         
    // }
    // //暂不开放
    // pub fn get_kycData(&self, user: AccountId) -> Option<UserKycData> {
    //     users_kycData.get(&user).cloned()
    // }
    // //暂不开放
    // pub fn get_the_unhelthy_reserves(&self)-> Option<Vec<AccountId>>{
    //     let debtToken: IERC20 =  FromAccountId::from_account_id(reserve.debt_token_address);
    //     let sToken: IERC20 = FromAccountId::from_account_id(reserve.stoken_address);
    //     let mut oracle: Price = FromAccountId::from_account_id(reserve.oracle_price_address);
    //     oracle.update().expect("Failed to update price");
    //     let unitPrice = oracle.get();
    //     let mut result = Vec::new();
    //     for (user, status) in users.iter(){
    //         if *status != 1 {
    //             //1表示这个用户有钱存在池子里 是我们的用户，0表示用户把所有钱都取走了，相当于不是我们的用户了
    //             continue
    //         }
    //         let _total_collateral_in_usd = unitPrice * sToken.balanceOf(*user)/ Types.ONE;
    //         let _totalDebt_in_usd = unitPrice * debtToken.balanceOf(*user)/ Types.ONE;
    //         if calculateHealthFactorFromBalance(_total_collateral_in_usd, _totalDebt_in_usd, reserve.liquidityThreshold) <HEALTH_FACTOR_LIQUIDATION_THRESHOLD {
    //             result.push(*user)
    //         }
    //     }
    //     if result.is_empty(){
    //         None
    //     }else{
    //         Some(result)
    //     }
    // } 
}
