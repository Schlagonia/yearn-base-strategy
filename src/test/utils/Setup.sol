// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IMockStrategy} from "../Mocks/IMockStrategy.sol";
import {MockStrategy, MockYieldSource} from "../Mocks/MockStrategy.sol";
import {MockIlliquidStrategy} from "../Mocks/MockIlliquidStrategy.sol";
import {MockFaultyStrategy} from "../Mocks/MockFaultyStrategy.sol";
import {MockFactory} from "../Mocks/MockFactory.sol";

import {DiamondHelper} from "../../DiamondHelper.sol";
import {BaseLibrary} from "../../libraries/BaseLibrary.sol";

interface ERC {
    function symbol() external returns (string memory);

    function name() external returns (string memory);
}

// TODO: add check strategy totals() to every function

contract Setup is ExtendedTest {
    // Contract instancees that we will use repeatedly.
    ERC20Mock public asset;
    IMockStrategy public strategy;
    MockFactory public mockFactory;
    MockYieldSource public yieldSource;
    DiamondHelper public diamondHelper;

    // Addresses for different roles we will use repeatedly.
    address public management = address(1);
    address public protocolFeeRecipient = address(2);
    address public performanceFeeRecipient = address(3);
    address public keeper = address(4);
    address public user = address(10);

    // Integer variables that will be used repeatedly.
    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public minFuzzAmount = 10_000;
    uint256 public maxFuzzAmount = 1e30;
    uint256 public MAX_BPS = 10_000;
    // TODO: make these adjustable
    uint256 public decimals = 18;
    uint256 public wad = 10 ** decimals;
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        // deploy the selector helper first to get a deterministic location
        bytes4[] memory selectors = getSelectors();
        diamondHelper = new DiamondHelper(selectors);

        // deploy the mock factory next for deterministic location
        mockFactory = new MockFactory(0, protocolFeeRecipient);

        diamondHelper.setLibrary(address(BaseLibrary));

        // create asset we will be using as the underlying asset
        asset = new ERC20Mock("Test asset", "tTKN", address(this), 0);
        // create a mock yield source to deposit into
        yieldSource = new MockYieldSource(address(asset));

        // Deploy strategy and set variables
        strategy = IMockStrategy(setUpStrategy());

        // label all the used addresses for traces
        vm.label(management, "management");
        vm.label(keeper, "keeper");
        vm.label(protocolFeeRecipient, "protocolFeeRecipient");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
        vm.label(address(asset), "asset");
        vm.label(address(strategy), "strategy");
        vm.label(address(BaseLibrary), "library");
        vm.label(address(diamondHelper), "Diamond heleper");
        vm.label(address(yieldSource), "Mock Yield Source");
        vm.label(address(mockFactory), "mock Factory");
    }

    function mintAndDepositIntoStrategy(address _user, uint256 _amount) public {
        asset.mint(_user, _amount);
        vm.prank(_user);
        asset.approve(address(strategy), _amount);

        vm.prank(_user);
        strategy.deposit(_amount, _user);
    }

    function checkStrategyTotals(
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle,
        uint256 _totalSupply
    ) public {
        assertEq(strategy.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(strategy.totalDebt(), _totalDebt, "!totalDebt");
        assertEq(strategy.totalIdle(), _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
        // We give supply a buffer or 1 wei for rounding
        assertApproxEq(strategy.totalSupply(), _totalSupply, 1, "!supply");
    }

    // For checks without totalSupply while profit is unlocking
    function checkStrategyTotals(
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        assertEq(strategy.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(strategy.totalDebt(), _totalDebt, "!totalDebt");
        assertEq(strategy.totalIdle(), _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function createAndCheckProfit(
        uint256 profit,
        uint256 _protocolFees,
        uint256 _performanceFees
    ) public {
        uint256 startingAssets = strategy.totalAssets();
        asset.mint(address(strategy), profit);

        // Check the event matches the expected values
        vm.expectEmit(true, true, true, true, address(strategy));
        emit BaseLibrary.Reported(profit, 0, _performanceFees, _protocolFees);

        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = strategy.report();

        assertEq(profit, _profit, "profit reported wrong");
        assertEq(_loss, 0, "Reported loss");
        assertEq(
            strategy.totalAssets(),
            startingAssets + profit,
            "total assets wrong"
        );
    }

    function createAndCheckLoss(
        uint256 loss,
        uint256 _protocolFees,
        uint256 _performanceFees
    ) public {
        uint256 startingAssets = strategy.totalAssets();

        yieldSource.simulateLoss(loss);
        // Check the event matches the expected values
        vm.expectEmit(true, true, false, true, address(strategy));
        emit BaseLibrary.Reported(0, loss, _performanceFees, _protocolFees);

        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = strategy.report();

        assertEq(0, _profit, "profit reported wrong");
        assertEq(_loss, loss, "Reported loss");
        assertEq(
            strategy.totalAssets(),
            startingAssets - loss,
            "total assets wrong"
        );
    }

    function increaseTimeAndCheckBuffer(uint256 _time, uint256 _buffer) public {
        skip(_time);
        // We give a buffer or 1 wei for rounding
        assertApproxEq(
            strategy.balanceOf(address(strategy)),
            _buffer,
            1,
            "!Buffer"
        );
    }

    function getSelectors() public pure returns (bytes4[] memory selectors) {
        string[42] memory _selectors = [
            "dd62ed3e",
            "095ea7b3",
            "70a08231",
            "07a2d13a",
            "c6e6f592",
            "a457c2d7",
            "6e553f65",
            "39509351",
            "534021b0",
            "94bf804d",
            "ef8b30f7",
            "b3d7f6b9",
            "4cdad506",
            "0a28a477",
            "ba087652",
            "969b1cdb",
            "01e1d114",
            "18160ddd",
            "a9059cbb",
            "23b872dd",
            "b460af94",
            "dd62ed3e",
            "095ea7b3",
            "70a08231",
            "07a2d13a",
            "c6e6f592",
            "a457c2d7",
            "6e553f65",
            "39509351",
            "534021b0",
            "94bf804d",
            "ef8b30f7",
            "b3d7f6b9",
            "4cdad506",
            "0a28a477",
            "ba087652",
            "969b1cdb",
            "01e1d114",
            "18160ddd",
            "a9059cbb",
            "23b872dd",
            "b460af94"
        ];
        selectors = new bytes4[](_selectors.length);
        for (uint256 i; i < _selectors.length; ++i) {
            selectors[i] = bytes4(bytes(_selectors[i]));
        }
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        mockFactory.setFee(_protocolFee);
        vm.prank(management);

        strategy.setPerformanceFee(_performanceFee);
    }

    function setUpStrategy() public returns (address) {
        // we save the mock base strategy as a IBaseLibrary to give it the needed interface
        IMockStrategy _strategy = IMockStrategy(
            address(new MockStrategy(address(asset), address(yieldSource)))
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setManagement(management);

        return address(_strategy);
    }

    function setUpIlliquidStrategy() public returns (address) {
        IMockStrategy _strategy = IMockStrategy(
            address(
                new MockIlliquidStrategy(address(asset), address(yieldSource))
            )
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setManagement(management);

        return address(_strategy);
    }

    function setUpFaultyStrategy() public returns (address) {
        IMockStrategy _strategy = IMockStrategy(
            address(
                new MockFaultyStrategy(address(asset), address(yieldSource))
            )
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setManagement(management);

        return address(_strategy);
    }

    function setupWhitelist(address _address) public {
        MockIlliquidStrategy _strategy = MockIlliquidStrategy(
            payable(address(strategy))
        );

        _strategy.setWhitelist(true);

        _strategy.allow(_address);
    }

    function configureFaultyStrategy(uint256 _fault, bool _callBack) public {
        MockFaultyStrategy _strategy = MockFaultyStrategy(
            payable(address(strategy))
        );

        _strategy.setFaultAmount(_fault);
        _strategy.setCallBack(_callBack);
    }
}
