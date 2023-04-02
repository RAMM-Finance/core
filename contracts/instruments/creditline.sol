pragma solidity ^0.8.16;
import {Instrument, Proxy} from "../vaults/instrument.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

// for each instrument should detail validator scope.
abstract contract CreditLineBase is Instrument {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    /// @notice can check whether loan expired with expirationTimestamp
    enum LoanStatus{
        // instrument during assessment stage
        awaitingApproval,
        // instrument approved
        approved,
        // borrower has drawn down funds + can repay now
        active,
        // borrower prepayment
        prepayment,
        // grace period
        gracePeriod,
        // instrument attempting to recover underlying i.e. liquidate collateral, skipped if uncollateralized
        recovery,
        // instrument is ready for resolution
        resolution
    }


    /// @notice various types of collateral
    enum CollateralType {
        ERC20,
        ERC721,
        ownership,
        none
    }

    uint256 public proposedPrincipal;
    uint256 public proposedNotionalInterest;
    /// @notice duration should be in seconds
    uint256 public duration;
    // approved approvedPrincipal
    uint256 public approvedPrincipal;
    // approved notional interest
    uint256 public approvedNotionalInterest;
    // per second interest rate
    uint256 public interestRate;
    uint256 internal accumulatedInterest;
    uint256 internal principalOwed;
    uint256 internal interestOwed;
    uint256 internal principalRepaid;
    uint256 internal interestRepaid;
    uint256 public approvalTimestamp;
    uint256 public drawdownTimestamp;
    uint256 public expirationTimestamp;
    // expiry timestamp for grace period
    uint256 public gracePeriodTimestamp;

    CollateralType public collateralType;
    LoanStatus public status;

    ///@notice time at which the interest starts accruing. interestOwed = (block.timestamp - lastRepaymentTimestamp).
    uint256 public lastRepaymentTimestamp;
    uint256 public maxGracePeriod = 2 days;

    /// @notice both _collateral and _oracle could be 0
    /// address if fully uncollateralized or does not have a price oracle 
    /// param _notionalInterest and _principal is initialized as desired variables
    constructor (
        address vault,
        address _borrower, 
        uint256 _proposedPrincipal,
        uint256 _proposedNotionalInterest, 
        uint256 _duration,
        CollateralType _collateralType
    )  Instrument(vault, _borrower) {
        proposedPrincipal =  _proposedPrincipal;
        proposedNotionalInterest = _proposedNotionalInterest;
        duration = _duration;
        collateralType = _collateralType;
        status = LoanStatus.awaitingApproval;
    }

    function expired() public view returns (bool) {
        return block.timestamp > expirationTimestamp;
    }

    /// UTILIZER FUNCTIONS

    /// @notice called by borrower to initiate creditline + interest accrual
    function drawdown() external onlyUtilizer {
        require(status == LoanStatus.approved, "!approved");
        drawdownTimestamp = block.timestamp;
        lastRepaymentTimestamp = block.timestamp;
        status = LoanStatus.active;
        principalOwed = approvedPrincipal;
        interestOwed = approvedNotionalInterest;
        expirationTimestamp = drawdownTimestamp + duration;

        underlyingTransfer(utilizer, approvedPrincipal);
    }

    /// @notice if repayAmount exceeds the interest owed for the period, then the remaining amount will be applied to the approvedPrincipal
    function repay(uint256 repayAmount) external onlyUtilizer {
        require(repayAmount > 0, "!repayAmount");
        require(canRepay(),"!canRepay");

        uint256 repayInterest;
        uint256 repayPrincipal;
        uint256 owedInterest = interestToRepay();
    
        if (repayAmount > owedInterest) {
            repayInterest = owedInterest;
            repayPrincipal = repayAmount - owedInterest;
            accumulatedInterest = 0;
        } else {
            repayInterest = repayAmount;
            accumulatedInterest += owedInterest - repayAmount;
        }

        interestRepaid += repayInterest;
        interestOwed -= repayInterest;

        // adjust down interestOwed
        if (repayPrincipal > 0) {
            principalRepaid += repayPrincipal;
            principalOwed -= repayPrincipal;
            uint256 remainingDuration = (drawdownTimestamp + duration) - block.timestamp;
            interestOwed = interestRate.mulWadDown(remainingDuration.mulWadDown(principalOwed));
        }

        checkRepayment();

        lastRepaymentTimestamp = block.timestamp;

        underlyingTransferFrom(utilizer, address(this), repayAmount);
    }

    function canRepay() internal returns (bool) {
        if (block.timestamp < expirationTimestamp) {
            return status == LoanStatus.active;
        } else {
            return block.timestamp < gracePeriodTimestamp;
        }
    }

    /// @notice interest to repay since the last repayment time
    function interestToRepay() public view returns(uint256) {
        uint256 timeElapsed;

        if (block.timestamp > expirationTimestamp) {
            timeElapsed = expirationTimestamp - lastRepaymentTimestamp;
        } else {
            timeElapsed = block.timestamp - lastRepaymentTimestamp;
        }
        return interestRate.mulWadDown(timeElapsed.mulWadDown(principalOwed)) + accumulatedInterest;
    }

    /// @notice checks whether the creditline has full repayment || prepayment.
    function checkRepayment() public returns (LoanStatus) {
        if (principalOwed == 0 && interestOwed == 0) {
            
            // if premature
            if (approvedPrincipal + approvedNotionalInterest > principalRepaid + interestRepaid) {
                status = LoanStatus.prepayment;

            // if fully repaid
            } else {
                status = LoanStatus.resolution;
            }
        }

        return status;
    }

    /// INSTRUMENT LOGIC
    function resolveCondition() external view override virtual returns (bool) {
        return status == LoanStatus.resolution;
    }

    /// @notice called by vault on marketApproval
    function onMarketApproval(uint256 _approvedPrincipal, uint256 _approvedNotionalInterest) external override onlyVault {
        require(status == LoanStatus.awaitingApproval, "!awaitingApproval");
        approvedPrincipal = _approvedPrincipal; 
        approvedNotionalInterest = _approvedNotionalInterest;
        interestRate = approvedNotionalInterest.divWadDown(duration.mulWadDown(approvedPrincipal));
        status = LoanStatus.approved;
        approvalTimestamp = block.timestamp;
        status = LoanStatus.approved;
    }

    /// VALIDATOR FUNCTIONS

    /// @notice triggers grace period for creditline,
    function triggerGracePeriod(uint256 _duration) onlyValidator external returns (LoanStatus _status) {
        require(block.timestamp > expirationTimestamp, "!expired");
        require(status == LoanStatus.active, "!active");
        require(_duration <= maxGracePeriod, "!duration");
        status = LoanStatus.gracePeriod;
        gracePeriodTimestamp = block.timestamp + _duration;
    }

    // TODO: constraints for validators to trigger recovery
    function triggerRecovery(bytes calldata data) onlyValidator external returns (LoanStatus _status) {
        
        // conditions to trigger recovery
        require(
            // expired loan
            (status == LoanStatus.active && block.timestamp > expirationTimestamp) || 
            // grace period over
            (status == LoanStatus.gracePeriod && block.timestamp >= gracePeriodTimestamp), "!loan_status"
            );
        // must be at loss
        require(
            approvedPrincipal > principalRepaid + interestRepaid, 
            "!at_loss"
        );
        status = LoanStatus.recovery;
        recoverUnderlying(data);
    }

    /// @notice triggers any liquidation of collateral necessary to recover underlying.
    function recoverUnderlying(bytes calldata data) internal virtual;

    function triggerResolve() external onlyValidator {
        require(status != LoanStatus.awaitingApproval, "!approved");
        status = LoanStatus.resolution;
    }

    /// @notice called by vault to transfer collateral back to borrower
    function recoverCollateral() external virtual onlyUtilizer {}
}

