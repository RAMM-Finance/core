pragma solidity ^0.8.16;
import {Instrument} from "../vaults/instrument.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {PoolConstants} from "./poolConstants.sol";
import {VaultAccount, VaultAccountingLibrary} from "./VaultAccount.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {IRateCalculator} from "./IRateCalculator.sol";
import {ReentrancyGuard} from "solmate/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Pausable} from "openzeppelin-contracts/security/Pausable.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {Vault} from "../vaults/vault.sol";
import "forge-std/console.sol";
import {ReputationManager} from "../protocol/reputationmanager.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";

// conditional lending pool
contract PoolInstrument is
    ERC4626,
    Instrument,
    PoolConstants,
    ReentrancyGuard,
    ERC721TokenReceiver
{
    using SafeTransferLib for ERC20;
    using VaultAccountingLibrary for VaultAccount;
    using FixedPointMathLib for uint256;
    // using SafeCastLib for uint256;

    /// @param lastBlock last block number
    /// @param lastTimestamp last block.timestamp
    /// @param ratePerSec rate per second of interest accrual
    struct CurrentRateInfo {
        uint64 lastBlock;
        uint64 lastTimestamp;
        uint64 ratePerSec;
    }

    /// @param lastBlock last block number
    /// @param lastTimestamp last block.timestamp
    /// @param lastUtilizationRate last utilization rate
    struct BorrowRateInfo {
        uint64 lastBlock;
        uint64 lastTimestamp;
        uint256 lastUtilizationRate;
    }

    /// @param tokenAddress collateral token address
    /// @param tokenId collateral tokenId, 0 for ERC20.
    /// @param isERC20 whether collateral is ERC20, determines liquidation mechanism used.
    struct CollateralLabel {
        address tokenAddress;
        uint256 tokenId;
        bool isERC20;
    }


    /// @param maxAmount: max amount in underlying that a user can "owe" per base unit of collateral (unit = 1 for NFTs, 1e18 for ERC20s)
    /// @param maxBorrow: max amount in underlying that a user can borrow per base unit of collateral (unit = 1 for NFTs, 1e18 for ERC20s)
    /// @param step: maxBorrow/maxAmount = (1 + step) * maxBorrow/maxAmount, in WAD precision.
    /// @param upperUtil: upperthreshold utilization rate, precision in UTIL_PREC
    /// @param lowerUtil: lowerthreshold utilization rate, precision in UTIL_PREC
    /// @param r: reputation percentile needed to borrow
    struct Config {
        uint256 maxBorrow;
        uint256 maxAmount;
        uint256 step;
        uint256 lowerUtil;
        uint256 upperUtil;
        uint256 r;
        uint256 maxDiscount; // in wad precision.
        uint256 buf; // starting price for liquidation is buf * maxAmount, in wad precision.
    }

    // CLP parameters
    Config public config;
    // amount: asset token borrowed, shares = total shares outstanding
    VaultAccount public totalBorrow;
    // amount: total asset supplied + interest earned, shares = total shares outstanding
    VaultAccount public totalAsset;

    /// NOTE: id for collateral => keccak256(abi.encodePacked(collateral, tokenId))
    // approved collateral for the pool
    mapping(bytes32 => bool) public approvedCollateral;
    // stores the balance of collateral per user. balance is 1 for nft.
    mapping(address => mapping(bytes32 => uint256)) public userCollateralBalances;
    // borrow share balance per user
    mapping(address => uint256) public userBorrowShares;
    // helper for collateral
    mapping(bytes32 => bool) private isERC20;
    // user deposited collateral, should never have collateral balance of 0 for collateral in this list.
    mapping(address => CollateralLabel[]) public userCollateral;
    // boolean for active collateral for the user
    mapping(address => mapping(bytes32=>bool)) public userCollateralBool;
    // collateral -> total collateral, decimals are whatever the collateral is in.
    mapping(bytes32 => uint256) public totalCollateral;

    IRateCalculator public rateContract;

    /// @dev depends on rateCalculator used
    bytes public rateInitCallData;

    CurrentRateInfo public currentRateInfo;
    BorrowRateInfo public borrowRateInfo;

    // approved collaterals
    CollateralLabel[] private collaterals;
    ReputationManager private reputationManager;

    /// SETUP

    constructor(
        address _vault,
        address _reputationManager,
        address _utilizer,
        address _rateCalculator,
        string memory _name,
        string memory _symbol,
        bytes memory _rateInitCallData,
        Config memory _config,
        CollateralLabel[] memory _labels
    )
        Instrument(_vault, _utilizer)
        ERC4626(Vault(_vault).asset(), _name, _symbol)
    {
        rateContract = IRateCalculator(_rateCalculator);
        rateInitCallData = _rateInitCallData;
        rateContract.requireValidInitData(_rateInitCallData);

        require(_config.maxBorrow > 0);
        require(_config.maxAmount > _config.maxBorrow);
        require(_config.step < 1e18);

        config = _config;

        reputationManager = ReputationManager(_reputationManager);

        borrowRateInfo.lastTimestamp = uint64(block.timestamp);

        for (uint256 i = 0; i < _labels.length; i++) {
            addAcceptedCollateral(
                _labels[i].tokenAddress,
                _labels[i].tokenId,
                _labels[i].isERC20
            );
        }
    }

    /// @notice adds accepted collateral to the CLP
    function addAcceptedCollateral(
        address collateral,
        uint256 tokenId,
        bool _isERC20
    ) public {
        bytes32 id = computeId(collateral, tokenId);
    
        require(msg.sender == vault.owner(), "only owner");
        require(!approvedCollateral[id], "already approved");

        if (_isERC20) {
            require(tokenId == 0, "tokenId must be 0 for ERC20");
        }

        collaterals.push(CollateralLabel(collateral, tokenId, _isERC20));
        isERC20[id] = _isERC20;
        approvedCollateral[id] = true;
    }

    /// MODIFIERS + HELPERS

    modifier onlyApprovedCollateral(address _collateral, uint256 _tokenId) {
        require(
            approvedCollateral[computeId(_collateral, _tokenId)],
            "!collateral_approved"
        );
        _;
    }

    /// @notice Checks if total amount of asset user borrowed is less than or equal to maxBorrowableAmount, i.e. maxAmount/maxBorrow =< userCollateralValue/userDebt.
    modifier isHealthy(address _borrower) {
        _;
        require(userMaxBorrowCapacity(_borrower) >= totalBorrow.toAmount(userBorrowShares[_borrower], true), "!healthy");
    }

    /// @notice checks if the user is not liquidatable after executing the contract code
    modifier isSolvent(address _borrower) {
        _;
        require(!isLiquidatable(_borrower), "!solvent");
    }

    /// @notice computes the id for a collateral
    function computeId(address _addr, uint256 _tokenId)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_addr, _tokenId));
    }

    function getAcceptedCollaterals()
        public
        view
        returns (CollateralLabel[] memory)
    {
        return collaterals;
    }

    // total amount of asset available in the pool
    function _totalAssetAvailable(
        VaultAccount memory _totalAsset,
        VaultAccount memory _totalBorrow
    ) internal pure returns (uint256) {
        return _totalAsset.amount - _totalBorrow.amount;
    }

    function getUserCollaterals(address borrower) public returns(CollateralLabel[] memory) {
        return userCollateral[borrower];
    }

    function getUserSnapshot(address _address)
        external
        view
        returns (
            uint256 _userAssetShares,
            uint256 _userAssetAmount,
            uint256 _userBorrowShares,
            uint256 _userBorrowAmount,
            int256 _userAccountLiquidity,
            CollateralLabel[] memory _userCollaterals
        )
    {
        _userAssetShares = balanceOf[_address];
        _userAssetAmount = totalAsset.toAmount(_userAssetShares, false);
        _userBorrowShares = userBorrowShares[_address];
        _userBorrowAmount = totalBorrow.toAmount(_userBorrowShares, false);
        (uint256 debt, uint256 maxDebt) = userAccountLiquidity(_address);
        _userAccountLiquidity = SafeCast.toInt256(maxDebt) - SafeCast.toInt256(debt);
        _userCollaterals = userCollateral[_address];
    }

    /// INTEREST RATE LOGIC

    event InterestAdded(
        uint256 indexed timestamp,
        uint256 interestEarned,
        uint256 feesAmount,
        uint256 feesShare,
        uint64 newRate
    );

    function addInterest()
        external
        nonReentrant
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        return _addInterest();
    }

    function _addInterest()
        internal
        returns (
            uint256 _interestEarned,
            uint256 _feesAmount,
            uint256 _feesShare,
            uint64 _newRate
        )
    {
        // Add interest only once per block
        CurrentRateInfo memory _currentRateInfo = currentRateInfo;
        if (_currentRateInfo.lastTimestamp == block.timestamp) {
            _newRate = _currentRateInfo.ratePerSec;
            return (_interestEarned, _feesAmount, _feesShare, _newRate);
        }

        // Pull some data from storage to save gas
        VaultAccount memory _totalAsset = totalAsset;
        VaultAccount memory _totalBorrow = totalBorrow;

        if (_totalBorrow.shares == 0) {
            _currentRateInfo.ratePerSec = DEFAULT_INT;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Effects: write to storage
            currentRateInfo = _currentRateInfo;
        } else {
            // We know totalBorrow.shares > 0
            uint256 _deltaTime = block.timestamp -
                _currentRateInfo.lastTimestamp;

            // NOTE: Violates Checks-Effects-Interactions pattern
            // Be sure to mark external version NONREENTRANT (even though rateContract is trusted)
            // Calc new rate
            uint256 _utilizationRate = (UTIL_PREC * _totalBorrow.amount) / _totalAsset.amount;
            // console.log("_utilizationRate: ", _utilizationRate);
            bytes memory _rateData = abi.encode(
                _currentRateInfo.ratePerSec,
                _deltaTime,
                _utilizationRate,
                block.number - _currentRateInfo.lastBlock
            );
            _newRate = IRateCalculator(rateContract).getNewRate(
                _rateData,
                rateInitCallData
            );

            // Effects: bookkeeping
            _currentRateInfo.ratePerSec = _newRate;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Calculate interest addd
            _interestEarned =(_deltaTime * _totalBorrow.amount * _currentRateInfo.ratePerSec) / 1e18;

            // Accumulate interest and fees, only if no overflow upon casting
            if (
                _interestEarned + _totalBorrow.amount <= type(uint128).max &&
                _interestEarned + _totalAsset.amount <= type(uint128).max
            ) {
                _totalBorrow.amount += uint128(_interestEarned);
                _totalAsset.amount += uint128(_interestEarned);
            }

            // Effects: write to storage
            totalAsset = _totalAsset;
            currentRateInfo = _currentRateInfo;
            totalBorrow = _totalBorrow;
        }
        emit InterestAdded(
            block.timestamp,
            _interestEarned,
            _feesAmount,
            _feesShare,
            _newRate
        );
    }

    /// DYNAMIC MAXBORROW && MAXAMOUNT

    /// @notice external implementation of _updateBorrowParameters
    function updateBorrowParameters() public returns (uint256 updatedMaxBorrow, uint256 updatedMaxAmount) {
        return _updateBorrowParameters();
    }

    /// @notice updates borrow parameters based on the current utilization rate of the pool
    function _updateBorrowParameters() internal returns (uint256 updatedMaxBorrow, uint256 updatedMaxAmount) {
        BorrowRateInfo memory _borrowRateInfo = borrowRateInfo;
        Config memory _config = config;

        // if (block.timestamp == _borrowRateInfo.lastTimestamp) {
        //     return (config.maxBorrow, config.maxAmount);
        // }

        uint256 currUtilizationRate = (UTIL_PREC * totalBorrow.amount) / totalAsset.amount; //uint256(totalBorrow.amount).mulDivDown(UTIL_PREC, uint256(totalAsset.amount));


        if (_borrowRateInfo.lastUtilizationRate > _config.upperUtil) {
            updatedMaxBorrow = (WAD - config.step).rpow(block.timestamp - _borrowRateInfo.lastTimestamp, WAD).mulWadDown(_config.maxBorrow);
            updatedMaxAmount = (WAD - config.step).rpow(block.timestamp - _borrowRateInfo.lastTimestamp, WAD).mulWadDown(_config.maxAmount);
        } else if (_borrowRateInfo.lastUtilizationRate < _config.lowerUtil) {
            updatedMaxBorrow = (WAD + config.step).rpow(block.timestamp - _borrowRateInfo.lastTimestamp, WAD).mulWadDown(_config.maxBorrow);
            updatedMaxAmount = (WAD + config.step).rpow(block.timestamp - _borrowRateInfo.lastTimestamp, WAD).mulWadDown(_config.maxAmount);
        } else {
            updatedMaxBorrow = _config.maxBorrow;
            updatedMaxAmount = _config.maxAmount;
        }

        // write to storage
        config.maxBorrow = updatedMaxBorrow;
        config.maxAmount = updatedMaxAmount;

        _borrowRateInfo.lastTimestamp = uint64(block.timestamp);
        _borrowRateInfo.lastBlock = uint64(block.number);
        _borrowRateInfo.lastUtilizationRate = uint256(currUtilizationRate);

        borrowRateInfo = _borrowRateInfo;
    
    }

    /// BORROW LOGIC

    event Borrow(address indexed _borrower, uint256 _amount, uint256 _shares);

    /// @notice retrieves the maximum asset borrowable by the user.
    function userMaxBorrowCapacity(address _user)
        public
        view
        returns (uint256 _capacity)
    {
        CollateralLabel[] memory userCollaterals = userCollateral[_user];
        uint256 maxBorrow = config.maxBorrow;

        for (uint256 i; i < userCollaterals.length; i++) {
            
            CollateralLabel memory _label = userCollaterals[i];
            bytes32 id = computeId(
                _label.tokenAddress,
                _label.tokenId
            );

            if (_label.isERC20) {
                uint256 d = ERC20(_label.tokenAddress).decimals();
                _capacity += (userCollateralBalances[_user][id]).mulDivDown(maxBorrow, 10**d);
            } else  {
                _capacity += (maxBorrow);
            }
        }
    }

    /// @param _borrowAmount amount of asset to borrow
    /// @param _collateralAmount amount of collateral to add
    /// @param _collateral address of collateral,
    /// @param _reciever address of reciever of asset
    function borrow(
        uint256 _borrowAmount,
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _reciever
    )
        external
        isHealthy(msg.sender)
        nonReentrant
        returns (uint256 _shares)
    {
        _addInterest();

        bytes32 id = computeId(_collateral, _tokenId);

        if (approvedCollateral[id] && (isERC20[id] && _collateralAmount > 0 || !isERC20[id])) {
            _addCollateral(
                msg.sender,
                _collateral,
                _collateralAmount,
                msg.sender,
                _tokenId
            );
        }

        // borrow asset.
        _shares = _borrow(SafeCast.toUint128(_borrowAmount), _reciever);

        _updateBorrowParameters();
    }

    function _borrow(uint128 _borrowAmount, address _receiver)
        internal
        returns (uint256 _shares)
    {
        VaultAccount memory _totalBorrow = totalBorrow;

        // Check available capital
        uint256 _assetsAvailable = _totalAssetAvailable(
            totalAsset,
            _totalBorrow
        );
        if (_assetsAvailable < _borrowAmount) {
            revert("!assetsAvailable");
        }

        // Effects: Bookkeeping to add shares & amounts to total Borrow accounting
        _shares = _totalBorrow.toShares(_borrowAmount, true);
        _totalBorrow.amount += _borrowAmount;
        _totalBorrow.shares += uint128(_shares);
        // NOTE: we can safely cast here because shares are always less than amount and _borrowAmount is uint128

        // Effects: write back to storage
        totalBorrow = _totalBorrow;
        userBorrowShares[msg.sender] += _shares;

        emit Borrow(msg.sender, _borrowAmount, _shares);

        // Interactions
        if (_receiver != address(this)) {
            asset.safeTransfer(_receiver, _borrowAmount);
        }
    }

    // REPAY LOGIC
    event Repay(address indexed borrower, uint256 amount, uint256 shares);

    function repay(uint256 _shares, address _borrower)
        external
        nonReentrant
        returns (uint256 _amountToRepay)
    {
        _addInterest();

        VaultAccount memory _totalBorrow = totalBorrow;
        _amountToRepay = _totalBorrow.toAmount(_shares, true);

        _repay(
            _totalBorrow,
            SafeCast.toUint128(_amountToRepay),
            SafeCast.toUint128(_shares),
            msg.sender,
            _borrower
        );

        _updateBorrowParameters();
    }

    function _repay(
        VaultAccount memory _totalBorrow,
        uint128 _amountToRepay,
        uint128 _shares,
        address _payer,
        address _borrower
    ) internal {
        // console.log("_shares: ", _shares);
        // console.log("_amountToRepay: ", _amountToRepay);
        // console.log(
        //     "userBorrowShares[_borrower]: ",
        //     userBorrowShares[_borrower]
        // );
        // console.log("totalBorrow.amount: ", totalBorrow.amount);
        // console.log("totalBorrow.shares: ", totalBorrow.shares);
        // Effects: Bookkeeping
        _totalBorrow.amount -= _amountToRepay;
        _totalBorrow.shares -= _shares;

        // Effects: write to state
        userBorrowShares[_borrower] -= _shares;
        totalBorrow = _totalBorrow;

        emit Repay(_borrower, _amountToRepay, _shares);

        // Interactions
        if (_payer != address(this)) {
            asset.safeTransferFrom(_payer, address(this), _amountToRepay);
        }
    }

    /// ADD/REMOVE COLLATERAL LOGIC

    event AddCollateral(
        address indexed borrower,
        address collateral,
        uint256 tokenId,
        uint256 amount
    );
    event RemoveCollateral(
        address indexed borrower,
        address collateral,
        uint256 tokenId,
        uint256 amount
    );


    /// @notice The ```addCollateral``` function allows the caller to add Collateral Token to a borrowers position
    /// @dev msg.sender must call ERC20.approve() on the Collateral Token contract prior to invocation, or ERC721.approve().
    /// @param _collateralAmount The amount of Collateral Token to be added to borrower's position
    /// @param _borrower The account to be credited
    function addCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _borrower
    ) external onlyApprovedCollateral(_collateral, _tokenId) nonReentrant {
        _addInterest();

        _addCollateral(
            msg.sender,
            _collateral,
            _collateralAmount,
            _borrower,
            _tokenId
        );
    }

    function _addCollateral(
        address _sender,
        address _collateral,
        uint256 _collateralAmount,
        address _borrower,
        uint256 _tokenId
    ) internal {
        // Interactions
        bytes32 id = computeId(_collateral, _tokenId);

        if (_sender != address(this)) {
            if (isERC20[id]) {
                userCollateralBalances[_borrower][id] += _collateralAmount;
                totalCollateral[id] += _collateralAmount;
                
                ERC20(_collateral).safeTransferFrom(
                    _sender,
                    address(this),
                    _collateralAmount
                );
            } else {
                userCollateralBalances[_borrower][id] = 1;
                totalCollateral[id] = 1;
                ERC721(_collateral).safeTransferFrom(
                    _sender,
                    address(this),
                    _tokenId
                );
            }
        }

        // user collateral accounting
        if (!userCollateralBool[_borrower][id]) {
            userCollateralBool[_borrower][id] = true;
            userCollateral[_borrower].push(CollateralLabel(_collateral, _tokenId, isERC20[id]));
        }

        emit AddCollateral(_borrower, _collateral, _tokenId, _collateralAmount);
    }

    function removeCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _receiver
    )
        external
        nonReentrant
        isSolvent(msg.sender)
        onlyApprovedCollateral(_collateral, _tokenId)
    {
        _addInterest();

        _removeCollateral(
            _collateral,
            _tokenId,
            _collateralAmount,
            msg.sender,
            _receiver
        );
    }

    function _removeCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _borrower,
        address _receiver
    ) internal {

        bytes32 id = computeId(_collateral, _tokenId);

        require(_collateralAmount <= userCollateralBalances[_borrower][id], "!balance");
        require(isERC20[id] && _collateralAmount > 0 || !isERC20[id], "!amount");

        if (_receiver != address(this)) {
            if (isERC20[id]) {
                // console.log("removing erc20 collateral");
                // console.log("userCollateralerc20: ", userERC20s[id][_borrower] );
                // console.log("collateralAmount: ", _collateralAmount);
                userCollateralBalances[_borrower][id] -= _collateralAmount;
                totalCollateral[id] -= _collateralAmount;
                ERC20(_collateral).safeTransfer(_receiver, _collateralAmount);
            } else {
                delete userCollateralBalances[_borrower][id];
                delete totalCollateral[id];
                ERC721(_collateral).safeTransferFrom(
                    address(this),
                    _receiver,
                    _tokenId
                );
            }
        }

        if (userCollateralBalances[_borrower][id] == 0) {
            CollateralLabel[] memory labels = userCollateral[_borrower];
            for (uint256 i; i < labels.length; i++) {
                if (computeId(labels[i].tokenAddress, labels[i].tokenId) == id) {
                    userCollateral[_borrower][i] = userCollateral[_borrower][labels.length - 1];
                }
            }
            userCollateral[_borrower].pop();
            delete userCollateralBool[_borrower][id];
        }

        emit RemoveCollateral(
            _borrower,
            _collateral,
            _tokenId,
            _collateralAmount
        );
    }

    /// LIQUIDATION LOGIC

    /// @notice returns true if the user is liquidatable
    /// underlying balance, collateral balance, what do we know about the user?
    /// if the user's borrow shares are equal to an amount of asset that is greater than the maximum amount they can borrow,
    function isLiquidatable(address _borrower)
        public
        view
        returns (bool)
    {

        if (userBorrowShares[_borrower] == 0) {
            return false;
        }

        (uint256 debt, uint256 maxDebt) = userAccountLiquidity(_borrower);
        return (debt >= maxDebt);
    }

    /// @notice debt, max allowable debt, all in vault underlying.
    function userAccountLiquidity(address user) public view returns (uint256 debt, uint256 maxDebt) {
        uint256 _maxAmount;

        CollateralLabel[] memory userCollaterals = userCollateral[user];

        for (uint256 i; i < userCollaterals.length; i++) {

            CollateralLabel memory _label = userCollaterals[i];
            bytes32 id = computeId(
                _label.tokenAddress,
                _label.tokenId
            );

            if (_label.isERC20) {
                uint256 d = ERC20(_label.tokenAddress).decimals();
                _maxAmount += userCollateralBalances[user][id].mulDivDown(config.maxAmount, 10**d);// (userCollateralBalances[user][id] * config.maxAmount) / (10**d);
                // console.log("maxAmount: ", userCollateralBalances[user][id].mulDivDown(config.maxAmount, 10**d));
                // console.log("another: ", (userCollateralBalances[user][id] * config.maxAmount) <= 10**d);
            } else  {
                _maxAmount += (config.maxAmount);
            }
        }

        return (totalBorrow.toAmount(userBorrowShares[user], true), _maxAmount);
    }

    struct LiquidationLocals {
        uint256 maxDiscount;
        uint256 healthScore;
        uint256 targetHealthScore;
        uint256 debt;
        uint256 maxDebt;
        
        uint256 repayLimit;
        uint256 discount;
        uint256 d;
        bytes32 id;
        uint256 badShares;
    }

    /// @notice liquidation mechanism, if not enough collateral to give for the repayAmount, then reverts?
    /// minYield parameter?
    /// @param _violator address of borrower with negative account liquidity
    /// @param _collateral address of collateral
    /// @param _repayAmount amount of asset to repay
    function liquidateERC20(
        address _violator,
        address _collateral,
        uint256 _repayAmount
    )   public
        onlyApprovedCollateral(_collateral, 0) // tokenId is 0 for ERC20
        returns (uint256 collateralToLiquidator)
    {
        _addInterest();
        _updateBorrowParameters();
    
        LiquidationLocals memory local;
        local.id = computeId(_collateral, 0);
        require(msg.sender != _violator, "self liquidation");
        require(isLiquidatable(_violator), "not liquidatable");
        require(isERC20[local.id], "not ERC20");

        (local.repayLimit, local.discount) = computeLiqOpp(_violator, _collateral, 0);

        // execute liquidation.
        require(_repayAmount <= local.repayLimit, "!repayLimit");

        console.log("repayAmount: ", _repayAmount);
        console.log("discount:", local.discount);

        local.d = ERC20(_collateral).decimals();
        collateralToLiquidator = _repayAmount == local.repayLimit ? 
        userCollateralBalances[_violator][local.id] 
        : _repayAmount.mulDivDown(10 ** (18 + local.d), config.maxAmount * (WAD - local.discount)).divWadDown(config.buf);
        console.log("collateralToLiquidator: ", collateralToLiquidator);
        // console.log("collateralBalanceBefore: ", userCollateralBalances[_violator][computeId(_collateral, 0)]);
        VaultAccount memory _totalBorrow = totalBorrow;

        (local.debt, local.maxDebt) = userAccountLiquidity(_violator);

        uint128 sharesToAdjust;
        uint128 amountToAdjust = uint128(local.debt - _repayAmount);

        // if no collateral left and there still exists debt, this is bad debt that needs to be deducted from the protocol asset balance.
        if (local.maxDebt == collateralToLiquidator.mulDivDown(config.maxAmount, 10**local.d) && amountToAdjust > 0) {
        
            sharesToAdjust = uint128(userBorrowShares[_violator] - _totalBorrow.toShares(_repayAmount, false));

            _totalBorrow.amount -= amountToAdjust;

            // write to asset state, loss for protocol
            totalAsset.amount -= amountToAdjust;
        }
        
        // repay borrowed amount, reverts if not enough asset.
        _repay(
            _totalBorrow,
            SafeCast.toUint128(_repayAmount),
            SafeCast.toUint128(totalBorrow.toShares(_repayAmount, false)) + sharesToAdjust,
            msg.sender,
            _violator
        );

        // transfer collateral to liquidator, reverts if not enough collateral
        _removeCollateral(
            _collateral,
            0, // tokenId => 0
            collateralToLiquidator,
            _violator,
            msg.sender
        );
    }

    /// @param _violator: address of borrower with negative account liquidity
    /// @param _collateral: address of collateral
    /// @param _tokenId: id of token
    function liquidateERC721(
        address _violator,
        address _collateral,
        uint256 _tokenId 
    )   public
        onlyApprovedCollateral(_collateral, _tokenId) 
        returns (uint256 repaidAmount)
    {
        _addInterest();
        _updateBorrowParameters();
    
        LiquidationLocals memory local;
        local.id = computeId(_collateral, 0);

        require(msg.sender != _violator, "self liquidation");
        require(isLiquidatable(_violator), "not liquidatable");
        require(!isERC20[local.id], "not ERC721");

        (, uint256 discount) = computeLiqOpp(_violator, _collateral, _tokenId);

        repaidAmount = config.maxAmount.mulWadDown(WAD - discount);
        
        VaultAccount memory _totalBorrow = totalBorrow;

        (local.debt, local.maxDebt) = userAccountLiquidity(_violator);
        // if no collateral left and there still exists debt, this is bad debt that needs to be deducted from the protocol asset balance.
        uint128 sharesToAdjust;
        uint128 amountToAdjust = uint128(local.debt - repaidAmount);
        if (local.maxDebt == config.maxAmount && amountToAdjust > 0) {
            
            sharesToAdjust = uint128(userBorrowShares[_violator] - _totalBorrow.toShares(repaidAmount, false));

            _totalBorrow.amount -= amountToAdjust;

            // write to asset state, loss to lenders
            totalAsset.amount -= amountToAdjust;
        }

        _repay(
            _totalBorrow,
            SafeCast.toUint128(repaidAmount),
            SafeCast.toUint128(totalBorrow.toShares(repaidAmount, false)) + sharesToAdjust,
            msg.sender,
            _violator
        );

        _removeCollateral(
            _collateral,
            _tokenId,
            0,
            _violator,
            msg.sender
        );
    }

    /// @notice computes the maximum amount of asset that can be repaid to liquidate a user and the discount bonus 
    /// maxRepay is used for ERC20 collateral only, in asset
    /// eq: maxAmount / maxBorrow = (userMaxAllowableDebt - maxRepay / (buf * (1 - discount))) / (currentDebt - maxRepay)
    function computeLiqOpp(address _violator, address _collateral, uint256 tokenId) public view returns (uint256 repayLimit, uint256 discount) {
        require(isLiquidatable(_violator), "not liquidatable");
        bytes32 id = computeId(_collateral, tokenId);
        LiquidationLocals memory local;
        (local.debt, local.maxDebt) = userAccountLiquidity(_violator);

        local.healthScore = local.maxDebt.divWadDown(local.debt);

        assert(local.healthScore <= WAD);

        // console.log("healthScore: ", healthScore);

        local.targetHealthScore = config.maxAmount.divWadDown(config.maxBorrow);
        local.maxDiscount = config.maxDiscount; // WAD - WAD.divWadDown(local.targetHealthScore) - 2e16;

        discount = WAD - local.healthScore < local.maxDiscount ? WAD - local.healthScore : local.maxDiscount; // max discount -> derived from the soft liquidation factor.

        // console.log("discount: ", discount);
        // console.log("T: ", targetHealthScore - WAD.divWadDown(WAD - discount));
        // console.log("H: ", targetHealthScore.mulWadDown(debt) - maxDebt);

        
        // soft liquidations won't make sense in virtually all scenarios tbh
        //repayLimit = (local.targetHealthScore.mulWadDown(local.debt) - local.maxDebt).divWadDown(local.targetHealthScore - WAD.divWadDown(config.buf.mulWadDown(WAD - discount))); // in description above.
        
        // if (repayLimit > local.debt) {
        //     repayLimit = local.debt;
        // }
        repayLimit = local.debt;

        // if collateral is ERC20, cap repayLimit at the value of the collateral
        if (isERC20[id]) {
            uint256 d = ERC20(_collateral).decimals();
            if (
                repayLimit
                >=
                userCollateralBalances[_violator][id].mulDivDown(config.maxAmount.mulWadDown(config.buf.mulWadDown(WAD - discount)), 10 ** d)
            ) {
                repayLimit = userCollateralBalances[_violator][id].mulDivDown(config.maxAmount.mulWadDown(config.buf.mulWadDown(WAD - discount)), (10 ** d));
            }
 
            // console.log("repayLimit collateral cap: ", repayLimit);
            // console.log("user collateral balance: ", userCollateralBalances[_violator][id]);
            // console.log("user collateral stuff: ", userCollateralBalances[_violator][id].mulDivDown(1e18, (10 ** d)));
            // console.log("user collateral stuff2: ", config.maxAmount.mulWadDown(WAD-discount));
        }
    }

    /// INSTRUMENT LOGIC

    /**
     @notice returns cost of purchasing _numTokens of collateral in pool underlying.
     */
    function approvalCondition()
        public
        view
        virtual
        override
        returns (bool)
    {
        return true;
    }

    function assetOracle(uint256 totalSupply)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // Default balance oracle
        // console.log('totalasset', uint256(totalAsset.amount), uint256(totalAsset.shares)); 
        // console.log('totalSupply', totalSupply, previewMint(1e18)); 
        return totalSupply.mulWadDown(previewMint(1e18));
        //TODO custom oracle
    }

    function balanceOfUnderlying(address user) public view override returns (uint256){
        if(user == address(this)) return   _totalAssetAvailable(totalAsset,totalBorrow);
        else return underlying.balanceOf(user); 
    }

    function resolveCondition() external view override returns (bool) {
        return true;
    }

    /// ERC4626 LOGIC

    function totalAssetAvailable() public view returns (uint256) {
        return _totalAssetAvailable(totalAsset, totalBorrow);
    }

    function beforeWithdraw(uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        // require(msg.sender == address(vault) || msg.sender == controller, "!Vault/Controller"); // only the vault can withdraw
        // check if there is enough asset to cover the withdraw.
        uint256 totalAvailableAsset = _totalAssetAvailable(
            totalAsset,
            totalBorrow
        );
        require(totalAvailableAsset >= assets, "not enough asset");

        VaultAccount memory _totalAsset = totalAsset;

        _totalAsset.amount -= SafeCast.toUint128(assets);
        _totalAsset.shares -= SafeCast.toUint128(shares);

        totalAsset = _totalAsset;

        _updateBorrowParameters();
    }

    function afterDeposit(uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        // require(msg.sender == address(vault) || msg.sender == controller, "!Vault/Controller"); // only the vault can deposit
        VaultAccount memory _totalAsset = totalAsset;

        _totalAsset.amount += SafeCast.toUint128(assets);
        _totalAsset.shares += SafeCast.toUint128(shares);

        totalAsset = _totalAsset;

        _updateBorrowParameters();
    }

    function isWithdrawable(address holder, uint256 amount)
        external
        view
        returns (bool)
    {
        return (previewRedeem(balanceOf[holder]) >= amount &&
            totalAssetAvailable() >= amount);
    }

    function toBorrowShares(uint256 _amount, bool _roundUp)
        external
        view
        returns (uint256)
    {
        return totalBorrow.toShares(_amount, _roundUp);
    }

    function toBorrowAmount(uint256 _shares, bool _roundUp)
        external
        view
        returns (uint256)
    {
        return totalBorrow.toAmount(_shares, _roundUp);
    }

    function toAssetAmount(uint256 _shares, bool _roundUp)
        external
        view
        returns (uint256)
    {
        return totalAsset.toAmount(_shares, _roundUp);
    }

    function toAssetShares(uint256 _amount, bool _roundUp)
        external
        view
        returns (uint256)
    {
        return totalAsset.toShares(_amount, _roundUp);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return uint256(totalAsset.amount);
    }

    function convertToShares(uint256 assets)
        public
        view
        virtual
        override
        returns (uint256)
    {   
        return totalAsset.toShares(assets, false);
    }

    function convertToAssets(uint256 shares)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return totalAsset.toAmount(shares, false);
    }

    function previewMint(uint256 shares)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return convertToAssets(shares);
    }

    // TODO doesn't use the UTIL_PREC, just defaults to 1e18
    function getUtilizationRate() public view returns(uint256){
        return (uint256(totalBorrow.amount) * 1e18) / uint256(totalAsset.amount); 
    }

    function totalBorrowAmount() public view returns(uint256){
        return totalBorrow.amount; 
    }

    /// @notice to modify totalassets very privileged function 
    function modifyTotalAsset(bool add, uint256 amount) external 
    //onlyManager
    {
        if(add) totalAsset.amount += uint128(amount); 
        else totalAsset.amount -= uint128(amount); 
    }
}