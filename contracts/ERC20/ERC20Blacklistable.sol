//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "./BlackList.sol";

contract ERC20Blacklistable is ERC20PresetMinterPauser, BlackList {

    uint8 _decimals;
    
    constructor(
        uint256 initialSupply, 
        string memory _name, 
        string memory _symbol, 
        uint8 _tokenDecimals
        ) ERC20PresetMinterPauser(_name, _symbol) {
            _decimals = _tokenDecimals;
            mint(_msgSender(), initialSupply);
    }

    function destroyBlackFunds(address blacklistedUser) public override onlyOwner {
        require(getBlacklistStatus(blacklistedUser) == true, "user not blacklisted");

        uint256 dirtyFunds = balanceOf(blacklistedUser);
        _burn(blacklistedUser, dirtyFunds);

        emit DestroyedBlackFunds(blacklistedUser, dirtyFunds);
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _revokeRole(DEFAULT_ADMIN_ROLE, owner());
        
        _revokeRole(MINTER_ROLE, owner());
        _revokeRole(PAUSER_ROLE, owner());

        _setupRole(MINTER_ROLE, newOwner);
        _setupRole(PAUSER_ROLE, newOwner);

        _transferOwnership(newOwner);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function burn(address account, uint256 amount) public virtual onlyOwner {
        _burn(account, amount);
    }

    function transferFrom(address sender, address recipient, uint amount) public override returns(bool) {
        if (msg.sender == owner())
            _transfer(sender, recipient, amount);
        else
            ERC20.transferFrom(sender, recipient, amount);

        return true;
    }
}