/// @notice linear dutch auction for now.
contract ERC721CreditLine is CreditLineBase, ERC721TokenReceiver {
    using FixedPointMathLib for uint256;
    ERC721 collateral;
    uint256 tokenId;
    uint256 public immutable MIN_AUCTION_DURATION = 2 hours;
    uint256 public immutable MAX_AUCTION_DURATION = 1 days;
    uint256 public immutable MINIMUM_MIN_AUCTION_PRICE;
    uint256 public immutable MINIMUM_MAX_AUCTION_PRICE;

    struct Auction {
        uint256 startTimestamp;
        uint256 duration;
        uint256 minPrice;
        uint256 maxPrice;
    }

    Auction public auction;

    constructor(
        address vault,
        address _borrower, 
        uint256 _proposedPrincipal,
        uint256 _proposedNotionalInterest, 
        uint256 _duration,
        uint256 _tokenId,
        address _collateral
    )  CreditLineBase(vault, _borrower, _proposedPrincipal, _proposedNotionalInterest, _duration, CollateralType.ERC721) {
        collateral = ERC721(_collateral);
        tokenId = _tokenId;
        MINIMUM_MAX_AUCTION_PRICE = _proposedPrincipal;
        MINIMUM_MIN_AUCTION_PRICE = 0;
    }

    /// @notice triggers dutch auction for the ERC721 collateral
    function recoverUnderlying(bytes calldata data) internal override {
        (
            uint256 auctionDuration,
            uint256 minPrice,
            uint256 maxPrice
        ) = abi.decode(data, (uint256, uint256, uint256));

        require(auctionDuration > MIN_AUCTION_DURATION && auctionDuration < MAX_AUCTION_DURATION, "!duration");
        require(minPrice > MINIMUM_MIN_AUCTION_PRICE, "!minPrice");
        require(maxPrice > minPrice && maxPrice >= MINIMUM_MAX_AUCTION_PRICE, "!maxPrice");

        auction = Auction({
            startTimestamp: block.timestamp,
            duration: auctionDuration,
            minPrice: minPrice,
            maxPrice: maxPrice
        });
    }

    /// @notice dutch auction, first bid takes collateral.
    function bid() external {
        require(auction.startTimestamp > 0, "!live");
        require(status == LoanStatus.recovery, "!recovery");
        require(msg.sender != utilizer, "!utilizer");
        require(auction.startTimestamp + auction.duration <= block.timestamp, "auction expired");

        uint256 price = auctionPrice();

        underlyingTransferFrom(msg.sender, address(this), price);
        collateral.safeTransferFrom(address(this), msg.sender, tokenId);

        // ready for resolution
        status = LoanStatus.resolution;

        // if auction covers the loss, then utilizer gets the excess value back.
        if (price > approvedPrincipal + approvedNotionalInterest - (principalRepaid + interestRepaid)) {
            underlyingTransfer(utilizer, price - (approvedPrincipal + approvedNotionalInterest));
        }
    }

    /// @notice returns the current price of the erc721 collateral, doesn't perform any creditline status checks
    function auctionPrice() public view returns (uint256 price) {
        Auction memory _auction = auction;

        price = _auction.maxPrice - (_auction.maxPrice - _auction.minPrice).divWadDown(_auction.duration).mulWadDown(block.timestamp - _auction.startTimestamp);
    }

    /// @notice can only reset auction if it has expired without a bid.
    function resetAuction() external onlyValidator {
        require(auction.startTimestamp + auction.duration < block.timestamp, "!expired auction");
        require(status == LoanStatus.recovery, "!recovery");

        auction.startTimestamp = block.timestamp;
    }

    /// INSTRUMENT LOGIC
    function approvalCondition() public override view returns (bool condition) {
        return collateral.ownerOf(tokenId) == address(this);
    }

    function recoverCollateral() public override onlyUtilizer {
        require(status == LoanStatus.resolution, "!resolution");
        require(collateral.ownerOf(tokenId) == address(this), "!collateral");
        collateral.safeTransferFrom(address(this), utilizer, tokenId);
    }
}

