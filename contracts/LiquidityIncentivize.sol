// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20 {
    function balanceOf(address _owner) external view returns (uint256 balance);
    function transfer(address _to, uint256 _value) external returns (bool success);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool success);
    function approve(address _spender, uint256 _value) external returns (bool success);
    function allowance(address _owner, address _spender) external view returns (uint256 remaining);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);
}

contract LiquidityIncentivize is Ownable {
    struct UserData {
        uint rewards; // total rewards accumulated
        uint deposit; // total participating deposit in this incentivization  
        uint depositTimestamp; // lat deposit/withdraw timestamp
    }

    mapping(address => UserData) public userData;
    uint participatingSTokens;

    uint public rewardsLeft;
    uint public weeklyReward;

    uint lastWeekTimestamp;
    bool hasEnded; // true when all rewards have dried up

    constructor(uint _weeklyReward) payable {
        rewardsLeft = msg.value;
        weeklyReward = _weeklyReward;
        lastWeekTimestamp = block.timestamp;
    }

    function updateUserData(address user, uint amount, bool liquidityAdded) public onlyOwner {
        require(!hasEnded, "This incentive dosn't have any more rewards");
        updateWeek();

        if (!liquidityAdded && (userData[user].deposit == 0))
            return;
        
        uint rewards = (block.timestamp - lastWeekTimestamp) * weeklyReward * userData[user].deposit  / participatingSTokens;
        if (rewards > address(this).balance) {
            rewards = address(this).balance;
            hasEnded = true;
        }
        rewardsLeft -= rewards;

        userData[user].rewards += rewards;
        userData[user].depositTimestamp = block.timestamp;

        if (!liquidityAdded) {
            if (amount > userData[user].deposit) {
                participatingSTokens -= userData[user].deposit;
                userData[user].deposit = 0;
            }
            else {
                participatingSTokens -= amount;
                userData[user].deposit -= amount;
            }
        } else {
            userData[user].deposit += amount;
            participatingSTokens += amount;
        }
    }

    function updateWeek() internal {
        uint weeksPassed = (block.timestamp - lastWeekTimestamp) / (7 days);
        lastWeekTimestamp += weeksPassed * 7 days;
    }

    // User calls this to accumulate rewards, as long as there are rewards available
    function updateUserRewards() public {
        require(!hasEnded, "This incentive dosn't have any more rewards");

        uint rewards = (block.timestamp - lastWeekTimestamp) * weeklyReward * userData[msg.sender].deposit  / participatingSTokens;
        if (rewards > address(this).balance) {
            rewards = address(this).balance;
            hasEnded = true;
        }
        rewardsLeft -= rewards;

        userData[msg.sender].rewards += rewards;
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
        if (msg.value != 0)
            hasEnded = false;
    }
}