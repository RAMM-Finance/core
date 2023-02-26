pragma solidity ^0.8.16;

import {SyntheticZCBPool} from "../bonds/bondPool.sol"; 
import {ERC20} from "solmate/tokens/ERC20.sol";

library Constants{
	uint256 public constant THRESHOLD_PJU = 5e17; // can't buy if below 0.5 
	uint256 public constant MAX_VAULT_URATE = 10e17; 

	uint256 public constant PRICING_ROUND = 1e12; //round to the nearest 0.000001


    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

}



struct MarketData {
    address instrument_address;
    address utilizer;
}

struct ApprovalData {
    uint256 managers_stake;
    uint256 approved_principal;
    uint256 approved_yield;
}

struct InstrumentData {
	bytes32 name;
	bool isPool; 
	// Used to determine if the Vault will operate on a Instrument.
	bool trusted;
	// Balance of the contract denominated in Underlying, 
	// used to determine profit and loss during harvests of the Instrument.  
	// represents the amount of debt the Instrument has incurred from this vault   
	uint256 balance; // in underlying, IMPORTANT to get this number right as it modifies key states 
	uint256 faceValue; // in underlying
	uint256 marketId;
	
	uint256 principal; //this is total available allowance in underlying
	uint256 expectedYield; // total interest paid over duration in underlying
	uint256 duration;
	string description;
	address instrument_address;
	InstrumentType instrument_type;
	uint256 maturityDate;
	PoolData poolData; 
}

/// @notice probably should have default parameters for each vault
struct PoolData{
	uint256 saleAmount; 
	uint256 initPrice; // init price of longZCB in the amm 
	uint256 promisedReturn; //per unit time 
	uint256 inceptionTime;
	uint256 inceptionPrice; // init price of longZCB after assessment 
	uint256 leverageFactor; // leverageFactor * manager collateral = capital from vault to instrument
	uint256 managementFee; // sum of discounts for high reputation managers/validators
	uint256 sharesOwnedByVault; // amount of erc4626 instrument shares owned by the vault
}

struct PoolPricingParam{
	uint256 incrementRate; 
	uint256 urateUpper; 
	uint256 urateLower;
	uint256 prevAccrueTime; 
	uint256 prevURate; 

	uint256 maxBorrowable; 
}	

struct ExchangeRateData{
	uint256 lastRate; 
	uint256 lastTime; 
	uint256 lastOracleRate;
	bool initialized;  
}


/// @param constantRF -> true if promised return is fixed, false then it is dynamic, fxn(utilization rate).
struct PricingInfo{
	uint256 psu; 

	uint256 prevAccrueTime; 
	uint256 prevIntervalRp; //per second compounding promised return, function of urate 

	// Constants for a given market 
	uint256 URATE_MULTIPLIER; 
	uint256 ID; 

	bool constantRF; 
}


struct CoreMarketData {
	SyntheticZCBPool bondPool; 
	ERC20 longZCB;
	ERC20 shortZCB; 
	string description; // instrument description
	uint256 creationTimestamp;
	uint256 resolutionTimestamp;
	bool isPool; 
}

struct MarketPhaseData {
	bool duringAssessment;
	bool onlyReputable;
	bool resolved;
	bool alive;
	bool atLoss;
	// uint256 min_rep_score;
	uint256 base_budget;
}

  /// @param N: upper bound on number of validators chosen.
  /// @param sigma: validators' stake
  /// @param alpha: minimum managers' stake
  /// @param omega: high reputation's stake 
  /// @param delta: Upper and lower bound for price which is added/subtracted from alpha 
  /// @param r: reputation percentile for reputation constraint phase
  /// @param s: senior coefficient; how much senior capital the managers can attract at approval 
  /// @param steak: steak*approved_principal is the staking amount.
  /// param beta: how much volatility managers are absorbing 
  /// param leverage: how much leverage managers can apply 
  /// param base_budget: higher base_budget means lower decentralization, 
  /// @dev omega always <= alpha
 struct MarketParameters{
	uint256 N;
	uint256 sigma; 
	uint256 alpha; 
	uint256 omega;
	uint256 delta; 
	uint256 r;
	uint256 s;
	uint256 steak;
  }



struct ResolveVar{
	uint256 endBlock; 
	bool isPrepared; 
}

struct Order{
	bool isLong; 
	uint256 price; 
	uint256 amount; 
	uint256 orderId; 
	address owner; 
}




enum InstrumentType {
    CreditLine,
    CoveredCallShort,
    LendingPool, 
    StraddleBuy,
    LiquidityProvision, 
    Other
}
