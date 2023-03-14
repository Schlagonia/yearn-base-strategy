// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import {Setup, IMockStrategy, BaseLibrary} from "./utils/Setup.sol";

contract AccountingTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function test_airdropDoesNotIncreasePPS(
        address _address,
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 10, MAX_BPS);
        vm.assume(_address != address(0) && _address != address(strategy));

        // set fees to 0 for calculations simplicity
        vm.prank(management);
        strategy.setPerformanceFee(0);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(_address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // aidrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(strategy.totalDebt(), _amount);
        assertEq(strategy.totalIdle(), 0);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out just the deposit amount
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(asset.balanceOf(address(strategy)), toAirdrop);
    }

    function test_airdropDoesNotIncreasePPS_reportRecordsIt(
        address _address,
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 10, MAX_BPS);
        vm.assume(_address != address(0) && _address != address(strategy));

        // set fees to 0 for calculations simplicity
        setFees(0, 0);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(_address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // aidrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(strategy.totalDebt(), _amount);
        assertEq(strategy.totalIdle(), 0);

        // process a report to realize the gain from the airdrop
        uint256 profit;
        vm.prank(keeper);
        (profit, ) = strategy.report();

        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(profit, toAirdrop);
        assertEq(strategy.totalDebt(), _amount + toAirdrop);
        assertEq(strategy.totalIdle(), 0);

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        assertGt(strategy.pricePerShare(), pricePerShare);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(strategy), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare);

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // we should get a % return equal to our profit factor
        assertRelApproxEq(
            strategy.pricePerShare(),
            wad + ((wad * _profitFactor) / MAX_BPS),
            MAX_BPS
        );
        assertEq(strategy.totalDebt(), _amount + toAirdrop);
        assertEq(strategy.totalIdle(), 0);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(
            asset.balanceOf(_address),
            beforeBalance + _amount + toAirdrop
        );
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(asset.balanceOf(address(strategy)), toAirdrop);
    }

    function test_earningYieldDoesNotIncreasePPS(
        address _address,
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 10, MAX_BPS);
        vm.assume(_address != address(0) && _address != address(strategy));

        // set fees to 0 for calculations simplicity
        setFees(0, 0);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the strategy
        mintAndDepositIntoStrategy(_address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // aidrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);

        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(strategy.totalDebt(), _amount);
        assertEq(strategy.totalIdle(), 0);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out just the deposit amount
        assertEq(asset.balanceOf(_address), beforeBalance + _amount);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
    }

    function test_earningYieldDoesNotIncreasePPS_reportRecodsIt(
        address _address,
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 10, MAX_BPS);
        vm.assume(_address != address(0) && _address != address(strategy));

        // set fees to 0 for calculations simplicity
        vm.prank(management);
        strategy.setPerformanceFee(0);

        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(_address, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // aidrop to strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(asset.balanceOf(address(yieldSource)), _amount + toAirdrop);
        // nothing should change
        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(strategy.totalDebt(), _amount);
        assertEq(strategy.totalIdle(), 0);

        // process a report to realize the gain from the airdrop
        uint256 profit;
        vm.prank(keeper);
        (profit, ) = strategy.report();

        assertEq(strategy.pricePerShare(), pricePerShare);
        assertEq(profit, toAirdrop);
        assertEq(strategy.totalDebt(), _amount + toAirdrop);
        assertEq(strategy.totalIdle(), 0);

        // allow some profit to come unlocked
        skip(profitMaxUnlockTime / 2);

        assertGt(strategy.pricePerShare(), pricePerShare);

        //air drop again, we should not increase again
        pricePerShare = strategy.pricePerShare();
        asset.mint(address(yieldSource), toAirdrop);
        assertEq(strategy.pricePerShare(), pricePerShare);

        // skip the rest of the time for unlocking
        skip(profitMaxUnlockTime / 2);

        // we should get a % return equal to our profit factor
        assertRelApproxEq(
            strategy.pricePerShare(),
            wad + ((wad * _profitFactor) / MAX_BPS),
            MAX_BPS
        );
        assertEq(strategy.totalDebt(), _amount + toAirdrop);
        assertEq(strategy.totalIdle(), 0);

        uint256 beforeBalance = asset.balanceOf(_address);
        vm.prank(_address);
        strategy.redeem(_amount, _address, _address);

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(
            asset.balanceOf(_address),
            beforeBalance + _amount + toAirdrop
        );
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(asset.balanceOf(address(yieldSource)), toAirdrop);
    }

    function test_tend_noIdle_harvestProfit(
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 1, MAX_BPS);

        setFees(0, 0);
        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(user, _amount);

        // should still be 1
        assertEq(strategy.pricePerShare(), pricePerShare);

        // aidrop to strategy to simulate a harvesting of rewards
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);
        assertEq(asset.balanceOf(address(strategy)), toAirdrop);

        vm.prank(keeper);
        strategy.tend();

        // Should have deposited the toAirdrop amount but no other changes
        assertEq(strategy.totalAssets(), _amount, "!assets");
        assertEq(strategy.totalDebt(), _amount, "1debt");
        assertEq(strategy.totalIdle(), 0, "!idle");
        assertEq(
            asset.balanceOf(address(yieldSource)),
            _amount + toAirdrop,
            "!yieldsource"
        );
        assertEq(strategy.pricePerShare(), wad, "!pps");

        // Make sure we now report the profit correctly
        vm.prank(keeper);
        strategy.report();

        skip(profitMaxUnlockTime);

        assertRelApproxEq(
            strategy.pricePerShare(),
            wad + ((wad * _profitFactor) / MAX_BPS),
            MAX_BPS
        );

        uint256 beforeBalance = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // should have pulled out the deposit plus profit that was reported but not the second airdrop
        assertEq(asset.balanceOf(user), beforeBalance + _amount + toAirdrop);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(asset.balanceOf(address(yieldSource)), 0);
    }

    function test_tend_idleFunds_harvestProfit(
        uint256 _amount,
        uint256 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = bound(_profitFactor, 1, MAX_BPS);

        // Use the illiquid mock strategy so it doesnt deposit all funds
        strategy = IMockStrategy(setUpIlliquidStrategy());

        setFees(0, 0);
        // nothing has happened pps should be 1
        uint256 pricePerShare = strategy.pricePerShare();
        assertEq(pricePerShare, wad);

        // deposit into the vault
        mintAndDepositIntoStrategy(user, _amount);

        uint256 expectedDeposit = _amount / 2;
        assertEq(strategy.totalAssets(), _amount, "!assets");
        assertEq(strategy.totalDebt(), expectedDeposit, "1debt");
        assertEq(strategy.totalIdle(), _amount - expectedDeposit, "!idle");
        assertEq(
            asset.balanceOf(address(yieldSource)),
            expectedDeposit,
            "!yieldsource"
        );
        // should still be 1
        assertEq(strategy.pricePerShare(), wad);

        // aidrop to strategy to simulate a harvesting of rewards
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        asset.mint(address(strategy), toAirdrop);
        assertEq(
            asset.balanceOf(address(strategy)),
            _amount - expectedDeposit + toAirdrop
        );

        vm.prank(keeper);
        strategy.tend();

        // Should have withdrawn all the funds from the yield source
        assertEq(strategy.totalAssets(), _amount, "!assets");
        assertEq(strategy.totalDebt(), 0, "1debt");
        assertEq(strategy.totalIdle(), _amount, "!idle");
        assertEq(asset.balanceOf(address(yieldSource)), 0, "!yieldsource");
        assertEq(asset.balanceOf(address(strategy)), _amount + toAirdrop);
        assertEq(strategy.pricePerShare(), wad, "!pps");

        // Make sure we now report the profit correctly
        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.totalAssets(), _amount + toAirdrop);
        assertEq(strategy.totalDebt(), (_amount + toAirdrop) / 2);
        assertEq(
            strategy.totalIdle(),
            (_amount + toAirdrop) - ((_amount + toAirdrop) / 2)
        );
        assertEq(
            asset.balanceOf(address(yieldSource)),
            (_amount + toAirdrop) / 2
        );

        skip(profitMaxUnlockTime);

        assertRelApproxEq(
            strategy.pricePerShare(),
            wad + ((wad * _profitFactor) / MAX_BPS),
            MAX_BPS
        );
    }

    function test_withdrawWithUnrealizedLoss(
        address _address,
        uint256 _amount,
        uint256 _lossFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _lossFactor = bound(_lossFactor, 10, MAX_BPS);
        vm.assume(_address != address(0) && _address != address(strategy));

        setFees(0, 0);
        mintAndDepositIntoStrategy(_address, _amount);

        uint256 toLoose = (_amount * _lossFactor) / MAX_BPS;
        // Simulate a loss.
        vm.prank(address(yieldSource));
        asset.transfer(address(69), toLoose);

        uint256 beforeBalance = asset.balanceOf(_address);
        uint256 expectedOut = _amount - toLoose;
        // Withdraw the full amount before the loss is reported.
        vm.prank(_address);
        strategy.withdraw(_amount, _address, _address);

        uint256 afterBalance = asset.balanceOf(_address);

        assertEq(afterBalance - beforeBalance, expectedOut);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalIdle(), 0);
        assertEq(strategy.totalSupply(), 0);
        assertEq(strategy.pricePerShare(), wad);
    }
}
