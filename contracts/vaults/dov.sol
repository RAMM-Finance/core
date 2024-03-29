pragma solidity ^0.8.16;

import "./vault.sol";
// import {ERC20} from "./tokens/ERC20.sol";
import "openzeppelin-contracts/utils/math/Math.sol";
// import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";
import "forge-std/console.sol";
import {Instrument} from "./instrument.sol";
import {Vault} from "./vault.sol"; 

/// @notice This contract acts as an OTC option platform
/// Utilizer will "propose" a strike price to buy
/// At maturity, premiums from utilizer will be collected by the vault when expires
/// below strike price 
contract CoveredCallOTC is Instrument{
    using FixedPointMathLib for uint256; 

    // address public immutable utilizer;
    uint256 public immutable strikePrice;
    uint256 public immutable pricePerContract; 
    uint256 public immutable shortCollateral; 
    uint256 public immutable longCollateral;
    address public immutable cash; 
    uint256 public immutable maturityTime; 
    uint256 public immutable tradeTime; 

    address public oracle ;
    uint256 public profit; 
    uint256 public constant timeThreshold = 10; 
    bool utilizerClaimed; 

    /// @param _shortCollateral depends on how much underlyingAsset is in the vault. 
    /// @param _pricePerContract is the price that the utilizer is willing to buy 
    /// the call option. Usually implied vol here is lower than external implied vol values 
    constructor(address _vault,
        address _utilizer,
        uint256 _strikePrice, 
        uint256 _pricePerContract, // depends on IV, price per contract denominated in underlying  
        uint256 _shortCollateral, // collateral for the sold options-> this is in underlyingAsset i.e weth 
        uint256 _longCollateral, // collateral amount in underlying for long to pay. (price*quantity)
        address _cash,
        uint256 duration,
        uint256 _tradeTime// when the trade will occur 
        ) Instrument(_vault, _utilizer){
        // TODO shortcollateral must equal principal 
        require(_longCollateral == _shortCollateral.mulWadDown(_pricePerContract), "incorrect setting"); 
        strikePrice = _strikePrice; 
        pricePerContract = _pricePerContract; 
        shortCollateral = _shortCollateral; 
        longCollateral = _longCollateral; 
        cash = _cash;
        tradeTime = block.timestamp+ _tradeTime; 
        maturityTime = block.timestamp + duration;
    }

    function setOracle(address _oracle) public {
        require(msg.sender ==Vault(vault).owner(), "not owner"); 
        oracle = _oracle; 
    }

    // function resolveCondition() external override view returns(bool) {
    //     return true;
    // }

    function returnCollateral() public onlyUtilizer{
        // can't return when approved, only can return when denied.  
        require(block.timestamp<= tradeTime, "redeem window passed"); 
        underlying.transfer(msg.sender, longCollateral); 
    }

    /// @notice returns true if the instrument can be approved
    /// and funds can be directed from vault. Utilizer must have escrowed
    /// to this contract before  
    function approvalCondition() public override view returns(bool){
        return underlying.balanceOf(address(this)) >= longCollateral;
    }
    uint256 public testqueriedPrice=1e18; 
    /// @notice queries oracle for the latest price of the underlying 
    function queryPrice() public view returns(uint256 price){
        //return testqueriedPrice; 
        return strikePrice;  
    }

    /// @notice for a given queriedPrice(usually the spot chainlink price at maturity)
    /// what is the profit returned to the utilizer 
    /// @dev utillizers can call this function at maturity so they can realize profit it is positive 
    /// if they miss the window(timethreshold), they can't realize profit. 
    /// param queriedPrice must be the exact price at which option is exercised, at maturity
    function profitForUtilizer() internal{
        // require(block.timestamp <= maturityTime + timeThreshold  && 
        //     block.timestamp >= maturityTime- timeThreshold , "Time window err"); 
        require(profit == 0, "profit already set"); 
        uint256 queriedPrice = queryPrice(); 

        // Under strike price 
        if (queriedPrice <= strikePrice) profit = 0; 

        // Profit denominated in the base asset for the underlyingAsset, normally a stablecoin 
        else {
            uint256 profitInCash = (queriedPrice - strikePrice).mulWadDown(shortCollateral); 

            // profit in underlying should be divided by the price 
            profit = profitInCash.divWadDown(queriedPrice); 
        }
    }

    /// @notice either option buyers(utilizers) or sellers(protocol)
    /// can claim their proportion of the winnings 
    function claim() external onlyUtilizer{
        require(maturityTime < block.timestamp, "not matured");
        profitForUtilizer(); 

        if (profit==0) return; 
        // require(profit> 0, "0profit"); 

        underlying.transfer(msg.sender, profit); 
        profit = 0; 
        utilizerClaimed = true; 
        vault.pingMaturity(address(this), false); 
    }

    /// @notice called at maturity
    function resolveCondition() external view override returns(bool){
        return ( (block.timestamp >= maturityTime + timeThreshold && profit == 0)
                || utilizerClaimed); 
    }

    /**
    deposit for the utilizer
     */
    function deposit() public onlyUtilizer {
        underlyingTransferFrom(msg.sender, address(this), longCollateral);
    }

    function instrumentStaticSnapshot() public view returns (uint256 _strikePrice, uint256 _pricePerContract, uint256 _shortCollateral, uint256 _longCollateral, uint256 _maturityTime, uint256 _tradeTime, address _oracle){
        return (strikePrice, pricePerContract, shortCollateral, longCollateral, maturityTime, tradeTime, oracle);
    }
}

