pragma solidity ^0.8.16;
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Controller} from "../protocol/controller.sol"; 
import {Vault} from "../vaults/vault.sol"; 
import  "../global/types.sol"; 

library PerpTranchePricer{
    using FixedPointMathLib for uint256;
    using PerpTranchePricer for PricingInfo; 
    uint256 constant BASE_UNIT = 1e18; 
	uint256 constant BASE_MULTIPLIER = 5284965330; //10% at 60% util rate 

	function setNewPrices(
		PricingInfo storage _self, 
		uint256 psu,
		uint256 multiplier, 
		uint256 id, 
		bool constantRF
		) internal {
		_self.psu = psu; 
		_self.URATE_MULTIPLIER = multiplier;  
		_self.ID = id; 
		_self.constantRF = constantRF; 
	}

	/// @notice needs to be updated whenver utilization rate is updated 
 	function storeNewPSU(
 		PricingInfo storage _self, 
 		uint256 uRate
 		) internal {
	    
	    // 1.00000003 ** x seconds
	    uint256 accruedPSU = (BASE_UNIT + _self.prevIntervalRp).rpow(block.timestamp - _self.prevAccrueTime, BASE_UNIT); 

	    _self.psu = _self.psu.mulWadDown(accruedPSU); 
	    _self.prevAccrueTime = block.timestamp; 
	    _self.prevIntervalRp = uRateRpLinear(uRate, _self.URATE_MULTIPLIER); 
	}

	/// @notice Get Promised return as function of uRate, 0<= uRate<= 1e18
	function uRateRpLinear(uint256 uRate, uint256 multiplier) internal pure returns(uint256){
		return multiplier > 0? uRate.mulWadDown(multiplier) : uRate.mulWadDown(BASE_MULTIPLIER); 
	}

	function refreshViewCurrentPricing(
		PricingInfo storage _self, 
		uint256 uRate, 
		uint256 juniorSupply, 
		PoolData memory perp
		) public returns(uint256 psu, uint256 pju, uint256 levFactor){
		_self.storeNewPSU(uRate); 
		return viewCurrentPricing(_self, perp,juniorSupply ); 
	}

	function viewCurrentPricing(
		PricingInfo memory _self,
		PoolData memory perp, 
		uint256 juniorSupply
		) public view returns(uint256 psu, uint256 pju, uint256 levFactor){
	    //TODO should not tick during assessment 
	 //    localVars memory vars; 
	 //    uint256 marketId = _self.ID; 
	 //    levFactor = perp.leverageFactor; 

	 //    require(perp.inceptionPrice > 0, "0 price"); 

	 //    vars.seniorSupply = vars.juniorSupply.mulWadDown(perp.leverageFactor); 
	 //    vars.totalAssetsHeldScaled = vault.instrumentAssetOracle(marketId, vars.juniorSupply, vars.seniorSupply)
	 //      .mulWadDown(perp.inceptionPrice); 

	 //    if (vars.seniorSupply == 0) return(psu, psu,levFactor); 

		// if(_self.constantRF){
		// 	psu = perp.inceptionPrice.mulWadDown((BASE_UNIT+ perp.promised_return)
  //   		 .rpow(block.timestamp - perp.inceptionTime, BASE_UNIT));
		// } else {
		// 	psu = _self.psu; 
		// }

		// // Check if all seniors can redeem
	 //    if (vars.totalAssetsHeldScaled < psu.mulWadDown(vars.seniorSupply)){
	 //    	psu = vars.totalAssetsHeldScaled.divWadDown(vars.seniorSupply); 
	 //    	vars.belowThreshold = true; 
	 //    }

	 //    // should be 0 otherwise 
	 //    if(!vars.belowThreshold) pju = (vars.totalAssetsHeldScaled 
	 //      - psu.mulWadDown(vars.seniorSupply)).divWadDown(vars.juniorSupply); 
	 //    console.log('psuhere', psu, pju, levFactor); 
	}

  

	struct localVars{

	    uint256 totalAssetsHeldScaled; 
	    uint256 juniorSupply;
	    uint256 seniorSupply; 

	    bool belowThreshold; 
	}

}
