// The incentive contract
// How to use:
// Deploy the pool contract with the incentive as msg.value and pass maxWeeklyRewards value

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityIncentivize is Ownable {
    struct UserData {
        uint rewards; // total rewards accumulated
        uint deposit; // total participating deposit in this incentivization  
        uint updateTimestamp; // last deposit/withdraw timestamp
    }

    address[] users;

    mapping(address => UserData) public userData;
    uint participatingSTokens;

    uint public rewardsLeft;
    uint public weeklyRewardLeft;
    uint public maxWeeklyReward;

    uint lastGlobalUpdateTimestamp;
    bool hasEnded; // true when all rewards have dried up

    constructor(uint _maxWeeklyReward) payable {
        rewardsLeft = msg.value;
        maxWeeklyReward = _maxWeeklyReward;
        weeklyRewardLeft = rewardsLeft >= maxWeeklyReward ? maxWeeklyReward : rewardsLeft;
        lastGlobalUpdateTimestamp = block.timestamp;
    }

    // Check `hasEnded` before calling to prevent unwanted reverts 
    function updateUserData(address user, uint amount, bool liquidityAdded) external onlyOwner {
        require(!hasEnded, "This incentive dosn't have any more rewards");

        require(block.timestamp < lastGlobalUpdateTimestamp + 7 days, "Call `updateRewardsGlobally` first!");

        // If new user for this contract, add to `users` list
        if (userData[user].updateTimestamp == 0) {
            users.push(user);
            userData[user].updateTimestamp = block.timestamp;
        }

        // Add pending rewards to the user's data
        updateUserRewards(user);

        if (!liquidityAdded && (userData[user].deposit < amount)) {
            participatingSTokens -= userData[user].deposit; 
            userData[user].deposit = 0;
            return;
        }

        if (!liquidityAdded) {
            participatingSTokens -= amount;
            userData[user].deposit -= amount;
        } else {
            participatingSTokens += amount;
            userData[user].deposit += amount;
        }
    }

    function updateRewardsGlobally() public {
        require(block.timestamp >= lastGlobalUpdateTimestamp + 7 days, "You can call this only after 7 days of previous week");
        
        for (uint i = 0; i < users.length; i++) {
            updateUserRewards(users[i]);
        }

        lastGlobalUpdateTimestamp = block.timestamp;
        weeklyRewardLeft = rewardsLeft >= maxWeeklyReward ? maxWeeklyReward : rewardsLeft;
    } 

    // User calls this to accumulate rewards, as long as there are rewards available
    function updateUserRewards(address user) public {
        uint rewards = (block.timestamp - userData[user].updateTimestamp) * maxWeeklyReward * userData[user].deposit  / participatingSTokens;
        if (rewards > weeklyRewardLeft) {
            rewards = weeklyRewardLeft;
            hasEnded = true;
        }

        rewardsLeft -= rewards;
        weeklyRewardLeft -= rewards;
        userData[user].rewards += rewards;
        userData[user].updateTimestamp = block.timestamp;
    }

    function isActive() external view returns(bool) {
        return  (block.timestamp < lastGlobalUpdateTimestamp + 7 days) && !hasEnded;
    }

    function withdraw() public {
        uint reward = userData[msg.sender].rewards;
        userData[msg.sender].rewards = 0;

        (bool sent, ) = payable(msg.sender).call{value: reward}("");
        require(sent, "Transfer failed");
    }

    // Used for filling up the rewards
    receive() external payable {
        rewardsLeft += msg.value;
        weeklyRewardLeft = rewardsLeft >= maxWeeklyReward ? maxWeeklyReward : rewardsLeft;
        
        if (msg.value != 0)
            hasEnded = false;
    }
}