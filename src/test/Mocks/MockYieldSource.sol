// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockYieldSource {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function deposit(uint256 _amount) public {
        ERC20(asset).transferFrom(msg.sender, address(this), _amount);
    }

    function withdraw(uint256 _amount) public {
        uint256 balance = ERC20(asset).balanceOf(address(this));
        _amount = _amount > balance ? balance : _amount;
        ERC20(asset).transfer(msg.sender, _amount);
    }

    function balance() public returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function simulateLoss(uint256 _amount) public {
        ERC20(asset).transfer(msg.sender, _amount);
    }
}
