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
// import "@prb/math/SD59x18.sol";

// https://github.com/FraxFinance/fraxlend
/// ****THIS IS A PROOF OF CONCEPT INSTRUMENT.
contract PoolInstrument is ERC4626, Instrument, PoolConstants, ReentrancyGuard, Pausable, ERC721TokenReceiver {
    using SafeTransferLib for ERC20;
    using VaultAccountingLibrary for VaultAccount;
    using SafeCastLib for uint256;
    using FixedPointMathLib for uint256;


    /// @param lastBlock last block number
    /// @param lastTimestamp last block.timestamp
    /// @param ratePerSec rate per second of interest accrual
    struct CurrentRateInfo {
        uint64 lastBlock;
        uint64 lastTimestamp;
        uint64 ratePerSec;
    }

    /// @param tokenAddress collateral token address
    /// @param tokenId collateral tokenId, 0 for ERC20.
    struct CollateralLabel {
        address tokenAddress;
        uint256 tokenId;
    }

    /// @param totalCollateral total amount of collateral for a given ERC20 asset, will be zero for NFTs
    /// @param maxAmount max amount in underlying that a user can "owe" per base unit of collateral (unit = 1 for NFTs, 1e18 for ERC20s)
    /// should always be more than the maxBorrowAmount, acts as buffer for protocol and borrower. this is the value to determine whether
    /// a borrower is liquidatable
    /// @param maxBorrowAmount max amount in underlying that a user can borrow per base unit of collateral (unit = 1 for NFTs, 1e18 for ERC20s)
    struct Collateral {
        uint256 totalCollateral; 
        uint256 maxAmount;
        uint256 maxBorrowAmount;
        bool isERC20;
    }

    /// @notice dutch auctions for NFTs, GDA for illiquid ERC20s.
    /// @param borrower address of borrower
    /// @param collateral address of collateral
    /// @param tokenId tokenId of collateral, 0 for ERC20
    /// @param initialPrice initial price of collateral currently is (account liquidity / collateral amount) + maxAmount.
    /// @param decayConstant parameter that controls price decay, stored as a 59x18 fixed precision number
    /// @param startTime for dutch auction: start time of auction, for GDA: time of last auction.
    /// @param emissionRate for dutch auction: 0, for GDA: amount of collateral to be auctioned off per second.
    // struct Auction {
    //     address borrower;
    //     address collateral;
    //     uint256 tokenId;
    //     SD59x18 initialPrice;
    //     SD59x18 minimumPrice;
    //     SD59x18 decayConstant;
    //     SD59x18 startTime;
    //     // SD59x18 emissionRate;
    //     bool alive;
    // }

    /// @notice amount: asset token borrowed, shares = total shares outstanding
    VaultAccount public totalBorrow;
    /// @notice amount: total asset supplied + interest earned, shares = total shares outstanding
    VaultAccount public totalAsset;

    mapping(address=>mapping(uint256 => Collateral)) public collateralData; // collateral address => tokenId (0 for erc20) => collateral data.
    mapping(address=>mapping(uint256=>bool)) public approvedCollateral;
    mapping(address=>mapping(address=>uint256)) public userCollateralERC20; // per collateral, user balance of collateral.
    mapping(address=>mapping(uint256 => address)) public userCollateralNFTs; // nft addr => tokenId => owner.
    mapping(address=>uint256) public userBorrowShares;
    mapping(address=>uint256) public userAuctionId; // user => current auction id, if 0 then no auction.
    
    /// @dev auction id => order of creation.
    // mapping(uint256=>Auction) public auctions; // auction id => auction data, auction id is in order of creation.

    uint256 public numAuctions; // number of auction ids.

    IRateCalculator public rateContract;

    /// @dev depends on rateCalculator used
    bytes public rateInitCallData;
    
    CurrentRateInfo public currentRateInfo;
    CollateralLabel[] collaterals; //approved collaterals.
    address controller;
    
    constructor (
        address _vault,
        address _controller,
        address _utilizer,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _rateCalculator,
        bytes memory _rateInitCallData,
        CollateralLabel[] memory _collaterals,
        Collateral[] memory _collateralDatas
    ) Instrument(_vault, _utilizer) ERC4626(ERC20(_asset), _name, _symbol) {
        controller = _controller;
        rateContract = IRateCalculator(_rateCalculator);
        rateInitCallData = _rateInitCallData;
        rateContract.requireValidInitData(_rateInitCallData);

        for (uint i = 0; i < _collaterals.length; i ++) {
            collaterals.push(_collaterals[i]);
            Collateral memory _collateral = _collateralDatas[i];
            _collateral.totalCollateral = 0;
            collateralData[_collaterals[i].tokenAddress][_collaterals[i].tokenId] = _collateral;
        }
    }

    // should be gated function
    /// tokenId 0 for ERC20.
    // function initialize(
    // ) external {

    // }

    function getAcceptedCollaterals() view public returns (CollateralLabel[] memory) {
        return collaterals;
    }

    event NewCollateralAdded(address collateral, uint256 tokenId, uint256 maxAmount, uint256 maxBorrowAmount, bool isERC20);
    // legacy for tests, remove later.
    function addAcceptedCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _maxAmount,
        uint256 _maxBorrowAmount,
        bool _isERC20
    ) external  {
        require(msg.sender == controller || msg.sender == address(vault), "!authorized");
        if (approvedCollateral[_collateral][_tokenId]) return; 
        require(_maxAmount > _maxBorrowAmount, "maxAmount must be greater than maxBorrowAmount");
        approvedCollateral[_collateral][_tokenId] = true;
        collaterals.push(CollateralLabel(_collateral, _tokenId));
        collateralData[_collateral][_tokenId] = Collateral(0,_maxAmount, _maxBorrowAmount, _isERC20);
        emit NewCollateralAdded(_collateral, _tokenId, _maxAmount, _maxBorrowAmount, _isERC20);
    }

    // INTERNAL HELPERS

    modifier onlyApprovedCollateral(address _collateral, uint256 _tokenId) {
        require(approvedCollateral[_collateral][_tokenId], "collateral not approved");
        _;
    }

    function _totalAssetAvailable(VaultAccount memory _totalAsset, VaultAccount memory _totalBorrow)
        internal
        pure
        returns (uint256)
    {
        return _totalAsset.amount - _totalBorrow.amount;
    }

    // INTEREST RATE LOGIC
    event InterestAdded(uint256 indexed timestamp, uint256 interestEarned, uint256 feesAmount, uint256 feesShare, uint64 newRate);

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

    function _addInterest() internal
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
        console.log("total borrower shares: ", totalBorrow.shares);

        // If there are no borrows or contract is paused, no interest adds and we reset interest rate
        if (_totalBorrow.shares == 0 || paused()) {
            if (!paused()) {
                _currentRateInfo.ratePerSec = DEFAULT_INT;
            }
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Effects: write to storage
            currentRateInfo = _currentRateInfo;
        } else {
            // We know totalBorrow.shares > 0
            uint256 _deltaTime = block.timestamp - _currentRateInfo.lastTimestamp;

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
                _newRate = IRateCalculator(rateContract).getNewRate(_rateData, rateInitCallData);

            // Effects: bookkeeping
            _currentRateInfo.ratePerSec = _newRate;
            _currentRateInfo.lastTimestamp = uint64(block.timestamp);
            _currentRateInfo.lastBlock = uint64(block.number);

            // Calculate interest addd
            _interestEarned = (_deltaTime * _totalBorrow.amount * _currentRateInfo.ratePerSec) / 1e18;

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
        console.log("_interestEarned: ", _interestEarned);
        emit InterestAdded(block.timestamp, _interestEarned, _feesAmount, _feesShare, _newRate);
        // console.log("ratePerSec: ", _currentRateInfo.ratePerSec);
    }

    // SOLVENCY* LOGIC

    /// @notice Checks if total amount of asset user borrowed is less than max borrow threshold AFTER executing contract code
    modifier canBorrow(address _borrower) {
        _;
        require(_canBorrow(_borrower), "borrower is insolvent");
    }


    /// @notice checks if the borrower is can borrow
    /// @dev collateral value is in asset, summed across all approved collaterals.
    /// @dev will return true if the borrower has no collateral and also has no borrower shares.
    /// @dev 0 addr cannot borrow.
    function _canBorrow(address _borrower) public view returns (bool) {
        uint256 _maxBorrowableAmount = getMaxBorrow(_borrower);

        if (userBorrowShares[_borrower] == 0) {
            return true;
        }
        if (_maxBorrowableAmount == 0) {
            return false;
        }
        return _maxBorrowableAmount >= totalBorrow.toAmount(userBorrowShares[_borrower], false);
    }

    function getMaxBorrow(address _borrower) public view returns(uint256 _maxBorrowableAmount){

        for (uint256 i; i < collaterals.length; i++) {
            CollateralLabel memory _collateral = collaterals[i];
            Collateral memory _collateralData = collateralData[_collateral.tokenAddress][_collateral.tokenId];
            if (_collateralData.isERC20 && userCollateralERC20[_collateral.tokenAddress][_borrower] > 0) {
                uint256 _d = ERC20(_collateral.tokenAddress).decimals();
                _maxBorrowableAmount += userCollateralERC20[_collateral.tokenAddress][_borrower] * _collateralData.maxBorrowAmount / (10**_d); // <= precision of collateral.
            } else {
                if (userCollateralNFTs[_collateral.tokenAddress][_collateral.tokenId] == _borrower) {
                    _maxBorrowableAmount += _collateralData.maxBorrowAmount;
                }
            }
        }
    }

    /// @notice returns how much collateral can be removed, given the borrower's current debt condition
    function removeableCollateral(address _borrower, uint256 tokenId, address collateral) public view returns(uint256){
        //800 borrowable = 800 * 1, 600borrowed (800-x)*1 - 600 = 0 x=? 
        //800*1-x*1-600 , x = (800*1 - 600)/1
        uint256 _maxBorrowableAmount = getMaxBorrow(_borrower); 
        uint256 perUnitMaxBorrowAmount = collateralData[collateral][tokenId].maxBorrowAmount; 
        //check solvency
        return (_maxBorrowableAmount - totalBorrow.toAmount(userBorrowShares[_borrower], true)) 
            * 1e18/ perUnitMaxBorrowAmount; 
    }  

    // BORROW LOGIC
    event Borrow(address indexed _borrower, uint256 _amount, uint256 _shares);

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
    ) canBorrow(msg.sender) nonReentrant whenNotPaused external returns (uint256 _shares) {
        _addInterest();

        if (_collateral != address(0) && (_collateralAmount > 0 || _tokenId > 0)) {
            require(approvedCollateral[_collateral][_tokenId], "unapproved collateral");
            _addCollateral(msg.sender, _collateral, _collateralAmount, msg.sender, _tokenId);
        }
        // borrow asset.
        _shares = _borrow(_borrowAmount.safeCastTo128(), _reciever);
    }

    function _borrow(
        uint128 _borrowAmount,
        address _receiver
    ) internal returns (uint256 _shares) {
        VaultAccount memory _totalBorrow = totalBorrow;

        // Check available capital
        uint256 _assetsAvailable = _totalAssetAvailable(totalAsset, _totalBorrow);
        if (_assetsAvailable < _borrowAmount) {
            revert("insufficient contract asset balance");
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

    function repayWithAmount(
        uint256 _amount, 
        address _borrower
        )   external nonReentrant returns (uint256 _sharesToRepay){
        VaultAccount memory _totalBorrow = totalBorrow;
        _sharesToRepay = _totalBorrow.toShares(_amount, true); 
        _repay(_totalBorrow, _amount.safeCastTo128(), _sharesToRepay.safeCastTo128(), msg.sender, _borrower);
    }

    function repay(
        uint256 _shares,
        address _borrower
    ) external nonReentrant returns (uint256 _amountToRepay) {
        VaultAccount memory _totalBorrow = totalBorrow;
        _amountToRepay = _totalBorrow.toAmount(_shares, true);
        console.log("amount to repay: ", _amountToRepay);
        _repay(_totalBorrow, _amountToRepay.safeCastTo128(), _shares.safeCastTo128(), msg.sender, _borrower);
    }

    function _repay(
        VaultAccount memory _totalBorrow,
        uint128 _amountToRepay,
        uint128 _shares,
        address _payer,
        address _borrower
    ) internal {
        console.log("_shares: ", _shares);
        console.log("_amountToRepay: ", _amountToRepay);
        console.log("userBorrowShares[_borrower]: ", userBorrowShares[_borrower]);
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


    // ADD/REMOVE COLLATERAL LOGIC
    event AddCollateral(address indexed borrower, address collateral, uint256 tokenId, uint256 amount);
    event RemoveCollateral(address indexed borrower, address collateral, uint256 tokenId, uint256 amount);

    
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
        _addCollateral(msg.sender, _collateral, _collateralAmount, _borrower, _tokenId);
    }

    function _addCollateral(
        address _sender,
        address _collateral,
        uint256 _collateralAmount,
        address _borrower,
        uint256 _tokenId
    ) internal {

        // Interactions
        bool _isERC20 = collateralData[_collateral][_tokenId].isERC20;
    
        if (_sender != address(this)) {
            if (_isERC20)  {
                userCollateralERC20[_collateral][_borrower] += _collateralAmount;
                collateralData[_collateral][0].totalCollateral += _collateralAmount;
                ERC20(_collateral).safeTransferFrom(_sender, address(this), _collateralAmount);
            } else {
                userCollateralNFTs[_collateral][_tokenId] = _borrower;
                ERC721(_collateral).safeTransferFrom(_sender, address(this), _tokenId);
            }
        }
        emit AddCollateral(_borrower, _collateral, _tokenId, _collateralAmount);
    }

    function removeAvailableCollateral(
        address _collateral, 
        uint256 _tokenId,
        address _receiver
    ) external nonReentrant canBorrow(msg.sender) onlyApprovedCollateral(_collateral, _tokenId) returns(uint256 removeable){
        _addInterest();

        removeable = removeableCollateral(msg.sender,  _tokenId,  _collateral); 

        _removeCollateral(_collateral, 
            removeable,
            _tokenId, msg.sender, _receiver);
    }

    function removeCollateral(
        address _collateral, 
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _receiver
    ) external nonReentrant canBorrow(msg.sender) onlyApprovedCollateral(_collateral, _tokenId) {
        _addInterest();

        // Note: exchange rate is irrelevant when borrower has no debt shares
        _removeCollateral(_collateral, _collateralAmount, _tokenId, msg.sender, _receiver);
    }

    function _removeCollateral(
        address _collateral,
        uint256 _collateralAmount,
        uint256 _tokenId,
        address _borrower,
        address _receiver
    ) internal {

        // Interactions
        bool _isERC20 = collateralData[_collateral][_tokenId].isERC20;
        if (_receiver != address(this)) {
            if (_isERC20) {
                console.log("removing erc20 collateral");
                console.log("userCollateralerc20: ", userCollateralERC20[_collateral][_borrower] );
                console.log("collateralAmount: ", _collateralAmount);
                console.log("total: ", collateralData[_collateral][0].totalCollateral);
                userCollateralERC20[_collateral][_borrower] -= _collateralAmount;
                collateralData[_collateral][0].totalCollateral -= _collateralAmount;
                ERC20(_collateral).safeTransfer(_receiver, _collateralAmount);
            } else {
                require(userCollateralNFTs[_collateral][_tokenId] == _borrower, "not owner of nft");
                delete userCollateralNFTs[_collateral][_tokenId];
                ERC721(_collateral).safeTransferFrom(address(this), _receiver, _tokenId);
            }
        }
        emit RemoveCollateral(_borrower, _collateral, _tokenId, _collateralAmount);
    }

    // liquidation logic

    /// @notice collateral should be auctioned off at a minimum price chosen by the managers
    /// underlying balance, collateral balance, what do we know about the user?
    /// if the user's borrow shares are equal to an amount of asset that is greater than the maximum amount they can borrow, 
    /// they are suceptible to liquidation
    /// how to determine what collateral should be auctioned off?
    /// maxBorrowAmount
    function _isLiquidatable(address _borrower) public view returns (bool, int256 accountLiq) {
        uint256 _maxBorrowableAmount;

        for (uint256 i; i < collaterals.length; i++) {
            CollateralLabel memory _collateral = collaterals[i];
            Collateral memory _collateralData = collateralData[_collateral.tokenAddress][_collateral.tokenId];
            if (_collateralData.isERC20 && userCollateralERC20[_collateral.tokenAddress][_borrower] > 0) {
                uint256 _d = ERC20(_collateral.tokenAddress).decimals();
                _maxBorrowableAmount += userCollateralERC20[_collateral.tokenAddress][_borrower] * _collateralData.maxAmount / (10**_d); // <= precision of collateral.
            } else {
                if (userCollateralNFTs[_collateral.tokenAddress][_collateral.tokenId] == _borrower) {
                    _maxBorrowableAmount += _collateralData.maxAmount;
                }
            }
        }


        return (_maxBorrowableAmount < totalBorrow.toAmount(userBorrowShares[_borrower], false), 
            int256(_maxBorrowableAmount) - int256(totalBorrow.toAmount(userBorrowShares[_borrower], false))
        );
    }

    /// AUCTION LOGIC

    event AuctionCreated(uint256 indexed id, address indexed borrower, address indexed collateral, uint256 tokenId);
    event AuctionClosed(uint256 indexed id, address indexed borrower, address indexed collateral, uint256 tokenId);
    event CollateralPurchased(uint256 indexed id, address indexed buyer, address indexed collateral, uint256 tokenId, uint256 amount);

    function liquidate(
        address _borrower
    ) external nonReentrant returns (CollateralLabel memory _collateral, uint256 _auctionId){
        _addInterest();
        
        (bool _liquidatable, int256 _accountLiq) = _isLiquidatable(_borrower);
        require(_liquidatable, "borrower is not liquidatable");
        require(userAuctionId[_borrower] == 0, "auction already exists");
        // _accountLiq < 0 if _liquidatable.
        //(_collateral, _auctionId) = _createAuction(_borrower, uint256(-_accountLiq));
    }

    // since we don't know the price of the collateral, will just use largest maxAmount collateral, presumably the most "liquid"
    /// @dev _accountLiq in wad.
    // function _createAuction(address _borrower, uint256 _accountLiq) internal returns (CollateralLabel memory _collateral, uint256 _auctionId) {
    //     CollateralLabel[] memory _collaterals = collaterals;

    //     uint256 maxBorrowableAmount;
    //     for (uint256 i; i<_collaterals.length; i++) {
    //         CollateralLabel memory _collateralLabel = _collaterals[i];
    //         Collateral memory _collateralData = collateralData[_collateralLabel.tokenAddress][_collateralLabel.tokenId];
    //         if (_collateralData.isERC20) {
    //             uint256 _amount = userCollateralERC20[_collateralLabel.tokenAddress][_borrower] * _collateralData.maxAmount / 1e18; // <= precision of collateral.
    //             if (_amount > maxBorrowableAmount) {
    //                 maxBorrowableAmount = _amount;
    //                 _collateral = _collateralLabel;
    //             }
    //         } else {
    //             if (userCollateralNFTs[_collateralLabel.tokenAddress][_collateralLabel.tokenId] == _borrower) {
    //                 if (_collateralData.maxAmount > maxBorrowableAmount) {
    //                     maxBorrowableAmount = _collateralData.maxAmount;
    //                     _collateral = _collateralLabel;
    //                 }
    //             }
    //         }
    //     }

    //     // creates auction for collateral user collateral.
    //     Collateral memory _data = collateralData[_collateral.tokenAddress][_collateral.tokenId];

    //     uint256 _id = numAuctions + 1;

    //     SD59x18 _balance;
    //     if (_data.isERC20) {
    //         uint256 _d = ERC20(_collateral.tokenAddress).decimals();
    //         _balance = sd(int256(userCollateralERC20[_collateral.tokenAddress][_borrower] * 10**(18-_d)));
    //     } else {
    //         _balance = toSD59x18(1);
    //     }
    //     console.log("accountLiq: ", _accountLiq);
    //     console.logInt(SD59x18.unwrap(_balance));
    //     console.log("maxAmount: ", _data.maxAmount);
    //     console.logInt(int256(_data.maxAmount));

    //     SD59x18 _initialPrice = sd(int256(_accountLiq)).div(_balance).add(sd(int256(_data.maxAmount))); // per collateral token.
    //     // console.logInt(SD59x18.unwrap(_initialPrice));

    //     console.log("shares: ", totalBorrow.toShares(uint256(SD59x18.unwrap(_initialPrice)), true));
    //     console.log("total.shares: ", totalBorrow.shares);
    //     console.log("total.amount: ", totalBorrow.amount);

    //     SD59x18 _decayConstant = sd(1e17).div(toSD59x18(86400));// decayConstant * deltaTime * initial price = discount.
    //     SD59x18 _minimumPrice = _initialPrice.div(toSD59x18(4)); // minimum price is 1/4 of initial price.
        
    //     // sd(1219450412706); // 10% a day. 1.219450412706322930873853944899453684098615428047153617638... × 10^-6
    //     // SD59x18 _emissionRate = _balance.div(toSD59x18(86400).div(toSD59x18(2))); // 1/2 balance in a day, tokens per second.
    //     auctions[_id] = Auction({
    //         collateral: _collateral.tokenAddress,
    //         tokenId: _collateral.tokenId,
    //         borrower: _borrower,
    //         initialPrice: _initialPrice,
    //         minimumPrice: _minimumPrice,
    //         decayConstant: _decayConstant,
    //         startTime: toSD59x18(int256(block.timestamp)),
    //         //emissionRate: _emissionRate,
    //         alive: true
    //     });
    
    //     numAuctions = numAuctions + 1;
    //     _auctionId = _id;
    //     userAuctionId[_borrower] = _auctionId;

    //     emit AuctionCreated(_id, _borrower, _collateral.tokenAddress, _collateral.tokenId);
    // }

    
    // function closeAuction(address _borrower) public {
    //     uint256 _id = userAuctionId[_borrower];
    //     (bool _liquidatable, ) = _isLiquidatable(auctions[_id].borrower);
    //     require(_id != 0, "no auction exists");

    //     if (!_liquidatable) {
    //         _closeAuction(_id);
    //     }
    // }

    // function _closeAuction(uint256 _id) internal {
    //     address _borrower = auctions[_id].borrower;
    //     emit AuctionClosed(_id, _borrower, auctions[_id].collateral, auctions[_id].tokenId);
    //     delete userAuctionId[_borrower];
    //     delete auctions[_id];
    // }

    // function purchaseERC20Collateral(uint256 _id, uint256 _amount) external returns (uint256 _totalCost) {
    //     Auction memory _auction = auctions[_id];

    //     (bool _liquidatable, ) = _isLiquidatable(_auction.borrower);
    //     if (!_liquidatable) {
    //         _closeAuction(_id);
    //         revert("auction closed");
    //     }
        
    //     _totalCost = purchasePriceERC20(_id, _amount);
    //     console.log("totalCost: ", _totalCost);

    //     VaultAccount memory _totalBorrow = totalBorrow;
    //     _repay(_totalBorrow, _totalCost.safeCastTo128(), _totalBorrow.toShares(_totalCost, false).safeCastTo128(), msg.sender, _auction.borrower);
       
    //    // will revert if not enough collateral in user collateral balance.
    //    _removeCollateral(_auction.collateral, _amount, _auction.tokenId, _auction.borrower, msg.sender);

    //     (_liquidatable, ) = _isLiquidatable(_auction.borrower);
    //     if (!_liquidatable) {
    //         _closeAuction(_id);
    //     }
    //     if (userCollateralERC20[_auction.collateral][_auction.borrower] == 0) {
    //         delete userAuctionId[_auction.borrower];
    //         delete auctions[_id];
    //     }
        
    // }

    // function purchasePriceERC20(uint256 _id, uint256 _numTokens) public view returns (uint256 totalCost) {
    //     Auction memory _auction = auctions[_id];
    //     require(_auction.alive, "auction is not alive");

    //     uint256 _d = ERC20(_auction.collateral).decimals();
        
    //     SD59x18 _quantity = sd(int256(_numTokens * (10 ** (18 - _d))));
    //     SD59x18 _discount = _auction.decayConstant.mul(toSD59x18(int256(block.timestamp)).sub(_auction.startTime)).mul(_auction.initialPrice);
    //     SD59x18 _price = SD59x18.unwrap(_auction.initialPrice) > SD59x18.unwrap(_auction.minimumPrice.add(_discount)) // is initial price > minimum price + discount => initial price - discount > minimum price
    //         ? _auction.initialPrice.sub(_discount) : _auction.minimumPrice;
    //     totalCost = uint256(SD59x18.unwrap(_price.mul(_quantity)));
    // }

    // /// @param _id is the auction id to purchase the collateral from
    // function purchaseERC721Collateral(uint256 _id) external returns (uint256 _totalCost) {
    //     Auction memory _auction = auctions[_id];

    //     (bool _liquidatable, ) = _isLiquidatable(_auction.borrower);
    //     if (!_liquidatable) {
    //         _auction.alive = false;
    //         auctions[_id] = _auction;
    //         delete userAuctionId[_auction.borrower];
    //         revert("auction closed");
    //     }
        
    //     _totalCost = purchasePriceERC721(_id);

    //     VaultAccount memory _totalBorrow = totalBorrow;
    //     _repay(_totalBorrow, _totalCost.safeCastTo128(), _totalBorrow.toShares(_totalCost, false).safeCastTo128(), msg.sender, _auction.borrower);
       
    //    // will revert if not enough collateral in user collateral balance.
    //    _removeCollateral(_auction.collateral, 0, _auction.tokenId, _auction.borrower, msg.sender);

    //     (_liquidatable, ) = _isLiquidatable(_auction.borrower);
    //     if (!_liquidatable) {
    //         _closeAuction(_id);
    //     }
    //     if (userCollateralNFTs[_auction.collateral][_auction.tokenId] == address(0)) {
    //         delete userAuctionId[_auction.borrower];
    //         delete auctions[_id];
    //     }
    // }

    // function purchasePriceERC721(uint256 _id) public view returns (uint256 totalCost) {
    //     Auction memory _auction = auctions[_id];
    //     require(_auction.alive, "auction is not alive");

    //     SD59x18 _discount = _auction.decayConstant.mul(toSD59x18(int256(block.timestamp)).sub(_auction.startTime));

    //     totalCost = SD59x18.unwrap(_auction.initialPrice) > SD59x18.unwrap(_auction.minimumPrice.add(_discount)) ? 
    //     uint256(SD59x18.unwrap(_auction.initialPrice.sub(_discount))) : uint256(SD59x18.unwrap(_auction.minimumPrice));
        
    // }

    // instrument functions
    function instrumentApprovalCondition() public override virtual view returns (bool) {
        return true;
    }

    function borrowLiquidityAvailable(uint256 _borrowAmount) public view returns (bool){
        VaultAccount memory _totalBorrow = totalBorrow;

        uint256 _assetsAvailable = _totalAssetAvailable(totalAsset, _totalBorrow);
        if (_assetsAvailable < _borrowAmount) {
            return false;
        }
        return true; 
    }

    function totalAssetAvailable() public view returns(uint256){
        return _totalAssetAvailable(totalAsset, totalBorrow); 
    }


    // ERC4626 functions.

    function beforeWithdraw(uint256 assets, uint256 shares) internal override virtual {
        // require(msg.sender == address(vault) || msg.sender == controller, "!Vault/Controller"); // only the vault can withdraw
        // check if there is enough asset to cover the withdraw.
        uint256 totalAvailableAsset = _totalAssetAvailable(totalAsset, totalBorrow);
        require(totalAvailableAsset >= assets, "not enough asset");

        VaultAccount memory _totalAsset = totalAsset;

        _totalAsset.amount -= assets.safeCastTo128();
        _totalAsset.shares -= shares.safeCastTo128();

        totalAsset = _totalAsset;

    }

    function afterDeposit(uint256 assets, uint256 shares) internal override virtual {
        // require(msg.sender == address(vault) || msg.sender == controller, "!Vault/Controller"); // only the vault can deposit
        VaultAccount memory _totalAsset = totalAsset;

        _totalAsset.amount += assets.safeCastTo128();
        _totalAsset.shares += shares.safeCastTo128();

        totalAsset = _totalAsset;
    }

    function getUserSnapshot(address _address)
        external
        view
        returns (
            uint256 _userAssetShares,
            uint256 _userAssetAmount,
            uint256 _userBorrowShares,
            uint256 _userBorrowAmount,
            int256 _userAccountLiquidity
        )
    {
        _userAssetShares = balanceOf[_address];
        _userAssetAmount = totalAsset.toAmount(_userAssetShares, false);
        _userBorrowShares = userBorrowShares[_address];
        _userBorrowAmount = totalBorrow.toAmount(_userBorrowShares, false);
        (, _userAccountLiquidity) = _isLiquidatable(_address);
    }
    function isWithdrawAble(address holder, uint256 amount) external view returns(bool){
        return (previewRedeem(balanceOf[holder])>= amount && totalAssetAvailable() >= amount); 
    }

    function toBorrowShares(uint256 _amount, bool _roundUp) external view returns (uint256) {
        return totalBorrow.toShares(_amount, _roundUp);
    }

    function toBorrowAmount(uint256 _shares, bool _roundUp) external view returns (uint256) {
        return totalBorrow.toAmount(_shares, _roundUp);
    }

    function toAssetAmount(uint256 _shares, bool _roundUp) external view returns (uint256) {
        return totalAsset.toAmount(_shares, _roundUp);
    }

    function toAssetShares(uint256 _amount, bool _roundUp) external view returns (uint256) {
        return totalAsset.toShares(_amount, _roundUp);
    }

    function totalAssets() public view override virtual returns (uint256) {
        return totalAsset.amount;
    }

    function convertToShares(uint256 assets) public view override virtual returns (uint256) {
        return totalAsset.toShares(assets, false);
    }

    function convertToAssets(uint256 shares) public view override virtual returns (uint256) {
        return totalAsset.toAmount(shares, false);
    }


    function previewMint(uint256 shares) public view override virtual returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view override virtual returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view override virtual returns (uint256) {
        return convertToAssets(shares);
    }
}

/**
nonReentrant
deposit asset
redeem/withdraw
borrow
add collateral,
remove collateral,
liquidate,
repay,
repay behalf,
update exchange rate,
update interest rate,
onlyVault
update oracle,
update rateCalculator
minting, redeeming, depositing
 add collateral in batches
 batch liquidation
 update exchange rate + accue interest when *necessary
 virtual function, is approved borrower.
 instrument functions to override: 
 function estimatedTotalAssets() public view virtual returns (uint256){}
 prepareWithdraw
 liquidatePosition => protocol liquidation for all outstanding debt.
 */