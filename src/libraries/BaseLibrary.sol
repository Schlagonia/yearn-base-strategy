// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.14;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {DiamondHelper, IDiamond, IDiamondLoupe} from "../DiamondHelper.sol";

import {IBaseStrategy} from "../interfaces/IBaseStrategy.sol";

interface IFactory {
    function protocol_fee_config()
        external
        view
        returns (uint16, uint32, address);
}

import "forge-std/console.sol";

/// TODO:
//       Bump sol version
//      Does base strategy need to hold errors and events?
//      add unchecked {} where applicable
//      add cloning
//      Add support interface for IERC165 https://github.com/mudgen/diamond-2-hardhat/blob/main/contracts/interfaces/IERC165.sol
//      Should storage stuct and variable be in its own contract. So it can be imported without accidently linking the library
//      Add reentrancy gaurds?
//      unsafe math library for easy unchecked

library BaseLibrary {
    using SafeERC20 for ERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted whent the 'mangement' address is updtaed to 'newManagement'.
     */
    event UpdateManagement(address indexed newManagement);

    /**
     * @notice Emitted whent the 'keeper' address is updtaed to 'newKeeper'.
     */
    event UpdateKeeper(address indexed newKeeper);

    /**
     * @notice Emitted whent the 'performaneFee' is updtaed to 'newPerformanceFee'.
     */
    event UpdatePerformanceFee(uint16 newPerformanceFee);

    /**
     * @notice Emitted whent the 'performanceFeeRecipient' address is
     * updtaed to 'newPerformanceFeeRecipient'.
     */
    event UpdatePerformanceFeeRecipient(
        address indexed newPerformanceFeeRecipient
    );

    /**
     * @notice Emitted whent the 'profitMaxUnlockTime' is updtaed to 'newProfitMaxUnlockTime'.
     */
    event UpdateProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Reported(
        uint256 profit,
        uint256 loss,
        uint256 performanceFees,
        uint256 protocolFees
    );

    event DiamondCut(
        IDiamond.FacetCut[] _diamondCut,
        address _init,
        bytes _calldata
    );

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                        STORAGE STRUCT
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The struct that will hold all the data for each implementation
     * strategy that uses the library.
     *
     * This replaces all state variables for a traditional contract. This
     * full struct will be initiliazed on the createion of the implemenation
     * contract and continually updated and read from for the life f the contract.
     *
     * We combine all the variables into one struct to limit the amount of times
     * custom storage slots need to be loadded during complex functions.
     *
     * Loading the corresponding storage slot for the struct into memory
     * does not load any of the contents of the struct into memory. So
     * the size has no effect on gas usage.
     */
    // TODO: this should be able to be packed better
    // prettier-ignore
    struct BaseStrategyData {
        // The ERC20 compliant underlying asset that will be
        // used by the implementation contract.
        ERC20 asset;
        

        // These are the corresponding ERC20 variables needed for the
        // token that is issued and burned on each deposit or withdraw.
        string name; // The name of the token for the strategy.
        string symbol; // The symbol of the token for the strategy.
        uint256 totalSupply; // The total amount of shares currently issued
        uint256 INITIAL_CHAIN_ID; // The intitial chain id when the strategy was created.
        bytes32 INITIAL_DOMAIN_SEPARATOR; // The domain seperator used for permits on the intitial chain.
        mapping(address => uint256) nonces; // Mapping of nonces used for permit functions.
        mapping(address => uint256) balances; // Mapping to track current balances for each account that holds shares.
        mapping(address => mapping(address => uint256)) allowances; // Mapping to track the allowances for the strategies shares.
        

        // Assets data to track totals the strategy holds.
        uint256 totalIdle; // The total amount of loose `asset` the strategy holds.
        uint256 totalDebt; // The total amount `asset` that is currently deployed by the strategy
        

        // Variables for profit reporting and locking
        uint256 fullProfitUnlockDate; // The timestamp at which all locked shares will unlock.
        uint256 profitUnlockingRate; // The rate at which locked profit is unlocking.
        uint256 profitMaxUnlockTime; // The amount of seconds that the reported profit unlocks over.
        uint256 lastReport; // The last time a {report} was called.
        uint16 performanceFee; // The percent in Basis points of profit that is charged as a fee.
        address performanceFeeRecipient; // The address to pay the `performanceFee` to.
        bool reporting; // Bool to prevent reentrancy during report calls
        

        // Access management addressess for permisssioned functions.
        address management; // Main address that can set all configurable variables.
        address keeper; // Address given permission to call {report} and {tend}.
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier notReporting() {
        isNotReporting();
        _;
    }

    modifier onlyManagement() {
        isManagement();
        _;
    }

    modifier onlyKeepers() {
        isKeeperOrManagement();
        _;
    }

    // These are left public to allow for the strategy to use them as well

    function isNotReporting() public view {
        require(!_baseStrategyStorgage().reporting, "!reporting");
    }

    function isManagement() public view {
        if (msg.sender != _baseStrategyStorgage().management)
            revert Unauthorized();
    }

    function isKeeperOrManagement() public view {
        BaseStrategyData storage S = _baseStrategyStorgage();
        if (msg.sender != S.management && msg.sender != S.keeper)
            revert Unauthorized();
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANT
    //////////////////////////////////////////////////////////////*/

    string private constant API_VERSION = "3.1.0";

    // NOTE: holder address based on expected location during tests
    address private constant diamondHelper =
        0xFEfC6BAF87cF3684058D62Da40Ff3A795946Ab06;

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    // Factory address NOTE: This will be set to deployed factory.
    // deterministic address for testing is used now
    // TODO: how to account for protocol fees when the strategy is empty
    address private constant FACTORY =
        0x2a9e8fa175F45b235efDdD97d2727741EF4Eee63;

    /**
     * @dev Custom storgage slot that will be used to store the
     * `BaseStrategyData` struct that holds each strategies
     * specific storage variables.
     *
     * Any storage updates done by the library actually update
     * the storage of the calling contract. This variable points
     * to the specic location that will be used to store the
     * struct that holds all that data.
     *
     * We intentionally use large strings in order to get high
     * slots that that should allow for stratgists to use any
     * amount of storage in the implementations without worrying
     * about collisions. This storage slot sits at roughly 1e77.
     */
    bytes32 private constant BASE_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("yearn.base.strategy.storage")) - 1);

    /*//////////////////////////////////////////////////////////////
                    STORAGE GETTER FUNCTION
    //////////////////////////////////////////////////////////////*/

    function _baseStrategyStorgage()
        private
        pure
        returns (BaseStrategyData storage S)
    {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = BASE_STRATEGY_STORAGE;
        assembly {
            S.slot := slot
        }
    }

    /*//////////////////////////////////////////////////////////////
                INITILIZATION OF DEFAULT STORAGE
    //////////////////////////////////////////////////////////////*/

    function init(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management
    ) external {
        // cache storage pointer
        BaseStrategyData storage S = _baseStrategyStorgage();

        // make sure we aren't initiliazed
        require(address(S.asset) == address(0), "!init");
        // set the strategys underlying asset
        S.asset = ERC20(_asset);
        // Set the Tokens name and symbol
        S.name = _name;
        S.symbol = _symbol;
        // Set initial chain id for permit replay protection
        S.INITIAL_CHAIN_ID = block.chainid;
        // Set the inital domain seperator for permit functions
        S.INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();

        // set the default management address
        S.management = _management;

        // default to a 10 day profit unlock period
        S.profitMaxUnlockTime = 10 days;
        // default to mangement as the treasury TODO: allow this to be customized
        S.performanceFeeRecipient = _management;
        // default to a 10% performance fee?
        S.performanceFee = 1_000;
        // set last report to this block
        S.lastReport = block.timestamp;

        // emit the standard DiamondCut event with the values from our helper contract
        emit DiamondCut(
            // struct containing the address of the library, the add enum and array of all function selectors
            DiamondHelper(diamondHelper).diamondCut(),
            // init address to call if applicable
            address(0),
            // call data to send the init address if applicable
            new bytes(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(
        uint256 assets,
        address receiver
    ) public notReporting returns (uint256 shares) {
        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        _deposit(receiver, assets, shares);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public notReporting returns (uint256 assets) {
        // No need to check for rounding error, previewMint rounds up.
        assets = previewMint(shares);

        _deposit(receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public notReporting returns (uint256 shares) {
        // No need to check for rounding error, previewWithdraw rounds up.
        shares = previewWithdraw(assets);

        _withdraw(receiver, owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public notReporting returns (uint256 assets) {
        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        _withdraw(receiver, owner, assets, shares);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Down);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Down);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? shares
                : shares.mulDiv(totalAssets(), supply, Math.Rounding.Up);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply(); // Saves an extra SLOAD if totalSupply() is non-zero.

        return
            supply == 0
                ? assets
                : assets.mulDiv(supply, totalAssets(), Math.Rounding.Up);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function maxDeposit(address _owner) public view returns (uint256) {
        return IBaseStrategy(address(this)).availableDepositLimit(_owner);
    }

    function maxMint(address _owner) public view returns (uint256 _maxMint) {
        _maxMint = IBaseStrategy(address(this)).availableDepositLimit(_owner);
        if (_maxMint != type(uint256).max) {
            _maxMint = convertToShares(_maxMint);
        }
    }

    function maxWithdraw(
        address _owner
    ) public view returns (uint256 _maxWithdraw) {
        _maxWithdraw = IBaseStrategy(address(this)).availableWithdrawLimit(
            _owner
        );
        if (_maxWithdraw == type(uint256).max) {
            // Saves a min check if there is no withdrawal limit.
            _maxWithdraw = convertToAssets(balanceOf(_owner));
        } else {
            _maxWithdraw = Math.min(
                convertToAssets(balanceOf(_owner)),
                _maxWithdraw
            );
        }
    }

    function maxRedeem(
        address _owner
    ) public view returns (uint256 _maxRedeem) {
        _maxRedeem = IBaseStrategy(address(this)).availableWithdrawLimit(
            _owner
        );
        // Conversion would overflow and saves a min check if there is no withdrawal limit.
        if (_maxRedeem == type(uint256).max) {
            _maxRedeem = balanceOf(_owner);
        } else {
            _maxRedeem = Math.min(
                convertToShares(_maxRedeem),
                balanceOf(_owner)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        BaseStrategyData storage S = _baseStrategyStorgage();
        return S.totalIdle + S.totalDebt;
    }

    function totalSupply() public view returns (uint256) {
        return _baseStrategyStorgage().totalSupply - _unlockedShares();
    }

    /**
     * @dev Function to be called during {deposit} and {mint} after
     * all neccesary checks have been completed.
     *
     * This function handles all logic including transfers, minting and accounting.
     *
     * We do all external calls before updating any internal values to prevent
     * re-entrancy from the token transfers or the _invest() calls.
     */
    function _deposit(
        address receiver,
        uint256 assets,
        uint256 shares
    ) private {
        require(receiver != address(this), "ERC4626: mint to self");
        require(
            assets <= maxDeposit(msg.sender),
            "ERC4626: deposit more than max"
        );

        // Cache storage variables used more than once.
        BaseStrategyData storage S = _baseStrategyStorgage();
        ERC20 _asset = S.asset;

        // Need to transfer before minting or ERC777s could reenter.
        _asset.safeTransferFrom(msg.sender, address(this), assets);

        // We will deposit up to current idle plus the new amount added
        uint256 toInvest = S.totalIdle + assets;

        // Cache for post {invest} checks.
        uint256 beforeBalance = _asset.balanceOf(address(this));

        // Invest up to all loose funds. Signal its during a permisionless deposit.
        IBaseStrategy(address(this)).invest(toInvest, false);

        // Always get the actual amount invested for complete accuracy
        // We double check the diff agianst toInvest to never underflow
        uint256 invested = Math.min(
            beforeBalance - _asset.balanceOf(address(this)),
            toInvest
        );

        // Adjust total Assets.
        unchecked {
            // Can't overflow, or the preview conversions would too.
            S.totalDebt += invested;
            // Cant't underflow due to previous min check.
            S.totalIdle = toInvest - invested;
        }

        // mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev To be called after all neccesary checks have been done in
     * {redeem} and {withdraw}.
     *
     * This will handle all logic, transfers and accounting in order to
     * service the withdraw request.
     *
     * If we are not able to withdraw the full amount needed, it will
     * be counted as a loss and passed on to the user.
     */
    function _withdraw(
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) private {
        require(shares <= maxRedeem(owner), "ERC4626: withdraw more than max");

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        BaseStrategyData storage S = _baseStrategyStorgage();
        // Expected beharvior is to need to free funds so we cache `_asset`.
        ERC20 _asset = S.asset;

        uint256 idle = S.totalIdle;

        if (idle < assets) {
            // We need to withdraw funds

            // Cache before balance for diff checks.
            uint256 before = _asset.balanceOf(address(this));
            // Tell implementation to free what we need.
            unchecked {
                IBaseStrategy(address(this)).freeFunds(assets - idle);
            }
            // Return the actual amount withdrawn. Adjust for potential overwithdraws.
            // TODO: Add an if check here so were only pulling from storage if neccesary?
            uint256 withdrawn = Math.min(
                _asset.balanceOf(address(this)) - before,
                S.totalDebt
            );

            unchecked {
                idle += withdrawn;
            }

            uint256 loss;
            // If we didn't get enough out then we have a loss
            if (idle < assets) {
                unchecked {
                    loss = assets - idle;
                }
                assets = idle;
            }

            // Update debt storage.
            S.totalDebt -= (withdrawn + loss);
        }

        // Update idle based on how much we took
        S.totalIdle = idle - assets;

        _burn(owner, shares);

        _asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT LOCKING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Function for keepers to call to harvest and record all profits accrued.
     * @dev This should only ever be called through protected relays as swaps will likely occur.
     *
     * This will account for any gains/losses since the last report and charge fees accordingly.
     *
     * Any profit over the totalFees charged will be immediatly locked so there is no change in PricePerShare.
     * Then slowly unlocked over the 'maxProfitUnlockTime' each second based on the calculated 'profitUnlockingRate'.
     *
     * Any 'loss' or fees greater than 'profit' will attempted to be offset with any remaining locked shares from the last
     * report in order to reduce any negative impact to PPS.
     *
     * Will then recalculate the new time to unlock profits over and the rate based on a weighted average of any remaining time from the last
     * report and the new amount of shares to be locked.
     *
     * Finally will tell the strategy to _invest all idle funds which should include both the totalIdle before the call as well
     * any amount of 'asset' freed up during the totalInvested() call.
     *
     * @return profit The notional amount of gain since the last report in terms of 'asset' if any.
     * @return loss The notional amount of loss since the last report in terms of "asset" if any.
     */
    function report()
        external
        notReporting
        onlyKeepers
        returns (uint256 profit, uint256 loss)
    {
        // Cache storage pointer since its used again at the end
        BaseStrategyData storage S = _baseStrategyStorgage();
        // set reporting = True for reentrancy
        S.reporting = true;

        uint256 oldTotalAssets;
        unchecked {
            // Manuaully calculate totalAssets to save an SLOAD
            oldTotalAssets = S.totalIdle + S.totalDebt;
        }

        // Calculate protocol fees before we burn shares and update lastReport
        (
            uint256 totalFees,
            address protocolFeesRecipient
        ) = _assessProtocolFees(oldTotalAssets);

        // burn unlocked shares
        _burnUnlockedShares();

        // Tell the strategy to report the real total assets it has.
        // It should account for invested and loose 'asset' so we can accuratly update the totalIdle to account
        // for sold but non-reinvested funds during reward harvesting.
        uint256 _invested = IBaseStrategy(address(this)).totalInvested();

        uint256 performanceFees;

        // Calculate profit/loss
        if (_invested > oldTotalAssets) {
            // We have a profit
            profit = _invested - oldTotalAssets;

            // Asses performance fees
            performanceFees = (profit * S.performanceFee) / MAX_BPS;
            totalFees += performanceFees;
        } else {
            // We have a loss
            loss = oldTotalAssets - _invested;
        }

        // We need to get the shares for fees to issue at current PPS before any minting or burning
        uint256 sharesForFees = convertToShares(totalFees);
        uint256 sharesToLock;
        if (loss + totalFees >= profit) {
            // We have a net loss
            // Will try and unlock the difference between between the gain and the loss
            uint256 sharesToBurn = Math.min(
                convertToShares((loss + totalFees) - profit), // Check vault code
                balanceOf(address(this))
            );

            if (sharesToBurn > 0) {
                _burn(address(this), sharesToBurn);
            }
        } else {
            // we have a net profit
            // lock (profit - fees)
            sharesToLock = convertToShares(profit - totalFees);
            _mint(address(this), sharesToLock);
        }

        // Mint fees shares.
        if (sharesForFees > 0) {
            uint256 performanceFeeShares = (sharesForFees * performanceFees) /
                totalFees;
            if (performanceFeeShares > 0) {
                _mint(S.performanceFeeRecipient, performanceFeeShares);
            }

            if (sharesForFees - performanceFeeShares > 0) {
                _mint(
                    protocolFeesRecipient,
                    sharesForFees - performanceFeeShares
                );
            }
        }

        {
            // Scoped to avoid stack to deep errors
            uint256 remainingTime;
            uint256 _fullProfitUnlockDate = S.fullProfitUnlockDate;
            if (_fullProfitUnlockDate > block.timestamp) {
                remainingTime = _fullProfitUnlockDate - block.timestamp;
            }

            // Update unlocking rate and time to fully unlocked
            uint256 totalLockedShares = balanceOf(address(this));
            uint256 _profitMaxUnlockTime = S.profitMaxUnlockTime;
            if (totalLockedShares > 0 && _profitMaxUnlockTime > 0) {
                uint256 previouslyLockedShares = totalLockedShares -
                    sharesToLock;

                // new_profit_locking_period is a weighted average between the remaining
                // time of the previously locked shares and the PROFIT_MAX_UNLOCK_TIME
                uint256 newProfitLockingPeriod = (previouslyLockedShares *
                    remainingTime +
                    sharesToLock *
                    _profitMaxUnlockTime) / totalLockedShares;

                S.profitUnlockingRate =
                    (totalLockedShares * MAX_BPS_EXTENDED) /
                    newProfitLockingPeriod;

                S.fullProfitUnlockDate =
                    block.timestamp +
                    newProfitLockingPeriod;
            } else {
                // NOTE: only setting this to 0 will turn in the desired effect,
                // no need to update fullProfitUnlockDate
                S.profitUnlockingRate = 0;
            }
        }

        // Update last report before external calls
        S.lastReport = block.timestamp;

        // Emit event with info
        emit Reported(
            profit,
            loss,
            performanceFees,
            totalFees - performanceFees // Protocol fees
        );

        // We need to update storage here for potential view reentrancy during
        // the external {invest} call so pps is not distorted.
        // NOTE: We could save an extra SSTORE here by only updating S.totalDebt = S.totalDebt + profit - loss. But reentrancy withdraws could break?
        uint256 newIdle = S.asset.balanceOf(address(this));
        S.totalIdle = newIdle;
        S.totalDebt = _invested - newIdle;

        // invest any idle funds, tell strategy it is during a report call
        IBaseStrategy(address(this)).invest(newIdle, true);

        // Update storage based on actual amounts
        newIdle = S.asset.balanceOf(address(this));
        S.totalIdle = newIdle;
        S.totalDebt = _invested - newIdle;
        // Reset reporting bool
        S.reporting = false;
    }

    function _assessProtocolFees(
        uint256 _oldTotalAssets
    )
        private
        view
        returns (uint256 protocolFees, address protocolFeesRecipient)
    {
        (
            uint16 protocolFeeBps,
            uint32 protocolFeeLastChange,
            address _protocolFeesRecipient
        ) = IFactory(FACTORY).protocol_fee_config();

        if (protocolFeeBps > 0) {
            protocolFeesRecipient = _protocolFeesRecipient;
            // NOTE: charge fees since last report OR last fee change
            // (this will mean less fees are charged after a change in protocol_fees, but fees should not change frequently)
            uint256 secondsSinceLastReport = Math.min(
                block.timestamp - _baseStrategyStorgage().lastReport,
                block.timestamp - uint256(protocolFeeLastChange)
            );

            protocolFees =
                (uint256(protocolFeeBps) *
                    _oldTotalAssets *
                    secondsSinceLastReport) /
                // TODO: make this one number for less runtime calculations
                24 /
                365 /
                3600 /
                MAX_BPS;
        }
    }

    function _burnUnlockedShares() private {
        uint256 unlcokdedShares = _unlockedShares();
        if (unlcokdedShares == 0) {
            return;
        }

        // update variables (done here to keep _unlcokdedShares() as a view function)
        if (_baseStrategyStorgage().fullProfitUnlockDate > block.timestamp) {
            _baseStrategyStorgage().lastReport = block.timestamp;
        }

        _burn(address(this), unlcokdedShares);
    }

    function _unlockedShares() private view returns (uint256) {
        // should save 2 extra calls for most scenarios
        BaseStrategyData storage S = _baseStrategyStorgage();
        uint256 _fullProfitUnlockDate = S.fullProfitUnlockDate;
        uint256 unlockedShares;
        if (_fullProfitUnlockDate > block.timestamp) {
            unlockedShares =
                (S.profitUnlockingRate * (block.timestamp - S.lastReport)) /
                MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            unlockedShares = S.balances[address(this)];
        }

        return unlockedShares;
    }

    /*//////////////////////////////////////////////////////////////
                        TENDING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice For a 'keeper' to 'tend' the strategy if a custom tendTrigger() is implemented.
     * @dev Both 'tendTrigger' and '_tend' will need to be overridden for this to be used.
     *
     * This will callback the internal '_tend' call in the BaseStrategy with the total current
     * amount available to the strategy to invest.
     *
     * Keepers are expected to use protected relays in tend calls so this can be used for illiquid
     * or manipulatable strategies to compound rewards, perform maintence or invest/withdraw funds.
     *
     * All accounting for totalDebt and totalIdle updates will be done here post '_tend'.
     *
     * This should never cause an increase in PPS. Total assets should be the same before and after
     *
     * A report() call will be needed to record the profit.
     */
    function tend() external notReporting onlyKeepers {
        BaseStrategyData storage S = _baseStrategyStorgage();
        // Expected Behavior is this will get used twice so we cache it
        uint256 _totalIdle = S.totalIdle;
        ERC20 _asset = S.asset;

        uint256 beforeBalance = _asset.balanceOf(address(this));
        IBaseStrategy(address(this)).tendThis(_totalIdle);
        uint256 afterBalance = _asset.balanceOf(address(this));

        // Adjust storage according to the changes without adjusting totalAssets().
        if (beforeBalance > afterBalance) {
            // Idle funds were deposited.
            uint256 invested = Math.min(
                beforeBalance - afterBalance,
                _totalIdle
            );
            S.totalIdle -= invested;
            S.totalDebt += invested;
        } else if (afterBalance > beforeBalance) {
            // We default to use any funds freed as idle for cheaper withdraw/redeems.
            uint256 harvested = Math.min(
                afterBalance - beforeBalance,
                S.totalDebt
            );
            S.totalIdle += harvested;
            S.totalDebt -= harvested;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Getter FUNCIONS
    //////////////////////////////////////////////////////////////*/

    // External view function to pull public variables from storage

    /**
     * @notice Get the api version for this Library.
     */
    function apiVersion() external pure returns (string memory) {
        return API_VERSION;
    }

    function totalIdle() external view returns (uint256) {
        return _baseStrategyStorgage().totalIdle;
    }

    function totalDebt() external view returns (uint256) {
        return _baseStrategyStorgage().totalDebt;
    }

    function management() external view returns (address) {
        return _baseStrategyStorgage().management;
    }

    function keeper() external view returns (address) {
        return _baseStrategyStorgage().keeper;
    }

    function performanceFee() external view returns (uint16) {
        return _baseStrategyStorgage().performanceFee;
    }

    function performanceFeeRecipient() external view returns (address) {
        return _baseStrategyStorgage().performanceFeeRecipient;
    }

    function fullProfitUnlockDate() external view returns (uint256) {
        return _baseStrategyStorgage().fullProfitUnlockDate;
    }

    function profitUnlockingRate() external view returns (uint256) {
        return _baseStrategyStorgage().profitUnlockingRate;
    }

    function profitMaxUnlockTime() external view returns (uint256) {
        return _baseStrategyStorgage().profitMaxUnlockTime;
    }

    function lastReport() external view returns (uint256) {
        return _baseStrategyStorgage().lastReport;
    }

    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** IBaseStrategy(address(this)).decimals());
    }

    /*//////////////////////////////////////////////////////////////
                        SETTER FUNCIONS
    //////////////////////////////////////////////////////////////*/

    function setManagement(address _management) external onlyManagement {
        require(_management != address(0), "ZERO ADDRESS");
        _baseStrategyStorgage().management = _management;

        emit UpdateManagement(_management);
    }

    function setKeeper(address _keeper) external onlyManagement {
        _baseStrategyStorgage().keeper = _keeper;

        emit UpdateKeeper(_keeper);
    }

    function setPerformanceFee(uint16 _performanceFee) external onlyManagement {
        require(_performanceFee < MAX_BPS, "MAX BPS");
        _baseStrategyStorgage().performanceFee = _performanceFee;

        emit UpdatePerformanceFee(_performanceFee);
    }

    function setPerformanceFeeRecipient(
        address _performanceFeeRecipient
    ) external onlyManagement {
        require(_performanceFeeRecipient != address(0), "ZERO ADDRESS");
        _baseStrategyStorgage()
            .performanceFeeRecipient = _performanceFeeRecipient;

        emit UpdatePerformanceFeeRecipient(_performanceFeeRecipient);
    }

    function setProfitMaxUnlockTime(
        uint256 _profitMaxUnlockTime
    ) external onlyManagement {
        _baseStrategyStorgage().profitMaxUnlockTime = _profitMaxUnlockTime;

        emit UpdateProfitMaxUnlockTime(_profitMaxUnlockTime);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL ERC-2535 VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets all facet addresses and their four byte function selectors.
     * @return facets_ Facet
     */
    function facets() external view returns (IDiamondLoupe.Facet[] memory) {
        return DiamondHelper(diamondHelper).facets();
    }

    /**
     * @notice Gets all the function selectors supported by a specific facet.
     * @param _facet The facet address.
     * @return facetFunctionSelectors_
     */
    function facetFunctionSelectors(
        address _facet
    ) external view returns (bytes4[] memory) {
        return DiamondHelper(diamondHelper).facetFunctionSelectors(_facet);
    }

    /**
     * @notice Get all the facet addresses used by a diamond.
     * @return facetAddresses_
     */
    function facetAddresses() external view returns (address[] memory) {
        return DiamondHelper(diamondHelper).facetAddresses();
    }

    /**
     * @notice Gets the facet that supports the given selector.
     * @dev If facet is not found return address(0).
     * @param _functionSelector The function selector.
     * @return facetAddress_ The facet address.
     */
    function facetAddress(
        bytes4 _functionSelector
    ) external view returns (address) {
        return DiamondHelper(diamondHelper).facetAddress(_functionSelector);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the name of the token.
     * @return . The name the strategy is using for its token.
     */
    function name() public view returns (string memory) {
        return _baseStrategyStorgage().name;
    }

    /**
     * @notice Returns the symbol of the token, usually a shorter version of the name.
     * @dev Should be some iteration of 'ys + asset symbol'
     * @return . The symbol the strategy is using for its tokens.
     */
    function symbol() public view returns (string memory) {
        return _baseStrategyStorgage().symbol;
    }

    /**
     * @notice Returns the current balance for a given '_account'.
     * @dev If the '_account is the strategy then this will subtract the amount of
     * shares that have been unlocked since the last profit first.
     * @param account the address to return the balance for.
     * @return . The current balance in y shares of the '_account'.
     */
    function balanceOf(address account) public view returns (uint256) {
        if (account == address(this)) {
            return
                _baseStrategyStorgage().balances[account] - _unlockedShares();
        }
        return _baseStrategyStorgage().balances[account];
    }

    /**
     * @notice Transfer '_amount` of shares from `msg.sender` to `to`.
     * @dev
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - the caller must have a balance of at least `_amount`.
     *
     * @param to The address shares will be transferred to.
     * @param amount The amount of shares to be transferred from sender.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     * @param owner The address who owns the shares.
     * @param spender The address who would be moving the owners shares.
     * @return . The remaining amount of shares of `owner` that could be moved by `spender`.
     */
    function allowance(
        address owner,
        address spender
    ) public view returns (uint256) {
        return _baseStrategyStorgage().allowances[owner][spender];
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     * @dev
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     *
     * @param spender the address to allow the shares to be moved by.
     * @param amount the amount of shares to allow `spender` to move.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * @dev
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `to` cannot be the address of the strategy.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     *
     * Emits a {Transfer} event.
     *
     * @param from the address to be moving shares from.
     * @param to the address to be moving shares to.
     * @param amount the quantity of shares to move.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Atomically increases the allowance granted to `spender` by the caller.
     *
     * @dev This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - cannot give spender over uint256.max allowance
     *
     * @param spender the account that will be able to move the senders shares.
     * @param addedValue the extra amount to add to the current allowance.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @notice Atomically decreases the allowance granted to `spender` by the caller.
     *
     * @dev This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     *
     * @param spender the account that will be able to move less of the senders shares.
     * @param subtractedValue the amount to decrease the current allowance by.
     * @return . a boolean value indicating whether the operation succeeded.
     */
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, allowance(owner, spender) - subtractedValue);
        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `to` cannot be the strategies address
     * - `from` must have a balance of at least `amount`.
     *
     */
    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(to != address(this), "ERC20 transfer to strategy");
        BaseStrategyData storage S = _baseStrategyStorgage();

        S.balances[from] -= amount;
        unchecked {
            S.balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     *
     */
    function _mint(address account, uint256 amount) private {
        require(account != address(0), "ERC20: mint to the zero address");
        BaseStrategyData storage S = _baseStrategyStorgage();

        S.totalSupply += amount;
        unchecked {
            S.balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) private {
        require(account != address(0), "ERC20: burn from the zero address");
        BaseStrategyData storage S = _baseStrategyStorgage();

        S.balances[account] -= amount;
        unchecked {
            S.totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _baseStrategyStorgage().allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) private {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * @dev Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     *
     * @param _owner the address of the account to return the nonce for.
     * @return . the current nonce for the account.
     */
    function nonces(address _owner) external view returns (uint256) {
        return _baseStrategyStorgage().nonces[_owner];
    }

    /**
     * @notice Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * @dev IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        require(deadline >= block.timestamp, "ERC20: PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                _baseStrategyStorgage().nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(
                recoveredAddress != address(0) && recoveredAddress == owner,
                "ERC20: INVALID_SIGNER"
            );

            _approve(recoveredAddress, spender, value);
        }
    }

    /**
     * @notice Returns the domain separator used in the encoding of the signature
     * for {permit}, as defined by {EIP712}.
     *
     * @dev This checks that the current chain id is the same as when the contract was deployed to
     * prevent replay attacks. If false it will calculate a new domain seperator based on the new chain id.
     *
     * @return . The domain seperator that will be used for any {permit} calls.
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        BaseStrategyData storage S = _baseStrategyStorgage();
        return
            block.chainid == S.INITIAL_CHAIN_ID
                ? S.INITIAL_DOMAIN_SEPARATOR
                : _computeDomainSeparator();
    }

    /**
     * @dev Calculates and returns the domain seperator to be used in any
     * permit functions for the strategies {permit} calls.
     *
     * This will be used at the initilization of each new strategies storage.
     * It would then be used in the future in the case of any forks in which
     * the current chain id is not the same as the origin al.
     *
     */
    function _computeDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes(_baseStrategyStorgage().name)),
                    keccak256(bytes(API_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }
}
