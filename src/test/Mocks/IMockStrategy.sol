// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.14;

import {IBaseLibrary} from "../../interfaces/IBaseLibrary.sol";

// Interface to use during testing that implements the 4626 standard the Library functions and the Strategies immutable functions
interface IMockStrategy is IBaseLibrary {
    function initialize(
        address _asset,
        string memory name_,
        address _management
    ) external;

    function availableDepositLimit(
        address _owner
    ) external view returns (uint256);

    function availableWithdrawLimit(
        address _owner
    ) external view returns (uint256);

    function invest(uint256 _assets, bool _reported) external;

    function freeFunds(uint256 _amount) external;

    function totalInvested() external returns (uint256);

    function tendThis(uint256 _totalIdle) external;
}
