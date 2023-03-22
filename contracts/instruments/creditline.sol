pragma solidity ^0.8.16;
import {Instrument, Proxy} from "../vaults/instrument.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

contract BaseCreditline is Instrument, ERC721TokenReceiver {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    /// @notice various stages of the creditline
    enum LoanStatus{
        awaitingApproval,
        approved,
        matured,
        gracePeriod, 
        defaulted
    }

    /// @notice various types of collateral
    enum CollateralType {
        liquidERC20,
        liquidERC721,
        nonliquidERC20,
        nonliquidERC721,
        ownership,
        none
    }

    uint256 public proposedPrincipal;
    uint256 public proposedNotionalInterest;
    /// @notice duration should be in seconds
    uint256 public duration;
    // approved principal
    uint256 public principal;
    // approved notional interest
    uint256 public notionalInterest;

    uint256 internal principalOwed;
    uint256 internal interestOwed;
    uint256 internal principalRepayed;
    uint256 internal interestRepayed;
    uint256 resolveBlock;

    CollateralType public collateralType;
    LoanStatus public loanStatus;

    /// @notice both _collateral and _oracle could be 0
    /// address if fully uncollateralized or does not have a price oracle 
    /// param _notionalInterest and _principal is initialized as desired variables
    constructor(
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
        collateralInfo = _collateralInfo;
        collateralType = _collateralType;
        loanStatus = LoanStatus.notApproved;
    }

    /// where area under curve is max_principal 
    function onMarketApproval(uint256 approvedPrincipal, uint256 approvedNotionalInterest) external override onlyVault {
        principal = approvedPrincipal; 
        notionalInterest = approvedNotionalInterest;
        loanStatus = LoanStatus.approvedNotDrawdowned;
        interestOwed = notionalInterest;
    }

    /// @notice Allows a borrower to borrow on their creditline.
    function borrow(uint256 amount) public view onlyUtilizer {
        require(loanStatus.approved, "!approved");
        require(amount <= principal - principalOwed, "!balance");

        principalOwed += amount;
        underlyingTransfer(utilizer, amount);
    }

    function repay(uint256 repayAmount) external onlyUtilizer{
        require(loanStatus == LoanStatus.approved, "!approved");
        uint256 repayInterest;
        uint256 repayPrincipal;

        if (principalOwed == 0) {
            repayInterest = repayAmount;
        } else if (principalOwed < repayAmount) {
            repayInterest = repayAmount - principalOwed;
            repayPrincipal = principalOwed;
        } else {
            repayPrincipal = repayAmount;
        }

        // state changes
        interestRepayed += repayInterest;
        principalRepayed += repayPrincipal;
        principalOwed -= repayPrincipal;
        interestOwed -= repayInterest;

        underlyingTransferFrom(utilizer, address(this), _repayAmount);
    }

    /// @notice called when loan defaults, can trigger auction for collateral, goal is to liquidate collateral for underlying.
    function liquidateCollateral() public virtual;

    function withdrawCollateral() external onlyUtilizer virtual;
}

contract LiquidERC20Creditline is CreditlineBase {
    ERC20 collateral;
    constructor(
        address vault,
        address _borrower, 
        uint256 _proposedPrincipal,
        uint256 _proposedNotionalInterest, 
        uint256 _duration,
        CollateralInfo memory _collateralInfo,
    )  CreditlineBase(vault, _borrower, _proposedPrincipal, _proposedNotionalInterest, _duration, _collateralInfo, CollateralType.liquidERC20) {
        collateralInfo = _collateralInfo;
    }

    function approvalCondition() public view returns (bool condition) {
    }
}

contract LiquidERC721Creditline is CreditlineBase {
    ERC721 collateral;
    constructor(
        address vault,
        address _borrower, 
        uint256 _proposedPrincipal,
        uint256 _proposedNotionalInterest, 
        uint256 _duration,
        CollateralInfo memory _collateralInfo,
    )  CreditlineBase(vault, _borrower, _proposedPrincipal, _proposedNotionalInterest, _duration, _collateralInfo, CollateralType.liquidERC721) {
        collateralInfo = _collateralInfo;
    }

    function approvalCondition() public view returns (bool condition) {
    }
}


contract IlliquidCreditline is CreditlineBase {

}

contract UncollateralizedCreditline is CreditlineBase {

}