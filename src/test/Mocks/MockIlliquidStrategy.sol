// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockYieldSource} from "./MockYieldSource.sol";
import {BaseStrategy} from "../../BaseStrategy.sol";

contract MockIlliquidStrategy is BaseStrategy {
    address public yieldSource;
    bool public whitelist;
    mapping(address => bool) public allowed;

    constructor(
        address _asset,
        address _yieldSource
    ) BaseStrategy(_asset, "Test Strategy") {
        yieldSource = _yieldSource;
        ERC20(_asset).approve(_yieldSource, type(uint256).max);
    }

    function _invest(uint256 _amount, bool _reported) internal override {
        MockYieldSource(yieldSource).deposit(_amount / 2);
    }

    function _freeFunds(uint256 _amount) internal override {
        //MockYieldSource(yieldSource).withdraw(_amount);
    }

    function _totalInvested() internal override returns (uint256) {
        return
            MockYieldSource(yieldSource).balance() +
            ERC20(asset).balanceOf(address(this));
    }

    function _tend(uint256 _idle) internal override {
        uint256 balance = MockYieldSource(yieldSource).balance();
        if (balance > 0) {
            MockYieldSource(yieldSource).withdraw(balance);
        }
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (whitelist && !allowed[_owner]) {
            return 0;
        } else {
            return super.availableDepositLimit(_owner);
        }
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        return BaseLibrary.totalIdle();
    }

    function setWhitelist(bool _bool) external {
        whitelist = _bool;
    }

    function allow(address _address) external {
        allowed[_address] = true;
    }
}