/// @notice linear dutch auction for now.
contract ERC20CreditLine is CreditLineBase {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    ERC20 public collateral;
    uint256 private collateralDecimals;
    uint256 public requiredBalance;
    uint256 public recoveredUnderlying;


    uint256 public immutable MIN_AUCTION_DURATION = 2 hours;
    uint256 public immutable MAX_AUCTION_DURATION = 1 days;
    uint256 public immutable MINIMUM_MIN_AUCTION_PRICE = 0;
    uint256 public immutable MINIMUM_MAX_AUCTION_PRICE;

    struct Auction {
        uint256 startTimestamp;
        uint256 duration;
        uint256 minPrice;
        uint256 maxPrice;
    }

    Auction public auction;

    constructor(
        address vault,
        address _borrower,
        uint256 _proposedPrincipal,
        uint256 _proposedNotionalInterest, 
        uint256 _duration,
        address _collateral,
        uint256 _requiredBalance
    )  CreditLineBase(vault, _borrower, _proposedPrincipal, _proposedNotionalInterest, _duration, CollateralType.ERC20) {
        collateral = ERC20(_collateral);
        requiredBalance = _requiredBalance;
        collateralDecimals = collateral.decimals();
        MINIMUM_MAX_AUCTION_PRICE = _proposedPrincipal.divWadDown(requiredBalance * 10 ** (18 - collateralDecimals));
    }

    function recoverUnderlying(bytes calldata data) internal override {
        (
            uint256 auctionDuration,
            uint256 minPrice,
            uint256 maxPrice
        ) = abi.decode(data, (uint256, uint256, uint256));

        require(auctionDuration > MIN_AUCTION_DURATION && auctionDuration < MAX_AUCTION_DURATION, "!duration");
        require(minPrice > MINIMUM_MIN_AUCTION_PRICE, "!minPrice");
        require(maxPrice > minPrice && maxPrice >= MINIMUM_MAX_AUCTION_PRICE, "!maxPrice");

        auction = Auction({
            startTimestamp: block.timestamp,
            duration: auctionDuration,
            minPrice: minPrice,
            maxPrice: maxPrice
        });
    }

    function bid(uint256 amountCollateral) external returns (uint256 totalCost) {
        require(status == LoanStatus.recovery, "!recovery");
        require(msg.sender != utilizer, "!utilizer");
        require(auction.startTimestamp > 0, "!live");
        require(auction.startTimestamp + auction.duration >= block.timestamp, "auction expired");

        uint256 price = auctionPrice();
        uint256 formattedAmount = amountCollateral * 10 ** (18 - collateralDecimals);
        totalCost = formattedAmount.mulWadDown(price);

        underlying.safeTransferFrom(msg.sender, address(this), formattedAmount);
        collateral.safeTransfer(msg.sender, amountCollateral);
        recoveredUnderlying += totalCost;

        if (recoveredUnderlying >= approvedPrincipal + approvedNotionalInterest - (principalRepaid + interestRepaid)) {
            status = LoanStatus.resolution;
            underlying.safeTransfer(utilizer, approvedPrincipal + approvedNotionalInterest - (principalRepaid + interestRepaid));
            if (collateral.balanceOf(address(this)) > 0) collateral.safeTransfer(utilizer, collateral.balanceOf(address(this)));
        }
    }

    /// @notice doesn't perform any checks wrt creditline status || auction state
    function auctionPrice() public view returns (uint256 price) {
        Auction memory _auction = auction;

        price = _auction.maxPrice - (_auction.maxPrice - _auction.minPrice).divWadDown(_auction.duration).mulWadDown(block.timestamp - _auction.startTimestamp);
    }

    function resetAuction() external onlyValidator {
        require(auction.startTimestamp + auction.duration > block.timestamp, "!expired auction");
        require(status == LoanStatus.recovery, "!recovery");
        auction.startTimestamp = block.timestamp;
    }

    /// INSTRUMENT LOGIC
    function approvalCondition() public override view returns (bool condition) {
        return collateral.balanceOf(address(this)) == requiredBalance;
    }

    /// @notice called by utilizer to recover the collateral
    function recoverCollateral() public override onlyUtilizer {
        require(status == LoanStatus.resolution, "!resolution");
        collateral.safeTransfer(utilizer, collateral.balanceOf(address(this)));
    }
}

