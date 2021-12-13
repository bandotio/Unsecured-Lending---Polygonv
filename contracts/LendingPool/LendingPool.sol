//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../ERC20/ERC20Blacklistable.sol";
// import "../ERC20/IERC20.sol";
import {Types} from "./Types.sol";

import "hardhat/console.sol";

contract LendingPool {
    using SafeMath for uint;
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
    // Following two vars are only for iterating on `delegateAllowance`, merge into usersData
    mapping(address=>address[]) delegatorsForDelegatee;
    mapping(address=>address[]) delegateesForDelegator;

    mapping(address => Types.UserKycData) usersKycData;
    Types.InterestRateData public interestSetting;

    mapping(address => bool) users;
    // Only for iterating on `users` 
    address[] usersList;

    struct BorrowStatusData {
        bool receiverInList;
        uint256 amount;
    }
    mapping(address=>mapping(address => BorrowStatusData)) public borrowStatus;
    
    // only for iterating
    mapping(address=>address[]) borrowOwners;
    uint256 public paratest;

    ERC20Blacklistable public sToken;
    ERC20Blacklistable public debtToken;
    AggregatorV3Interface oracle;
    
    constructor(
        // address _sToken,
        // address _debtToken,
        address oraclePriceAddress,
        uint256 ltv,
        uint256 liquidityThreshold,
        uint256 liquidityBonus,
        uint256 optimalUtilizationRate,
        uint256 rateSlope1, uint256 rateSlope2
    ) {
        // Change as per convenience
        sToken = new ERC20Blacklistable(0, "S-Token", "STOK", 18);
        debtToken = new ERC20Blacklistable(0, "D-Token", "DTOK", 18);

        reserve = Types.newReserveData(
            address(sToken), 
            address(debtToken), 
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

        oracle = AggregatorV3Interface(oraclePriceAddress);
    }

    //when the contract init, the reserve.lastUpdatedTimestamp is 0, so needed
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

        usersData[receiver].lastUpdatedTimestamp = block.timestamp;
            
        sToken.mint(receiver, amount);
        users[receiver] = true;
        usersList.push(receiver);

        emit Deposit(sender, receiver, amount);
    }

    function getBlockTimestamp() public view returns(uint256) {
        return block.timestamp;
    }

    function getNormalizedIncome(uint256 timestamp) public view returns(uint256) {
        return calculateLinearInterest(timestamp) * reserve.liquidityIndex / Types.ONE;
    }

    function getNormalizedDebt(uint256 timestamp) public view returns(uint256) {
        return calculateCompoundedInterest(reserve.borrowRate, timestamp) * reserve.borrowIndex / Types.ONE;
    }

    // Returns the factor to multiply with the principal amount to get current value
    // @audit relation with liquidityIndex and effect on withdraw, repay, borrow
    function calculateLinearInterest(uint256 lastUpdatedTimestamp) public view returns(uint256) {
        uint256 timeDifference = block.timestamp - lastUpdatedTimestamp;

        // Check redundancy for this
        if (lastUpdatedTimestamp == 0)
            timeDifference = 0;
        
        return reserve.liquidityRate * timeDifference / Types.ONE_YEAR;
    }

    function calculateCompoundedInterest(uint256 rate, uint256 lastUpdatedTimestamp) public view returns(uint256) {
        uint256 timeDifference = block.timestamp - lastUpdatedTimestamp;
        if (timeDifference == 0) 
            return 0;
        uint256 timeDifferenceMinusOne = timeDifference - 1;
        uint256 timeDifferenceMinusTwo;
        if (timeDifference > 2) {
            timeDifferenceMinusTwo = timeDifference - 2;
        } else {
            timeDifferenceMinusTwo = 0;
        }

        uint256 secondTerm = timeDifference * timeDifferenceMinusOne * rate**2  / (Types.ONE_YEAR**2 * Types.ONE * 2);
        uint256 thirdTerm = timeDifference * timeDifferenceMinusOne * timeDifferenceMinusTwo * rate**3 / (Types.ONE_YEAR**3 * Types.ONE**2 * 6);
        return rate * timeDifference / Types.ONE_YEAR + secondTerm + thirdTerm;
    }

    /// @dev should always be called before token burns
    function updatePoolState(uint256 liquidityAdded, uint256 liquidityTaken) internal {
        (
            uint256 newLiquidityRate, 
            uint256 newBorrowRate, 
            uint256 utilizationRate
        ) = Types.calculateInterestRates(
            reserve, 
            interestSetting, 
            liquidityAdded , 
            liquidityTaken , 
            reserve.borrowRate
        );

        reserve.lastUpdatedTimestamp = block.timestamp;
        reserve.liquidityRate = newLiquidityRate;
        reserve.borrowRate = newBorrowRate;
        interestSetting.utilizationRate = utilizationRate;

        // @follow-up see how lastUpdatedTimestamp initialization prior to this can cause issues
        if (reserve.liquidityRate > 0) {
            uint256 cumulatedLiquidityInterest = calculateLinearInterest(reserve.lastUpdatedTimestamp);
            reserve.liquidityIndex = reserve.liquidityIndex * cumulatedLiquidityInterest / Types.ONE;
        }

        // @audit-issue setting reserve.lastUpdatedTimestamp before calculating borrowInterest is harmful
        uint256 cumulatedBorrowInterest = calculateCompoundedInterest(reserve.borrowRate, reserve.lastUpdatedTimestamp);
        if (cumulatedBorrowInterest > 0) {
            reserve.borrowIndex = reserve.borrowIndex * cumulatedBorrowInterest / Types.ONE;
        }
    }

    function getNewReserveRates(uint256 liquidityAdded, uint256 liquidityTaken) public view returns(uint256, uint256, uint256) {
        return Types.calculateInterestRates(reserve, interestSetting, liquidityAdded, liquidityTaken, reserve.borrowRate);
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
        
        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) * sToken.balanceOf(sender) / Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) * debtToken.balanceOf(sender) / Types.ONE;
        Types.UserReserveData memory reserveData = usersData[sender];
        require(reserveData.lastUpdatedTimestamp > 0, "user config does not exist");

        if (interest > 0) {
            reserveData.cumulatedLiquidityInterest += interest;
            reserveData.cumulatedBorrowInterest += debtInterest;
        }

        uint256 availableUserBalance = sToken.balanceOf(sender) + reserveData.cumulatedLiquidityInterest - reserveData.cumulatedBorrowInterest;

        require(
            amount <= availableUserBalance,
            "Not enough available user balance"
        );

        updatePoolState(0, amount);

        // @follow-up
        if (reserve.liquidityIndex / Types.ONE == 0) {
            sToken.burn(sender, amount);
        } else {
            sToken.burn(sender, amount * Types.ONE / reserve.liquidityIndex);
        }
        reserveData.lastUpdatedTimestamp = block.timestamp;

        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "Failed to send MATIC");
        emit Withdraw(sender, receiver, amount);
    }

    /**
    * @dev Allows users to borrow a specific `amount` of the reserve underlying asset, provided that the borrower
    * was given enough allowance by a credit delegator on the
    * corresponding debt token
    * - E.g. User borrows 100 MATIC passing as `onBehalfOf` his own address, receiving the 100 MATIC in his wallet
    *   and 100 debt tokens
    * @param amount The amount to be borrowed
    * @param onBehalfOf Address of the user who will receive the debt. Should be the zero address
    * if he wants to borrow against his own collateral, or the address of the credit delegator
    * if he has been given credit delegation allowance
    **/ 
    function borrow(uint256 amount, address onBehalfOf) public {
        require(onBehalfOf != address(0), "Invalid value for address onBehalfOf");
        address sender = msg.sender;

        require(amount != 0, "Invalid amount");
        address receiver = onBehalfOf;
        
        uint256 creditBalance = sToken.balanceOf(sender) - debtToken.balanceOf(sender);
        if (sender != receiver)
            creditBalance = delegateAllowance[receiver][sender]; // This should be reversed

        require(
            amount <= creditBalance, 
            "Not enough available user balance"
        );       
        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) * sToken.balanceOf(receiver) / Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) * debtToken.balanceOf(receiver) / Types.ONE;

        Types.UserReserveData memory reserveData = usersData[receiver];
        // TODO check if it is updated on deposit/borrow/withdraw/repay
        require(reserveData.lastUpdatedTimestamp > 0, "user config does not exist");
        if (interest > 0) {
            reserveData.cumulatedLiquidityInterest = interest;
            reserveData.cumulatedBorrowInterest = debtInterest;
        }
        uint256 curAvailableBalance = reserveData.cumulatedLiquidityInterest - reserveData.cumulatedBorrowInterest;

        require(
            amount / Types.ONE <= curAvailableBalance, 
            "Not enough available user balance"
        );
        reserveData.lastUpdatedTimestamp = block.timestamp;

        delegateAllowance[receiver][sender] = creditBalance - amount;
        if (reserve.borrowIndex / Types.ONE == 0) 
            debtToken.mint(receiver, amount);
        else debtToken.mint(receiver, amount * reserve.borrowIndex / Types.ONE);

        if (!borrowStatus[sender][receiver].receiverInList) { 
            borrowOwners[sender].push(receiver);
        }
        borrowStatus[sender][receiver].amount += amount;   

        (bool sent, ) = sender.call{value: amount}("");
        require(sent, "transfer failed");

        updatePoolState(0, amount);

        emit Borrow(sender, onBehalfOf, amount);
    }

    /**
    * @notice Repays a borrowed `amount` on a specific reserve, burning the equivalent debt tokens owned
    * - E.g. User repays 100 MATIC, burning 100 debt tokens of the `onBehalfOf` address
    * - Send the value in order to repay the debt for `asset`
    * @param onBehalfOf Address of the user who will get his debt reduced/removed. Should be the address of the
    * user calling the function if he wants to reduce/remove his own debt, or the address of any other
    * other borrower whose debt should be removed
    **/   
    function repay(address onBehalfOf) public payable {
        address sender = msg.sender;
        require(onBehalfOf != address(0), "Invalid value for address onBehalfOf");
        address receiver = onBehalfOf;
        uint256 amount = msg.value;
        require(amount != 0, "Invalid amount");

        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) * sToken.balanceOf(receiver) / Types.ONE / Types.ONE ;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) * debtToken.balanceOf(receiver) / Types.ONE_PERCENTAGE / Types.ONE;
        Types.UserReserveData memory reserveDataSender = usersData[receiver];
        require(reserveDataSender.lastUpdatedTimestamp > 0, "you have not borrowed any matic");

        if (interest > 0) {
            reserveDataSender.cumulatedLiquidityInterest = interest;
            reserveDataSender.cumulatedBorrowInterest = debtInterest;
        }
        if (reserve.borrowIndex / Types.ONE == 0) {
            debtToken.burn(receiver, amount);            
        } else {
            debtToken.burn(receiver, amount * reserve.borrowIndex / Types.ONE);
        }

        borrowStatus[sender][receiver].amount -= amount; 
        reserveDataSender.lastUpdatedTimestamp = block.timestamp;
        
        updatePoolState(amount, 0);

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

        // For iterating purposes
        delegatorsForDelegatee[delegatee].push(delegator);
        delegateesForDelegator[delegator].push(delegatee);
    }

    // Unnecessary
    function delegateAmount(address delegator, address delegatee) public view returns(uint256) {
        return delegateAllowance[delegator][delegatee];
    }

    
    function delegateFrom() public view returns(
        address[] memory delegators, 
        uint256[] memory amounts
    ) {
        delegators = delegatorsForDelegatee[msg.sender];
        amounts = new uint256[](delegators.length);

        for (uint256 i = 0; i < delegators.length; i++) 
            amounts[i] = delegateAllowance[delegators[i]][msg.sender];
    }

    function delegateTo() public view returns (
       address[] memory delegatees, 
       uint[] memory amounts
    ) {
        delegatees = delegateesForDelegator[msg.sender];
        amounts = new uint256[](delegatees.length);

        for (uint256 i = 0; i < delegatees.length; i++) 
            amounts[i] = delegateAllowance[msg.sender][delegatees[i]];
    }

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
        
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        // @audit-issue total debt interest accrued and deposit interest accrued not added
        uint256 borrowerTotalDebt = debtToken.balanceOf(borrower) * unitPrice / Types.ONE; 
        uint256 borrowerTotalBalance = sToken.balanceOf(borrower) * unitPrice / Types.ONE;
        uint256 healthFactor = Types.calculateHealthFactorFromBalance(borrowerTotalBalance, borrowerTotalDebt, reserve.liquidityThreshold);
        require(
            healthFactor < Types.HEALTH_FACTOR_LIQUIDATION_THRESHOLD, 
            "LPCM Health factor not below threshold"
        );
        require(
            borrowerTotalDebt > 0, 
            "LPCM specified currency not borrowed by user"
        );
        uint256 maxLiquidatableDebt = borrowerTotalDebt * Types.LIQUIDATION_CLOSE_FACTOR_PERCENT / unitPrice / Types.ONE;
        (uint256 actualDebtToLiquidate, uint256 maxCollateralToLiquidate) = calculateDebtAndCollateralToLiquidate(borrower, debtToCover, maxLiquidatableDebt);
 
        if (!receiveSToken) {
            uint256 availableMatic = address(this).balance; 
            require(
                availableMatic >= maxCollateralToLiquidate, // Meaning maxCollateralToLiquidate is 1:1 value with MATIC, thus sToken:MATIC is 1:1 
                "LPCM not enough liquidity to liquidate"
            );
        } 
        
        updatePoolState(actualDebtToLiquidate, 0);
        debtToken.burn(borrower, actualDebtToLiquidate);


        if (receiveSToken) {
            require(sToken.transferFrom(borrower, liquidator, maxCollateralToLiquidate), "transferFrom failed");                   
        } else {
            updatePoolState(0, maxCollateralToLiquidate);
            sToken.burn(borrower, maxCollateralToLiquidate);

            (bool sent, ) = liquidator.call{value: maxCollateralToLiquidate}("");
            require(sent, "transfer failed");
        }

        Types.UserReserveData memory borrowerData = usersData[borrower];
        require(borrowerData.lastUpdatedTimestamp > 0, "user config does not exist");
        
        // @audit-issue store the last calculated borrowInterest, if previous suggestion implemented and tokens minted, set to 0
        // alternatively make an update function for addresses
        borrowerData.lastUpdatedTimestamp = block.timestamp;

        emit Liquidation(liquidator, borrower, actualDebtToLiquidate, maxCollateralToLiquidate);
    }

    function calculateDebtAndCollateralToLiquidate(address borrower, uint256 debtToCover, uint256 maxLiquidatableDebt) internal view returns(
        uint256 actualDebtToLiquidate, uint256 
    ) {
        if (debtToCover > maxLiquidatableDebt) {
            actualDebtToLiquidate = maxLiquidatableDebt;
        } else {
            actualDebtToLiquidate = debtToCover;
        }

        (uint256 maxCollateralToLiquidate, uint256 debtAmountNeeded) = Types.calculateAvailableCollateralToLiquidate(reserve, actualDebtToLiquidate, sToken.balanceOf(borrower));
        if (debtAmountNeeded < actualDebtToLiquidate) {
            actualDebtToLiquidate = debtAmountNeeded;
        }

        return (actualDebtToLiquidate, maxCollateralToLiquidate);
    }
    
    function isUserReserveHealthy(address user) public view returns(uint256) {
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        //if user does not exist should return 0
        if (usersData[user].lastUpdatedTimestamp == 0) {
            return 0;
        }

        // @audit-issue total debt interest accrued and deposit interest accrued not added 
        uint256 _totalCollateralInUsd = unitPrice * sToken.balanceOf(user) / Types.ONE;
        uint256 _totalDebtInUsd = unitPrice * debtToken.balanceOf(user) / Types.ONE;
        uint256 healthFactor = Types.calculateHealthFactorFromBalance(_totalCollateralInUsd, _totalDebtInUsd, reserve.liquidityThreshold);
        return healthFactor;
    }

    function oracleTest() public view returns(uint256) {
        (, int256 result, , , ) = oracle.latestRoundData();
        return uint256(result);
    }

    /**
    * Get reserve data * total market supply * available liquidity 
    * total lending * utilization rate 
    **/
    function getReserveDataUi() public view returns(uint256, uint256, uint256, uint256) {
        uint256 totalSToken = sToken.totalSupply();
        uint256 totalDToken = debtToken.totalSupply();
        uint256 availableLiquidity = totalSToken - totalDToken;
        
        uint256 utilizationRate = totalDToken * Types.ONE / (totalSToken + totalDToken);
        return (totalSToken, availableLiquidity, totalDToken, utilizationRate);
    }

    /**
    * liquidity_rate * borrow_rate * ltv * liquidity_threshold
    * liquidity_bonus * decimals * last_updated_timestamp*liquidity_index*borrow_index
    **/
    function getReserveData() public view returns
    (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        return (
            reserve.liquidityRate, 
            reserve.borrowRate,
            reserve.ltv, reserve.liquidityThreshold, 
            reserve.liquidityBonus, reserve.decimals, 
            reserve.lastUpdatedTimestamp, reserve.liquidityIndex,
            reserve.borrowIndex
        );
    } 

    /**
    * Get user reserve data * total deposit * total borrow * deposit interest
    * borrow interest *current timestamp 
    **/        
    function getUserReserveDataUi(address user) public view returns(uint256, uint256, uint256, uint256, uint256) {
        uint256 userSToken = sToken.balanceOf(user) / Types.ONE;
        uint256 userDToken = debtToken.balanceOf(user) / Types.ONE;

        uint256 interest = getNormalizedIncome(reserve.lastUpdatedTimestamp) * userSToken / Types.ONE;
        uint256 debtInterest = getNormalizedDebt(reserve.lastUpdatedTimestamp) * userDToken / Types.ONE_PERCENTAGE;
        Types.UserReserveData memory data = usersData[user];

        if (data.lastUpdatedTimestamp > 0) {
            uint256 cumulatedLiquidityInterest = data.cumulatedLiquidityInterest + interest;
            uint256 cumulatedBorrowInterest = data.cumulatedBorrowInterest + debtInterest;
            uint256 currentTimestamp = block.timestamp;
            return (userSToken, cumulatedLiquidityInterest, userDToken, cumulatedBorrowInterest, currentTimestamp);
        } else return (0, 0, 0, 0, 0);
    }

    function getUserBorrowStatus() public view returns(
        address[] memory addresses, 
        uint256[] memory amounts
    ) {
        addresses = borrowOwners[msg.sender];
        amounts = new uint256[](addresses.length);

        for (uint256 i = 0; i < borrowOwners[msg.sender].length; i++) {
            amounts[i] = borrowStatus[msg.sender][addresses[i]].amount;
        }
    }

    function showUtilizeRate(uint256 liquidityAdded, uint256 liquidityTaken) public view returns(uint256 utilizationRate) {
        uint256 totalDebt = debtToken.totalSupply() / Types.ONE;
        uint256 _availableLiqudity = sToken.totalSupply() / Types.ONE;
        uint256 currentAvailableLiqudity = _availableLiqudity + liquidityAdded - liquidityTaken;

        if (totalDebt == 0) {
            utilizationRate = 0;
        } else {
            utilizationRate = totalDebt  * Types.ONE / (currentAvailableLiqudity + totalDebt);
        }
    }

    function setReserveConfiguration(
        uint256 ltv, 
        uint256 liquidityThreshold, 
        uint256 liquidityBonus
    ) public {
        reserve.ltv = ltv;
        reserve.liquidityThreshold = liquidityThreshold;
        reserve.liquidityBonus = liquidityBonus;
    }

    function setInterestRateData(
        uint256 optimalUtilizationRate, 
        uint256 rateSlope1, 
        uint256 rateSlope2
    ) public {
            interestSetting.optimalUtilizationRate = optimalUtilizationRate;
            interestSetting.rateSlope1 = rateSlope1;
            interestSetting.rateSlope2 = rateSlope2;                
    }

    function setKycData(string memory name, string memory email) public {
        if (bytes(name).length == 0) 
            name = usersKycData[msg.sender].name;
        if (bytes(email).length == 0) 
            email = usersKycData[msg.sender].email;

        usersKycData[msg.sender] = Types.UserKycData ({name: name, email: email});      
    }
    
    function getTheUnhealthyReserves() public view returns(uint256 length, address[] memory addresses) {
        (, int256 result, , , ) = oracle.latestRoundData();
        uint256 unitPrice = uint256(result);

        addresses = new address[](usersList.length);

        for (uint256 i = 0; i < usersList.length; i++) {
            address user = usersList[i];
            if (!users[user])
                continue;
        
            uint256 _totalCollateralInUsd = unitPrice * sToken.balanceOf(user) / Types.ONE;
            uint256 _totalDebtInUsd = unitPrice * debtToken.balanceOf(user) / Types.ONE;
            if (Types.calculateHealthFactorFromBalance(_totalCollateralInUsd, _totalDebtInUsd, reserve.liquidityThreshold) < Types.HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
                addresses[length++] = user;
            }
            return (length, addresses);
        }
    } 
}
