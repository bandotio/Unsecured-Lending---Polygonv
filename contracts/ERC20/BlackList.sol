//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract BlackList is Ownable {
    event DestroyedBlackFunds(address indexed blacklistedUser, uint256 balance);
    event AddedBlackList(address indexed user);
    event RemovedBlackList(address indexed user);

    mapping(address=>bool) blacklisted;

    /// Whether the user is blacklisted.
    function getBlacklistStatus(address maker) public view virtual returns(bool) {
        return blacklisted[maker];
    }

    /// Add illegal user to blacklist.
    function addBlacklist(address evilUser) public virtual onlyOwner {
        require(blacklisted[evilUser] == false, "user already blacklisted");
        blacklisted[evilUser] = true;

        emit AddedBlackList(evilUser);
    }

    /// Remove the user from blacklist.
    function removeBlacklist(address clearedUser) public virtual onlyOwner {
        require(blacklisted[clearedUser] == true, "user not blacklisted");
        blacklisted[clearedUser] = false;

        emit RemovedBlackList(clearedUser);
    }

    /// Destroy blacklisted user funds from total supply.
    function destroyBlackFunds(address blacklistedUser) public virtual;
}