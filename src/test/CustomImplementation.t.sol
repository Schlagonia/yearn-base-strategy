// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import {Setup, DiamondHelper, MockFactory, ERC20Mock, MockYieldSource, IMockStrategy} from "./utils/Setup.sol";

import {BaseLibrary} from "../libraries/BaseLibrary.sol";

contract CutsomImplementationsTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_customWithdrawLimit(
        address _address,
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(_address != address(0) && _address != address(strategy));

        strategy = IMockStrategy(setUpIlliquidStrategy());

        mintAndDepositIntoStrategy(_address, _amount);

        // Assure we have a withdraw limit
        assertEq(
            strategy.availableWithdrawLimit(_address),
            strategy.totalIdle()
        );
        assertGt(strategy.totalAssets(), strategy.totalIdle());

        vm.expectRevert("ERC4626: withdraw more than max");
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);
    }

    function test_customDepositLimit(
        address _allowed,
        address _notAllowed,
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        vm.assume(
            _allowed != address(0) &&
                _allowed != address(strategy) &&
                _allowed != _notAllowed
        );
        vm.assume(
            _notAllowed != address(0) && _notAllowed != address(strategy)
        );

        strategy = IMockStrategy(setUpIlliquidStrategy());

        setupWhitelist(_allowed);

        // Deposit should work fine for normal
        mintAndDepositIntoStrategy(_allowed, _amount);

        // Assure we deposit correctly
        assertEq(strategy.totalAssets(), _amount);

        asset.mint(_notAllowed, _amount);
        vm.prank(_notAllowed);
        asset.approve(address(strategy), _amount);

        vm.expectRevert("ERC4626: deposit more than max");
        vm.prank(_notAllowed);
        strategy.deposit(_amount, _notAllowed);
    }

    // TODO:
    // withdraw full amount when locked
    // strategy that withdraws more than it should
    // strategy that deposits less than it should
    // exploiter strategy that reenters
    // View only reentrancy
}