// contract OwnerCreditline is CreditlineBase {

// }

// contract UncollateralizedCreditline is CreditlineBase {

// }

// interface ICreditlineAuctioneer {
//     function price(uint256 startTimestamp, bytes calldata data) external view returns (uint256 price);
// }

// contract LinearDutch is ICreditlineAuctioneer {
//     function price(bytes calldata data) external view returns (uint256 price) {
//         (uint256 p_i, uint256 t, uint256 k) = abi.decode(data, (uint256, uint256, uint256));
//         return linearPrice(p_i, t, k);
//     }

//     function linearPrice(uint256 p_i, uint256 t, uint256 k) public pure returns (uint256) {
//         return p_i - (p_i * t / k);
//     }
// }

// contract ExponentialDutch is ICreditlineAuctioneer {
//     function price(bytes calldata data) external view returns (uint256 price) {
//         (uint256 p_i, uint256 t, uint256 k) = abi.decode(data, (uint256, uint256, uint256));
//         return exponentialPrice(p_i, t, k);
//     }

//     function exponentialPrice(uint256 p_i, uint256 t, uint256 k) public pure returns (uint256) {
//         return p_i * (k - t) / k;
//     }
// }

// library GradualDutchAuctionDiscrete {
// }

// library GradualDutchAuctionContinuous {

// }