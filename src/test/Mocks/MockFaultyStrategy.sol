// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockYieldSource} from "./MockYieldSource.sol";
import {BaseStrategy} from "../../BaseStrategy.sol";

interface IPappa {
    function callBack(
        uint256 _pps,
        uint256 _converAmountToShares,
        uint256 _converAmountToAssets
    ) external;
}

contract MockFaultyStrategy is BaseStrategy {
    address public yieldSource;

    address public pappa;
    uint256 public fault;
    bool public doCallBack;

    constructor(
        address _asset,
        address _yieldSource
    ) BaseStrategy(_asset, "Test Strategy") {
        yieldSource = _yieldSource;
        ERC20(_asset).approve(_yieldSource, type(uint256).max);
        pappa = msg.sender;
    }

    function _invest(uint256 _amount, bool _reported) internal override {
        if (doCallBack) {
            // If we are reentering base it off of totalInvested during reports
            if (_reported) {
                callBack(_totalInvested());
            } else {
                callBack(_amount);
            }
        }
        MockYieldSource(yieldSource).deposit(_amount + fault);
    }

    function _freeFunds(uint256 _amount) internal override {
        if (doCallBack) callBack(_amount);
        MockYieldSource(yieldSource).withdraw(_amount + fault);
    }

    function _totalInvested() internal override returns (uint256) {
        return
            MockYieldSource(yieldSource).balance() +
            ERC20(asset).balanceOf(address(this));
    }

    function _tend(uint256 _idle) internal override {
        if (doCallBack) callBack(_idle);
        uint256 balance = ERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            MockYieldSource(yieldSource).deposit(balance);
        }
    }

    function setFaultAmount(uint256 _fault) public {
        fault = _fault;
    }

    function setCallBack(bool _bool) public {
        doCallBack = _bool;
    }

    // This means we are in the middle of a strategy function.
    // We will simulate a view reentrancy.
    function callBack(uint256 _amount) public {
        IPappa(pappa).callBack(
            BaseLibrary.pricePerShare(),
            BaseLibrary.convertToShares(_amount),
            BaseLibrary.convertToAssets(_amount)
        );
    }
}
