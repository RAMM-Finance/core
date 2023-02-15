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
import {Auctioneer} from "./auctioneer.sol";

// import "@prb/math/SD59x18.sol";

interface Bouncer {
    function borrowerAllowed(address _borrower) external view returns (bool);
}

contract BouncerLike is Bouncer {
    function borrowerAllowed(address _borrower) external view override returns (bool) {
        return true;
    }
}

// https://github.com/FraxFinance/fraxlend
/// ****THIS IS A PROOF OF CONCEPT INSTRUMENT.
contract PoolInstrument is
    ERC4626,
    Instrument,
    PoolConstants,
    ReentrancyGuard,
    // Pausable,
    ERC721TokenReceiver
{
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
    struct Config {
        uint256 totalCollateral;
        uint256 maxAmount;
        uint256 maxBorrowAmount;
        bool isERC20;
        // auction parameters
        uint256 tau; // seconds after auction start when the price reaches zero -> linearDecrease
        uint256 cusp; // percentage price drop that can occur before an auction must be reset.
        uint256 tail; // seconds that can elapse before an auction must be reset.
        uint256 buf; // auction start price = buf * maxAmount
    }

    /// @notice amount: asset token borrowed, shares = total shares outstanding
    VaultAccount public totalBorrow;
    /// @notice amount: total asset supplied + interest earned, shares = total shares outstanding
    VaultAccount public totalAsset;

    mapping(bytes32 => Config) public collateralConfigs; // collateral address => tokenId (0 for erc20) => collateral data.
    mapping(bytes32 => bool) public approvedCollateral;
    mapping(bytes32 => mapping(address => uint256)) public userERC20s; // per collateral, user balance of collateral. id -> user -> balance.
    mapping(bytes32 => address) public userERC721s; // nft addr => tokenId => owner.
    mapping(address => uint256) public userBorrowShares; // user -> shares, this should be equivalent to balanceOf(user), since pool is vault.

    // mapping(address=>uint256) private baseUnits; // equivalent to 10**decimals for ERC20s, 1 for NFTs.
    mapping(address => mapping(bytes32 => bool)) public enabledCollateral; // user -> collateral -> enabled.
    mapping(address => CollateralLabel[]) public userCollateral;

    // *** id for collateral = keccak256(abi.encodePacked(collateral, tokenId))

    IRateCalculator public rateContract;

    /// @dev depends on rateCalculator used
    bytes public rateInitCallData;

    CurrentRateInfo public currentRateInfo;
    CollateralLabel[] private collaterals; //approved collaterals.
    ReputationManager private reputationManager;
    Auctioneer private auctioneer;
    uint256 public r; // reputation score for this instrument.

    constructor(
        address _vault,
        address _reputationManager,
        uint256 _r,
        address _utilizer,
        string memory _name,
        string memory _symbol,
        address _rateCalculator,
        bytes memory _rateInitCallData,
        CollateralLabel[] memory _collaterals,
        Config[] memory _collateralData
    )
        Instrument(_vault, _utilizer)
        ERC4626(Vault(_vault).UNDERLYING(), _name, _symbol)
    {
        rateContract = IRateCalculator(_rateCalculator);
        rateInitCallData = _rateInitCallData;
        rateContract.requireValidInitData(_rateInitCallData);

        // need to check for added collateral that erc20 is erc20. ability to add or remove accepted collateral.

        reputationManager = ReputationManager(_reputationManager);
        r = _r;

        for (uint256 i = 0; i < _collaterals.length; i++) {
            _addAcceptedCollateral(
                _collaterals[i].tokenAddress,
                _collaterals[i].tokenId,
                _collateralData[i]
            );
        }
    }

    /**
     helper fxn for computing id for collateral, tokenId == 0 for ERC20s.
     */
    function computeId(address _addr, uint256 _tokenId)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_addr, _tokenId));
    }

    function getCollateralConfig(bytes32 collateralId)
        public
        view
        returns (Config memory)
    {
        return collateralConfigs[collateralId];
    }

    function getAcceptedCollaterals()
        public
        view
        returns (CollateralLabel[] memory)
    {
        return collaterals;
    }

    function setAuctioneer(address _auctioneer) public {
        require(msg.sender == vault.owner(), "only owner");
        auctioneer = Auctioneer(_auctioneer);
    }

    // event NewCollateralAdded(address collateral, uint256 tokenId, uint256 maxAmount, uint256 maxBorrowAmount, bool isERC20);
    // legacy for tests, remove later.

    function addAcceptedCollateral(
        address _collateral,
        uint256 _tokenId,
        Config calldata _config
    ) public {
        require(msg.sender == vault.owner(), "only owner");
        _addAcceptedCollateral(_collateral, _tokenId, _config);
    }

    /**
     @notice adds a new collateral to the instrument
     */
    function _addAcceptedCollateral(
        address _collateral,
        uint256 _tokenId,
        Config memory _config
    ) internal {
        // need to ensure that _config isERC20 is correct.
        // max borrow must be less than max amount.
        bytes32 id = computeId(_collateral, _tokenId);
        require(!approvedCollateral[id], "already approved");
        require(
            _config.maxBorrowAmount < _config.maxAmount,
            "maxBorrowAmount must be less than maxAmount"
        );
        if (_config.isERC20) {
            require(_tokenId == 0, "tokenId must be 0 for ERC20");
        }
        _config.totalCollateral = 0;
        collateralConfigs[id] = _config;
        collaterals.push(CollateralLabel(_collateral, _tokenId));
        approvedCollateral[id] = true;
    }

    function updateConfig(
        CollateralLabel calldata _label,
        Config calldata _config
    ) public {
        require(msg.sender == vault.owner(), "!owner");
        bytes32 id = computeId(_label.tokenAddress, _label.tokenId);
        require(approvedCollateral[id], "!collateral_approved");
        collateralConfigs[id] = _config;
    }

    // INTERNAL HELPERS

    modifier onlyApprovedCollateral(address _collateral, uint256 _tokenId) {
        require(
            approvedCollateral[computeId(_collateral, _tokenId)],
            "!collateral_approved"
        );
        _;
    }

    function _totalAssetAvailable(
        VaultAccount memory _totalAsset,
        VaultAccount memory _totalBorrow
    ) internal pure returns (uint256) {
        return _totalAsset.amount - _totalBorrow.amount;
    }

    // INTEREST RATE LOGIC
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

        // If there are no borrows or contract is paused, no interest adds and we reset interest rate
        if (_totalBorrow.shares == 0) {
            // if (!paused()) {
            //     _currentRateInfo.ratePerSec = DEFAULT_INT;
            // }
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
            uint256 _utilizationRate = (UTIL_PREC * _totalBorrow.amount) /
                _totalAsset.amount;
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
            _interestEarned =
                (_deltaTime *
                    _totalBorrow.amount *
                    _currentRateInfo.ratePerSec) /
                1e18;

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

    // SOLVENCY* LOGIC

    /// @notice Checks if total amount of asset user borrowed is less than max borrow threshold AFTER executing contract code
    modifier canBorrow(address _borrower) {
        _;
        require(_canBorrow(_borrower), "!solvent");
    }

    modifier isSolvent(address _borrower) {
        _;
        bool isLiq = _isLiquidatable(_borrower);
        require(!isLiq, "!solvent");
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
        return
            _maxBorrowableAmount >=
            totalBorrow.toAmount(userBorrowShares[_borrower], false);
    }

    function getMaxBorrow(address _borrower)
        public
        view
        returns (uint256 _maxBorrowableAmount)
    {
        CollateralLabel[] memory userCollaterals = userCollateral[_borrower];

        for (uint256 i; i < userCollaterals.length; i++) {
            CollateralLabel memory _collateral = userCollaterals[i];
            bytes32 id = computeId(
                _collateral.tokenAddress,
                _collateral.tokenId
            );
            Config memory _collateralData = collateralConfigs[id];
            if (_collateralData.isERC20 && userERC20s[id][_borrower] > 0) {
                uint256 _d = ERC20(_collateral.tokenAddress).decimals();
                _maxBorrowableAmount +=
                    (userERC20s[id][_borrower] *
                        _collateralData.maxBorrowAmount) /
                    (10**_d); // <= precision of collateral.
            } else if (userERC721s[id] == _borrower) {
                _maxBorrowableAmount += _collateralData.maxBorrowAmount;
            }
        }
    }

    /// @notice returns how much collateral can be removed from a borrower given the debt condition
    /// borrowed assets < maxBorrowAmount, then collateral can be removed,
    // only needed for erc20s.
    // function removeableCollateral(
    //     address _borrower,
    //     uint256 tokenId,
    //     address collateral
    // ) public view returns (uint256) {
    //     //800 borrowable = 800 * 1, 600borrowed (800-x)*1 - 600 = 0 x=?
    //     //800*1-x*1-600 , x = (800*1 - 600)/1
    //     uint256 _maxBorrowableAmount = getMaxBorrow(_borrower);
    //     bytes32 id = computeId(collateral, tokenId);
    //     uint256 perUnitMaxBorrowAmount = collateralConfigs[id].maxBorrowAmount;
    //     //check solvency
    //     return
    //         ((_maxBorrowableAmount -
    //             totalBorrow.toAmount(userBorrowShares[_borrower], true)) *
    //             ERC20(collateral).decimals()) / perUnitMaxBorrowAmount;
    // }

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
        address _reciever,
        bool _enable
    )
        external
        canBorrow(msg.sender)
        nonReentrant
        // whenNotPaused
        returns (uint256 _shares)
    {
        _addInterest();

        if (
            _collateral != address(0) && (_collateralAmount > 0 || _tokenId > 0)
        ) {
            bytes32 id = computeId(_collateral, _tokenId);
            require(approvedCollateral[id], "!unapproved");
            if (_enable) {
                enableCollateral(_collateral, _tokenId);
            }
            _addCollateral(
                msg.sender,
                _collateral,
                _collateralAmount,
                msg.sender,
                _tokenId
            );
        }
        // borrow asset.
        _shares = _borrow(_borrowAmount.safeCastTo128(), _reciever);
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

    // function repayWithAmount(uint256 _amount, address _borrower)
    //     external
    //     nonReentrant
    //     returns (uint256 _sharesToRepay)
    // {
    //     VaultAccount memory _totalBorrow = totalBorrow;
    //     _sharesToRepay = _totalBorrow.toShares(_amount, true);
    //     _repay(
    //         _totalBorrow,
    //         _amount.safeCastTo128(),
    //         _sharesToRepay.safeCastTo128(),
    //         msg.sender,
    //         _borrower
    //     );
    // }

    function repay(uint256 _shares, address _borrower)
        external
        nonReentrant
        returns (uint256 _amountToRepay)
    {
        VaultAccount memory _totalBorrow = totalBorrow;
        _amountToRepay = _totalBorrow.toAmount(_shares, true);
        console.log("amount to repay: ", _amountToRepay);
        _repay(
            _totalBorrow,
            _amountToRepay.safeCastTo128(),
            _shares.safeCastTo128(),
            msg.sender,
            _borrower
        );
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

        // need to check if liquidatable, if so and there are open auctions, then need to close those auctions.
        if (auctioneer.getActiveUserAuctions(_borrower).length != 0) {
            auctioneer.closeAllAuctions(_borrower);
        }
    }

    // ADD/REMOVE/ENABLE/DISABLE COLLATERAL LOGIC
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

    function enableCollateral(address _collateral, uint256 _tokenId)
        public
        onlyApprovedCollateral(_collateral, _tokenId)
    {
        // if already enabled, then return
        bytes32 id = computeId(_collateral, _tokenId);
        if (enabledCollateral[msg.sender][id]) {
            return;
        }
        enabledCollateral[msg.sender][id] = true;
        userCollateral[msg.sender].push(CollateralLabel(_collateral, _tokenId));
    }

    /**
     can only disable collateral if no collateral balance.
     */
    function disableCollateral(address _collateral, uint256 _tokenId)
        public
        
        onlyApprovedCollateral(_collateral, _tokenId)
        isSolvent(msg.sender)
    {
        // if already enabled, then return
        bytes32 id = computeId(_collateral, _tokenId);
        if (!enabledCollateral[msg.sender][id]) {
            return;
        }

        // require zero collateral, maybe this isn't necessary.
        require(
            userERC20s[id][msg.sender] == 0 ||
                userERC721s[id] != address(msg.sender),
            "must remove all remaining collateral to disable"
        );

        // switch w/ last and pop
        CollateralLabel[] memory arr = userCollateral[msg.sender];
        for (uint256 i; i < arr.length; i++) {
            if (
                arr[i].tokenAddress == _collateral && arr[i].tokenId == _tokenId
            ) {
                userCollateral[msg.sender][i] = userCollateral[msg.sender][
                    userCollateral[msg.sender].length - 1
                ];
                userCollateral[msg.sender].pop();
                break;
            }
        }

        enabledCollateral[msg.sender][id] = false;
    }

    /// @notice The ```addCollateral``` function allows the caller to add Collateral Token to a borrowers position
    /// @dev msg.sender must call ERC20.approve() on the Collateral Token contract prior to invocation, or ERC721.approve().
    /// @param _collateralAmount The amount of Collateral Token to be added to borrower's position
    /// @param _borrower The account to be credited
    function addCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _borrower,
        bool _enable
    ) external onlyApprovedCollateral(_collateral, _tokenId) nonReentrant {
        _addInterest();

        if (_enable) {
            enableCollateral(_collateral, _tokenId);
        }

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
        bool _isERC20 = collateralConfigs[id].isERC20;

        if (_sender != address(this)) {
            if (_isERC20) {
                userERC20s[id][_borrower] += _collateralAmount;
                collateralConfigs[id].totalCollateral += _collateralAmount;
                ERC20(_collateral).safeTransferFrom(
                    _sender,
                    address(this),
                    _collateralAmount
                );
            } else {
                userERC721s[id] = _borrower;
                ERC721(_collateral).safeTransferFrom(
                    _sender,
                    address(this),
                    _tokenId
                );
            }
        }
        emit AddCollateral(_borrower, _collateral, _tokenId, _collateralAmount);
    }

    /**
     erc20: removes all collateral so that maxBorrow === existing borrow.
     erc721: if can remove collateral, then removes it, otherwise reverts.
     */
    // function removeAvailableCollateral(
    //     address _collateral,
    //     uint256 _tokenId,
    //     address _receiver
    // )
    //     external
    //     nonReentrant
    //     canBorrow(msg.sender)
    //     onlyApprovedCollateral(_collateral, _tokenId)
    //     returns (uint256 removeable)
    // {
    //     _addInterest();

    //     removeable = removeableCollateral(msg.sender, _tokenId, _collateral);

    //     _removeCollateral(
    //         _collateral,
    //         removeable,
    //         _tokenId,
    //         msg.sender,
    //         _receiver
    //     );
    // }

    function removeCollateral(
        address _collateral,
        uint256 _tokenId,
        uint256 _collateralAmount,
        address _receiver,
        bool _disable
    )
        external
        nonReentrant
        canBorrow(msg.sender)
        onlyApprovedCollateral(_collateral, _tokenId)
    {
        _addInterest();

        if (_disable) {
            disableCollateral(_collateral, _tokenId);
        }

        // Note: exchange rate is irrelevant when borrower has no debt shares
        _removeCollateral(
            _collateral,
            _collateralAmount,
            _tokenId,
            msg.sender,
            _receiver
        );
    }

    function _removeCollateral(
        address _collateral,
        uint256 _collateralAmount,
        uint256 _tokenId,
        address _borrower,
        address _receiver
    ) internal {
        // Interactions
        bytes32 id = computeId(_collateral, _tokenId);
        bool _isERC20 = collateralConfigs[id].isERC20;
        if (_receiver != address(this)) {
            if (_isERC20) {
                // console.log("removing erc20 collateral");
                // console.log("userCollateralerc20: ", userERC20s[id][_borrower] );
                // console.log("collateralAmount: ", _collateralAmount);
                userERC20s[id][_borrower] -= _collateralAmount;
                collateralConfigs[id].totalCollateral -= _collateralAmount;
                ERC20(_collateral).safeTransfer(_receiver, _collateralAmount);
            } else {
                require(userERC721s[id] == _borrower, "not owner of nft");
                delete userERC721s[id];
                ERC721(_collateral).safeTransferFrom(
                    address(this),
                    _receiver,
                    _tokenId
                );
            }
        }
        emit RemoveCollateral(
            _borrower,
            _collateral,
            _tokenId,
            _collateralAmount
        );
    }

    // liquidation logic

    /// @notice collateral should be auctioned off at a minimum price chosen by the managers
    /// underlying balance, collateral balance, what do we know about the user?
    /// if the user's borrow shares are equal to an amount of asset that is greater than the maximum amount they can borrow,
    /// they are suceptible to liquidation
    /// how to determine what collateral should be auctioned off?
    /// maxBorrowAmount
    function _isLiquidatable(address _borrower)
        public
        view
        returns (bool)
    {
        return (accountLiquidity(_borrower) < 0);
    }

    function accountLiquidity(address _borrower) public view returns (int256) {
        uint256 _maxAmount;

        CollateralLabel[] memory userCollaterals = userCollateral[_borrower];
        for (uint256 i; i < userCollaterals.length; i++) {
            CollateralLabel memory _collateral = userCollaterals[i];
            bytes32 id = computeId(
                _collateral.tokenAddress,
                _collateral.tokenId
            );
            Config memory _collateralData = collateralConfigs[id];
            if (_collateralData.isERC20 && userERC20s[id][_borrower] > 0) {
                uint256 _d = ERC20(_collateral.tokenAddress).decimals();
                _maxAmount +=
                    (userERC20s[id][_borrower] * _collateralData.maxAmount) /
                    (10**_d); // <= precision of collateral.
            } else {
                if (userERC721s[id] == _borrower) {
                    _maxAmount += _collateralData.maxAmount;
                }
            }
        }

        return int256(_maxAmount) - int256(totalBorrow.toAmount(userBorrowShares[_borrower], true));
    }

    // function getUserCollateral(address _borrower)
    //     external
    //     view
    //     returns (CollateralLabel[] memory)
    // {
    //     return userCollateral[_borrower];
    // }

    /**
     @notice can only be called when user is liquidatable, all auctions are terminated if not the case.
     need rewards for ppl who call this fxn right?
     */
    function triggerAuction(
        address _borrower,
        address _collateral,
        uint256 _tokenId
    )
        external
        onlyApprovedCollateral(_collateral, _tokenId)
        nonReentrant
        returns (bytes32 _auctionId)
    {
        _addInterest();

        // bool _liquidatable = _isLiquidatable(_borrower);


        if (_isLiquidatable(_borrower)) {
            _auctionId = auctioneer.createAuction(
                _borrower,
                _collateral,
                _tokenId
            );
        }
    }

    /**
     @param _amount: amount of collateral to purchase w/ collateral decimals.
     will reset auction if either tau passed or cusp reached and user still insolvent.
     watch for price increases, maxPrice should be param set by user. mkerdao
     if collateral not erc20, then amount is ignored.
     */
    function purchaseCollateral(
        address _borrower,
        CollateralLabel calldata _label,
        uint256 _amount,
        uint256 _deadline
    ) external returns (uint128 _totalCost) {
        if (block.timestamp > _deadline) {
            revert("past deadline");
        }

        _addInterest();

        bytes32 collateralId = computeId(_label.tokenAddress, _label.tokenId);

        Config memory config = collateralConfigs[collateralId];

        require(auctioneer.getAuction(_borrower, _label.tokenAddress, _label.tokenId).alive, "!alive");

        (bool reset, bool closed) = checkAuction(_borrower, _label.tokenAddress, _label.tokenId);

        if (reset || closed) {
            return 0;
        }

        uint256 currentPrice = auctioneer.purchasePrice(
            _borrower,
            _label.tokenAddress,
            _label.tokenId
        ); // price of collateral in underlying.

        if (config.isERC20) {
            //TODO need to ensure safe to cast here.
            _totalCost = uint128((_amount * currentPrice) / (10**ERC20(_label.tokenAddress).decimals())); // <= decimals of collateral.
            
            console.log("total cost: %s", _totalCost);
            if (_amount == userERC20s[collateralId][_borrower]) {
                auctioneer.closeAuction(
                    _borrower,
                    _label.tokenAddress,
                    _label.tokenId
                );
            }
        } else {
            _totalCost = uint128(currentPrice);
            auctioneer.closeAuction(
                _borrower,
                _label.tokenAddress,
                _label.tokenId
            );

            // if nft sold for more than borrowShares, then give rest of asset to borrower
            if (_totalCost > totalBorrow.toAmount(userBorrowShares[_borrower], false)) {
                uint256 difference = _totalCost - totalBorrow.toAmount(userBorrowShares[_borrower], false);
                
                // difference goes to the pool.
                totalAsset.amount += difference.safeCastTo128();
                asset.safeTransferFrom(msg.sender, address(this), difference);

                _totalCost = uint128(totalBorrow.toAmount(userBorrowShares[_borrower], true));
            }
        }

        VaultAccount memory _totalBorrow = totalBorrow;

        // console.log("cost share: %s", totalBorrow.toShares(_totalCost, false));
        // console.log("user borrow shares: %s", userBorrowShares[_borrower]);
        // console.log("gt?", totalBorrow.toShares(_totalCost, false) > userBorrowShares[_borrower]);

        _repay(
            _totalBorrow,
            _totalCost,
            uint128(totalBorrow.toShares(_totalCost, false)),
            msg.sender,
            _borrower
        );

        // reverts if not enough collateral
        _removeCollateral(
            _label.tokenAddress,
            _amount,
            _label.tokenId,
            _borrower,
            msg.sender
        );

        // total cost of collateral in asset.
    }

    /**
        @notice checks if auction is still valid -> borrower still liq + none of the auction end conditions have been met , if not resets auction.
        only for alive auctions
     */
    function checkAuction(
        address _borrower,
        address _collateral,
        uint256 _tokenId
    ) public onlyApprovedCollateral(_collateral, _tokenId) returns (bool reset, bool closed) {
        Auctioneer.Auction memory auction = auctioneer.getAuction(
            _borrower,
            _collateral,
            _tokenId
        );

        Config memory config = collateralConfigs[computeId(_collateral, _tokenId)];

        // close all auctions if liquidatable.
        if (!_isLiquidatable(_borrower)) {
            auctioneer.closeAllAuctions(
                _borrower
            );
            return (false, true);
        }
        
        if (
            (block.timestamp > auction.creationTimestamp + config.tau) ||
            (auctioneer.purchasePrice(_borrower, _collateral, _tokenId) < config.cusp.mulWadDown(config.maxAmount.mulWadDown(config.buf)))
        ) {
            auctioneer.resetAuction(
                _borrower,
                _collateral,
                _tokenId
            );
            return (true, false);
        }
    }

    /**
     @notice returns cost of purchasing _numTokens of collateral in pool underlying.
     */

    // instrument functions
    function instrumentApprovalCondition()
        public
        view
        virtual
        override
        returns (bool)
    {
        return true;
    }

    function totalAssetAvailable() public view returns (uint256) {
        return _totalAssetAvailable(totalAsset, totalBorrow);
    }

    // ERC4626 functions.

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

        _totalAsset.amount -= assets.safeCastTo128();
        _totalAsset.shares -= shares.safeCastTo128();

        totalAsset = _totalAsset;
    }

    function afterDeposit(uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
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
            int256 _userAccountLiquidity,
            CollateralLabel[] memory _userCollaterals
        )
    {
        _userAssetShares = balanceOf[_address];
        _userAssetAmount = totalAsset.toAmount(_userAssetShares, false);
        _userBorrowShares = userBorrowShares[_address];
        _userBorrowAmount = totalBorrow.toAmount(_userBorrowShares, false);
        _userAccountLiquidity = accountLiquidity(_address);
        _userCollaterals = userCollateral[_address];
    }

    function isWithdrawAble(address holder, uint256 amount)
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
        return totalAsset.amount;
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

    function assetOracle(uint256 totalSupply)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // Default balance oracle
        console.log('totalSupply', totalSupply, previewMint(1e18)); 
        return totalSupply.mulWadDown(previewMint(1e18));
        //TODO custom oracle
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
