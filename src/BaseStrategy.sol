// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.14;

// Generic OpenZeppelin Dependencies
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Custom Base Strategy interfacies
import {IBaseStrategy} from "./interfaces/IBaseStrategy.sol";
import {IBaseLibrary} from "./interfaces/IBaseLibrary.sol";

import "forge-std/console.sol";

abstract contract BaseStrategy is IBaseStrategy {
    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlySelf() {
        _onlySelf();
        _;
    }

    modifier onlyManagement() {
        BaseLibrary.isManagement();
        _;
    }

    modifier onlyKeepers() {
        BaseLibrary.isKeeperOrManagement();
        _;
    }

    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTANTS /IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * This is the address of the BaseLibrary that will be used by all
     * strategies to handle the accounting, logic, storage etc.
     *
     * Any external calls to the strategy that don't hit one of the functions
     * defined in the implementation will end up going to the fallback
     * function, which will delegateCall this address.
     *
     * This address should be the same for every strategy, never be adjusted
     * and always be checked before any integration with the implementation.
     */
    // NOTE: This will be set to internal constants once the library has actually been deployed
    address public baseLibraryAddress =
        0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    /**
     * This can be used to retrieve storage data within the implementation
     * contract as if it were a linked library.
     *
     *       i.e. uint256 totalAssets = BaseLibrary.totalAssets()
     *
     * We use this so that there does not have to be a library actually linked
     * to the strategy when deployed that would rarely be used and only for
     * reading storage. It also standardizies all Base Library interaction.
     *
     * Using address(this) will mean any calls using this variable will lead
     * to a static call to itself. Which will hit the fallback function and
     * delegateCall that to the actual BaseLibrary.
     */
    IBaseLibrary internal immutable BaseLibrary = IBaseLibrary(address(this));

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    // Underlying asset the Strategy is earning yield on
    address public asset;

    // The decimals of the underlying asset we will use.
    // Keep this private with a getter function so it can be easily
    // accessed by strategists but not updated.
    uint8 private _decimals;

    constructor(address _asset, string memory _name) {
        _initialize(_asset, _name, msg.sender);
    }

    function initialize(
        address _asset,
        string memory _name,
        address _management
    ) external {
        _initialize(_asset, _name, _management);
    }

    // TODO: ADD additional variables for keeper performance fee etc?
    function _initialize(
        address _asset,
        string memory _name,
        address _management
    ) internal {
        // make sure we have not been initialized
        require(asset == address(0), "!init");

        // set ERC20 variables
        asset = _asset;
        IERC20Metadata a = IERC20Metadata(_asset);
        _decimals = a.decimals();

        string memory _symbol = string(abi.encodePacked("ys", a.symbol()));

        // initilize the strategies storage variables
        _init(_asset, _name, _symbol, _management);
    }

    /*//////////////////////////////////////////////////////////////
                        BASELIBRARY HOOKS
    //////////////////////////////////////////////////////////////*/

    // These function are left external so they can be called by the BaseLibrary during a delegateCall.     \\
    // If the library calls an external function of another contract the msg.sender will be the original    \\
    // contract that delegate called the library. Therefore msg.sender will be the strategy itself.         \\

    /**
     * @notice Should invest up to '_amount' of 'asset'.
     * @dev Callback for the library to call during a deposit, mint or report to tell the strategy it can invest funds.
     *
     * This can only be called after a 'deposit', 'mint' or 'report' delegateCall to the library so msg.sender == address(this).
     *
     * Both permisionless deposits and permissioned reports will lead to this function being called with all currently idle funds sent as '_assets'.
     * The '_reported' bool is how to differeniate between the two. If true this means it was called at the end of a report with the expectation of coming
     * through a trusted relay and therefore safe to perform otherwise manipulatable transactions.
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt to deposit in the yield source.
     * @param _reported Bool repersenting if this is part of a permissined 'report'.
     */
    function invest(uint256 _amount, bool _reported) external onlySelf {
        _invest(_amount, _reported);
    }

    /**
     * @notice Will attempt to free the '_amount' of 'asset'.
     * @dev Callback for the library to call during a withdraw or redeem to free the needed funds to service the withdraw.
     *
     * This can only be called after a 'withdraw' or 'redeem' delegateCall to the library so msg.sender == address(this).
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt to free up.
     */
    function freeFunds(uint256 _amount) external onlySelf {
        _freeFunds(_amount);
    }

    /**
     * @notice Returns the accurate amount of all funds currently held by the Strategy.
     * @dev Callback for the library to call during a report to get an accurate accounting of assets the strategy controls.
     *
     * This can only be called after a report() delegateCall to the library so msg.sender == address(this).
     *
     * @return _invested A trusted and accurate account for the total amount of 'asset' the strategy currently holds.
     */
    function totalInvested() external onlySelf returns (uint256 _invested) {
        return _totalInvested();
    }

    /**
     * @notice Will call the internal '_tend' when a keeper tends the strategy.
     * @dev Callback for the library to initiate a _tend call in the strategy.
     * This can only be called after a tend() delegateCall to the library so msg.sender == address(this).
     * @param _totalIdle The amount of current idle funds that can be invested during the tend
     */
    function tendThis(uint256 _totalIdle) external onlySelf {
        _tend(_totalIdle);
    }

    /*//////////////////////////////////////////////////////////////
                    NEEDED TO OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Should invest up to '_amount' of 'asset'.
     * @dev Should do any needed parameter checks. 0 may be passed in as '_amount'.
     *
     * Both permisionless deposits and permissioned reports will lead to this function being called with all currently idle funds sent as '_amount'.
     * The '_reported' bool is how to differeniate between the two. If true this means it was called at the end of a report with the potential of coming
     * through a trusted relay and therefore safe to perform otherwise manipulatable transactions.
     *
     * @param _amount The amount of 'asset' that the strategy should attemppt to deposit in the yield source.
     * @param _reported Bool repersenting if this is part of a permissined 'report'.
     */
    function _invest(uint256 _amount, bool _reported) internal virtual;

    /**
     * @notice Will attempt to free the '_amount' of 'asset'.
     * @dev The amount of 'asset' that is already loose has already been accounted for.
     *
     * Should do any needed parameter checks, '_amount' may be more than is actually available.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than for diff accounting puroposes.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal virtual;

    /**
     * @notice Internal non-view function to return the accurate amount of funds currently held by the Strategy
     * @dev This should do any needed harvesting, rewards selling, accrual etc. to get the most accurate view of current assets.
     *
     * This can leave any or all assets uninvested if desired as there will always be a _invest() call at the end of the report
     * with '_reported' set as true to differentiate between a normal deposit.
     *
     * Care should be taken when relying on oracles or swap values rather than actual amounts as all Strategy profit/loss accounting
     * will be done based on this returned value.
     *
     * All applicable assets including loose assets should be accounted for in this function.
     *
     * @return _invested A trusted and accurate account for the total amount of 'asset' the strategy currently holds.
     */
    function _totalInvested() internal virtual returns (uint256 _invested);

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Optional function for strategist to override that can be called in between reports.
     * @dev If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a persionned role so may be through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds, perform needed
     * poisition maintence or anything else that doesn't need a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting sandwhiched
     *   can use the tend when a certain threshold of idle to totalAssets has been reached.
     *
     * The library will do all needed debt and idle updates after this has finished
     * and will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to invest.
     */
    function _tend(uint256 _totalIdle) internal virtual {}

    /**
     * @notice Returns wether or not tend() should be called by a keeper.
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function tendTrigger() external view virtual returns (bool) {
        return false;
    }

    // NOTE: these functions are kept in the Base to give strategists
    // the ability to override them to limit deposit or withdraws for
    // andy strategies that want to implement deposit limts, whitelists, illiquid strategies etc.

    function availableDepositLimit(
        address /*_owner*/
    ) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     */
    function decimals() public view returns (uint8) {
        return _decimals;
    }

    // NOTE: We cannot use the `BaseLibrary` call since this contract is not deployed fully yet
    // So we need to manually delegateCall the library.
    // This is the only time an internal delegateCall should not be for a view function
    function _init(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management
    ) private {
        (bool success, ) = baseLibraryAddress.delegatecall(
            abi.encodeWithSignature(
                "init(address,string,string,address)",
                _asset,
                _name,
                _symbol,
                _management
            )
        );

        require(success, "init failed");
    }

    // exeute a function on the baseLibrary and return any value.
    fallback() external payable {
        // load our target address
        address _baseLibraryAddress = baseLibraryAddress;
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(
                gas(),
                _baseLibraryAddress,
                0,
                calldatasize(),
                0,
                0
            )
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {}
}