// TODO extra gains redemption price effects 

// Vault supplies to this instrument, validators can manually do twaps. If price deviates too much 
// between assessment period start to end, validators can pull out, and create new proposals. 

// everytime a manager buys, the same amount needs to be deposited into lyra. lyra wil
// 0.97 buy-> 
// issue poollongzcb-> supply to instrument from vault-> triggers and open position  to lyra
// redeem poollongzcb-> withdraw from instrument to vault -> triggers and close position -> realize profit back to vault 
// pool zcb value is derived from options price using it as an exchange rate. 
// contract CoveredCallLyra is Instrument{
//     using FixedPointMathLib for uint256; 

//     address public immutable utilizer;
//     uint256 public immutable strikePrice;
//     uint256 public immutable pricePerContract; 
//     uint256 public immutable shortCollateral; 
//     uint256 public immutable longCollateral;
//     address public immutable cash; 
//     uint256 public immutable maturityTime; 
//     uint256 public immutable tradeTime; 

//     address public oracle ;
//     uint256 public profit; 
//     uint256 public constant timeThreshold = 10; 
//     bool utilizerClaimed; 

//     /// @param _shortCollateral depends on how much underlyingAsset is in the vault. 
//     /// @param _pricePerContract is the price that the utilizer is willing to buy 
//     /// the call option. Usually implied vol here is lower than external implied vol values 
//     constructor(address _vault,
//         address _utilizer,
//         uint256 _strikePrice, 
//         uint256 _pricePerContract, // depends on IV, price per contract denominated in underlying  
//         uint256 _shortCollateral, // collateral for the sold options-> this is in underlyingAsset i.e weth 
//         uint256 _longCollateral, // collateral amount in underlying for long to pay. (price*quantity)
//         address _cash,
//         uint256 duration,
//         uint256 _tradeTime// when the trade will occur 
//         ) Instrument(_vault, _utilizer){
//         // TODO shortcollateral must equal principal 
//         require(_longCollateral == _shortCollateral.mulWadDown(_pricePerContract), "incorrect setting"); 
//         utilizer = _utilizer;
//         strikePrice = _strikePrice; 
//         pricePerContract = _pricePerContract; 
//         shortCollateral = _shortCollateral; 
//         longCollateral = _longCollateral; 
//         cash = _cash;
//         tradeTime = block.timestamp+ _tradeTime; 
//         maturityTime = block.timestamp + duration;
//     }

//     // @notice when buyer buys longZCB, funds are directed to here  triggers the contract to supply to lyra 
//     function deposit() public onlyVault{

//     }

//     /// @notice returns true if the instrument can be approved
//     /// and funds can be directed from vault. Utilizer must have escrowed
//     /// to this contract before  
//     function instrumentApprovalCondition() public override view returns(bool){
//         return underlying.balanceOf(address(this)) >= longCollateral;
//     }

//     /// @notice short sell a single batch of call options in lyra 
//     function performsSingleTrade() public 
//    // onlyValidator 
//     {
//         lyraOp.openPosition(TradeInputParameters memory params)
//     }


//     /// @notice pull out funds back to vault when price deviation exceeds threshold 
//     function invalidateInstrument() public 
//     //onlyValidator
//     {

//     }







// }
//If you are indeed a scammer, not difficult to make bots that terrorize your account. I really don't deal well with liars and those who rip people off. 
