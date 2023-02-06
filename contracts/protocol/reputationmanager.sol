pragma solidity ^0.8.16;
import "forge-std/console.sol";

import {config} from "../utils/helpers.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Controller} from "./controller.sol"; 
import {StorageHandler} from "../global/GlobalStorage.sol"; 

contract ReputationManager {
    using FixedPointMathLib for uint256;

    mapping(address=>uint256) public trader_scores; // trader address => score
    mapping(address=>bool) public isRated;
    address[] public traders;

    address controller;
    address marketManager;

    address deployer;

    modifier onlyProtocol() {
        require(msg.sender == controller || msg.sender == marketManager || msg.sender == deployer, "ReputationManager: !protocol");
        _;
    }
    // event pullLogged(uint256 marketId, address recipient, );
    event reputationUpdated(uint256 marketId, address recipient);

    constructor(
        address _controller,
        address _marketManager
    ) {
       controller = _controller;
       marketManager = _marketManager;
       deployer = msg.sender;
    }
  StorageHandler public Data; 
  function setDataStore(address dataStore) public onlyProtocol{
    Data = StorageHandler(dataStore); 
  }
    struct RepLog{
        uint256 collateralAmount; 
        uint256 bondAmount; 
        uint256 budget; 
        bool perpetual; 
        //TODO place this info elsewhere or do packing
    }

    mapping(address=> mapping(uint256=> RepLog)) public repLogs; //trader=> marketid=>replog 

    function getRepLog(address trader, uint256 marketId) external view returns(RepLog memory){
        return repLogs[trader][marketId]; 
    }

    event RecordPull(address trader, uint256 marketId, uint256 bondAmount, uint256 collateral_amount, uint256 budget, bool perpetual);

    /// @notice record for reputation updates whenever trader buys longZCB
    function recordPull(
        address trader, 
        uint256 marketId, 
        uint256 bondAmount, 
        uint256 collateral_amount, 
        uint256 budget,
        bool perpetual
        ) external onlyProtocol{
        RepLog memory newLog = repLogs[trader][marketId]; 
        newLog.collateralAmount += collateral_amount; 
        newLog.bondAmount += bondAmount; 
        newLog.perpetual = perpetual; 
        newLog.budget = budget; 

        repLogs[trader][marketId] = newLog;   

        emit RecordPull(trader, marketId, bondAmount, collateral_amount, budget, perpetual);
    }

    /// @notice updates reputation whenever trader redeems 
    /// param premature is true if trader redeems/sells before maturity 
    /// param redeemAmount is 0 if !perpetual, since for those traders will redeem all at once 
    function recordPush(
        address trader, 
        uint256 marketId, 
        uint256 bondPrice, 
        bool premature, 
        uint256 redeemAmount//in bonds 
        ) external onlyProtocol {
        RepLog memory newLog = repLogs[trader][marketId]; 

        uint256 avgPrice = newLog.collateralAmount.divWadDown(newLog.bondAmount); 

        // Penalize premature sells 
        if(premature){
            _updateReputation(marketId, trader, false, 1e18, newLog); 
            delete repLogs[trader][marketId]; 
        }
        // What about when trader buys during assessment at discount?  
        // if instrument is perpetual, increment if exit price > avgPrice by 
        // proportional to the diff in price  
        if(newLog.perpetual){
            if (bondPrice >= avgPrice) 
                _updateReputation(marketId, trader, true,  bondPrice-avgPrice, newLog); 
            else 
                _updateReputation(marketId, trader, false,  avgPrice - bondPrice, newLog); 

            require(newLog.collateralAmount >= redeemAmount.mulWadDown(avgPrice), "logERR1");
            require(newLog.bondAmount>= redeemAmount, "logERR2"); 
            unchecked{
                newLog.collateralAmount -= redeemAmount.mulWadDown(avgPrice);
                newLog.bondAmount -= redeemAmount; 
                repLogs[trader][marketId] = newLog; 
            }
        }

        // if instrument is fixed term, increment if redemptionprice >= 1, 
        // no change if 1>= redemption price >= avgPrice and decrement otherwise 
        else{
            //bondPrice is redemptionprice for fixed term instruments
            if(bondPrice>= 1e18)
                _updateReputation(marketId, trader, true, bondPrice-avgPrice, newLog); 
            
            else if(bondPrice <= avgPrice && bondPrice < 1e18)
                _updateReputation(marketId, trader, false, avgPrice-bondPrice, newLog);  
            // Redeeming everything at maturity 
            delete repLogs[trader][marketId];             
        }


    }

    /// @notice given a hypoethetical bond price, calculate how much reputation one will gain
    function expectedRepGain(
        address trader, 
        uint256 marketId, 
        uint256 bondPrice, 
        uint256 incremntalAmount, 
        uint256 incrementalBondAmount) external view returns(int256 expectedGain){
        RepLog memory log = repLogs[trader][marketId]; 

        uint256 avgPrice = (log.collateralAmount+incremntalAmount)
            .divWadDown(log.bondAmount + incrementalBondAmount); 
        uint256 priceChange = bondPrice- avgPrice; 
        uint256 implied_probs; 

        if(log.perpetual){
            implied_probs = log.collateralAmount.divWadDown(log.budget); 
            expectedGain = (bondPrice >= avgPrice)
                ? int256(priceChange.mulWadDown(implied_probs))
                : -int256(priceChange.mulWadDown(implied_probs)); 
        } else {
            implied_probs = calcImpliedProbability(
                log.bondAmount, 
                log.collateralAmount, 
                log.budget
                ); 
            if(bondPrice>= 1e18)
                expectedGain = int256(priceChange.mulWadDown(implied_probs)); 
            else if(bondPrice <= avgPrice && bondPrice < 1e18)
                expectedGain = -int256(priceChange.mulWadDown(implied_probs)); 
        }
    }

    /// @notice when market is resolved(maturity/early default), calculates score
    /// and update each assessment phase trader's reputation, called by individual traders when redeeming
    function _updateReputation(
        uint256 marketId,
        address trader,
        bool increment, 
        uint256 priceChange, 
        RepLog memory log
    ) internal {

        uint256 implied_probs = log.perpetual
            ? log.collateralAmount.divWadDown(log.budget)
            : calcImpliedProbability(
                log.bondAmount, 
                log.collateralAmount, 
                log.budget
                ); 

        uint256 change = priceChange.mulWadDown(implied_probs); 
                        // log.perpetual
                        // ? priceChange.mulWadDown(implied_probs) * 
                        // : implied_probs.mulDivDown(implied_probs, config.WAD);

        if (increment) {
            incrementScore(trader, change);
        } else {
            decrementScore(trader, change);
        }
    }

    //function expectedRepGain()


    /// @notice calculates implied probability of the trader, used to
    /// update the reputation score by brier scoring mechanism
    /// @param budget of trader in collateral decimals
    function calcImpliedProbability(
        uint256 bondAmount,
        uint256 collateral_amount,
        uint256 budget
    ) public pure returns (uint256) {
        require(bondAmount > 0 && collateral_amount > 0, "0div"); 
      // TODO underflows when avgprice bigger than wad
        uint256 avg_price = collateral_amount.divWadDown(bondAmount);
        uint256 b = avg_price.mulWadDown(config.WAD - avg_price);
        uint256 ratio = bondAmount.divWadDown(budget);

        return ratio.mulWadDown(b) + avg_price;
    }

    function calculateMinScore(uint256 percentile) view external returns (uint256) {
        uint256 l = traders.length * config.WAD;
        if (percentile / 1e2 == 0) {
        return 0;
        }
        uint256 x = l.mulWadDown(percentile / 1e2);
        x /= config.WAD;
        return trader_scores[traders[x - 1]];
    }

    // change visiblity, external only for testing.
    function setTraderScore(address trader, uint256 score) external {
        uint256 prev_score = trader_scores[trader];
        if (score > prev_score) {
        incrementScore(trader, score - prev_score);
        } else if (score < prev_score) {
        decrementScore(trader, prev_score - score);
        }
    }
    
    function isReputable(address trader, uint256 percentile) view external returns (bool) {
        uint256 k = findTrader(trader);
        uint256 n = (traders.length - (k+1))*config.WAD;
        uint256 N = traders.length*config.WAD;
        uint256 p = uint256(n).divWadDown(N)*10**2;

        if (p >= percentile) {
        return true;
        } else {
        return false;
        }
    }

    // TODO 
    function expectedIncrement(address manager) public view returns(uint256){

    }

    /**
    @dev percentile is is wad 0-100
    @notice returns a list of top X percentile traders excluding the utilizer. 
    */
    function filterTraders(uint256 percentile, address utilizer) view public returns (address[] memory) {
        uint256 l = traders.length * config.WAD;
        
        // if below minimum percentile, return all traders excluding the utilizer
        if (percentile / 1e2 == 0) {
        if (isRated[utilizer]) {
            address[] memory result = new address[](traders.length - 1);

            uint256 j = 0;
            for (uint256 i=0; i<traders.length; i++) {
            if (utilizer == traders[i]) {
                j = 1;
                continue;
            }
            result[i - j] = traders[i];
            }
            return result;
        } else {
            return traders;
        }
        }

        uint256 x = l.mulWadDown((config.WAD*100 - percentile) / 1e2);
        x /= config.WAD;

        address[] memory selected; 
        if (utilizer == address(0) || !isRated[utilizer]) {
        selected = new address[](x);
        for (uint256 i=0; i<x; i++) {
            selected[i] = traders[i];
        }
        } else {
        selected = new address[](x - 1);
        uint256 j=0;
        for (uint256 i = 0; i<x; i++) {
            if (traders[i] == utilizer) {
            j = 1;
            continue;
            }
            selected[i - j] = traders[i];
        }
        }

        return selected;
    }

    function getTraders() view public returns (address[] memory) {
        return traders;
    }

    event ScoreUpdated(address trader, uint256 score);
    /**
    @notice increments trader's score
    @dev score >= 0, update > 0
    */
    function incrementScore(address trader, uint256 update) onlyProtocol public {
        trader_scores[trader] += update;
        _updateRanking(trader, true);
        emit ScoreUpdated(trader, trader_scores[trader]);
    }

    function testIncrementScore(uint256 update) public {
        trader_scores[msg.sender] += update;
        _updateRanking(msg.sender, true);
        emit ScoreUpdated(msg.sender, trader_scores[msg.sender]);
    }

    /**
    @notice decrements trader's score
    @dev score >= 0, update > 0
    */
    function decrementScore(address trader, uint256 update) onlyProtocol public {
        if (update >= trader_scores[trader]) {
        trader_scores[trader] = 0;
        } else {
        trader_scores[trader] -= update;
        }
        _updateRanking(trader, false);
        emit ScoreUpdated(trader, trader_scores[trader]);
    }

    /**
    @notice updates top trader array
    @dev holy moly is this ugly
    */
    function _updateRanking(address trader, bool increase) internal {
        uint256 score = trader_scores[trader];

        if (!isRated[trader]) {
        isRated[trader] = true;
        if (traders.length == 0) {
            traders.push(trader);
            return;
        }
        for (uint256 i=0; i<traders.length; i++) {
            if (score > trader_scores[traders[i]]) {
            traders.push(address(0));
            _shiftRight(i, traders.length-1);
            traders[i] = trader;
            return;
            }
            if (i == traders.length - 1) {
            traders.push(trader);
            return;
            }
        }
        } else {
        uint256 k = findTrader(trader);
        //swap places with someone.
        if ((k == 0 && increase)
        || (k == traders.length - 1 && !increase)) {
            return;
        }

        if (increase) {
            for (uint256 i=0; i<k; i++) {
            if (score > trader_scores[traders[i]]) {
                _shiftRight(i,k);
                traders[i] = trader;
                return;
            }
            }
        } else {
            for (uint256 i=traders.length - 1; i>k; i--) {
            if (score < trader_scores[traders[i]]) {
                _shiftLeft(k, i);
                traders[i] = trader;
                return;
            }
            }
        }
        }
    }

    function findTrader(address trader) public view returns (uint256) {
    for (uint256 i=0; i<traders.length; i++) {
        if (trader == traders[i]) {
            return i;
        }
        }
    }

    /**
    @notice helpers
    */
    function _shiftRight(uint256 pos, uint256 end) internal {
        for (uint256 i=end; i>pos; i--) {
        traders[i] = traders[i-1];
        }
    }

    function _shiftLeft(uint256 pos, uint256 end) internal {
        for (uint256 i=pos; i<end; i++) {
        traders[i] = traders[i+1];
        }
    }
    
}