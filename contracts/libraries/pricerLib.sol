pragma solidity ^0.8.16;
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Controller} from "../protocol/controller.sol"; 
import {Vault} from "../vaults/vault.sol"; 
import  "../global/types.sol"; 
import {Instrument} from "../vaults/instrument.sol"; 
import "forge-std/console.sol";

library PerpTranchePricer{
    using FixedPointMathLib for uint256;
    using PerpTranchePricer for PricingInfo; 
    uint256 constant BASE_UNIT = 1e18; 

	/**
	 @notice setter for PricingInfo
	 */
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

	function setRF(PricingInfo storage _self, bool isConstant) internal{
		_self.constantRF = isConstant; 
	}

	/// @notice needs to be updated whenver utilization rate is updated 
 	function storeNewPSU(
 		PricingInfo storage _self, 
 		uint256 uRate
 		) internal {
	    
	    // 1.00000003 ** x seconds
	    uint256 accruedPSU = (BASE_UNIT + _self.prevIntervalRp).rpow(block.timestamp - _self.prevAccrueTime, BASE_UNIT); 
	    console.log('accruedPSU', accruedPSU, _self.prevIntervalRp, block.timestamp- _self.prevAccrueTime); 
	    _self.psu = _self.psu.mulWadDown(accruedPSU); 
	    _self.prevAccrueTime = block.timestamp; 
	    _self.prevIntervalRp = uRateRpLinear(uRate, _self.URATE_MULTIPLIER); 
	}

	/// @notice Get Promised return as function of uRate, 0<= uRate<= 1e18
	function uRateRpLinear(uint256 uRate, uint256 multiplier) internal pure returns(uint256){
		return multiplier > 0? uRate.mulWadDown(multiplier) : uRate.mulWadDown(Constants.BASE_MULTIPLIER); 
	}

	/// @notice can all seniors redeem for given psu 
	function isSolvent(
		address instrument, 
		uint256 psu, 
		uint256 juniorSupply, 
		PoolData memory perp) public view returns(bool){
		return(
			Instrument(instrument).assetOracle(juniorSupply + juniorSupply.mulWadDown(perp.leverageFactor))
	    	 .mulWadDown(perp.inceptionPrice)
	   		>= psu.mulWadDown(juniorSupply.mulWadDown(perp.leverageFactor)) 
	   	); 
	}

	function constantRF_PSU(
		uint256 inceptionPrice, 
		uint256 promisedReturn, 
		uint256 inceptionTime) public view returns(uint256){
		return inceptionPrice.mulWadDown((BASE_UNIT+ promisedReturn).rpow(block.timestamp - inceptionTime, BASE_UNIT));
	}

	function refreshViewCurrentPricing(
		PricingInfo storage _self, 
		address instrument, 
		PoolData memory perp,
		uint256 juniorSupply, 
		uint256 uRate
		) public returns(uint256 psu, uint256 pju, uint256 levFactor){
		_self.storeNewPSU(uRate); 
		return viewCurrentPricing(_self, instrument, perp,juniorSupply ); 
	}

	/// @notice pricing function for perps
	function viewCurrentPricing(
		PricingInfo memory _self,
		address instrument, 
		PoolData memory perp, 
		uint256 juniorSupply
		) public view returns (uint256 psu, uint256 pju , uint256 levFactor ){
	    //TODO should not tick during assessment 
	    localVars memory vars; 

	    uint256 marketId = _self.ID; 
	    levFactor = perp.leverageFactor; 
	    require(perp.inceptionPrice > 0, "0 price"); 

	    vars.seniorSupply = juniorSupply.mulWadDown(perp.leverageFactor); 
	    vars.totalAssetsHeldScaled = Instrument(instrument).assetOracle(juniorSupply + vars.seniorSupply)
	    	 .mulWadDown(perp.inceptionPrice); 
	    if (vars.seniorSupply == 0) return (_self.psu, _self.psu, levFactor); 	    	

		if(_self.constantRF){
			psu = perp.inceptionPrice.mulWadDown((BASE_UNIT+ perp.promisedReturn)
    		 .rpow(block.timestamp - perp.inceptionTime, BASE_UNIT));
		} else {
			psu = _self.psu; 
		}

		// Check if all seniors can redeem
	    if (vars.totalAssetsHeldScaled < psu.mulWadDown(vars.seniorSupply)){
	    	psu = vars.totalAssetsHeldScaled.divWadDown(vars.seniorSupply); 
	    	vars.belowThreshold = true; 
	    }
	    // should be 0 otherwise 

	    if(!vars.belowThreshold) pju = 
	    	(vars.totalAssetsHeldScaled 
	      	- psu.mulWadDown(vars.seniorSupply)).divWadDown(juniorSupply); 

	     // console.log('alternative', (levFactor + BASE_UNIT).mulWadDown(Instrument(instrument).assetOracle(BASE_UNIT).mulWadDown(perp.inceptionPrice), 
	     // 	levFactor.mulWadDown(psu));
	    // console.log('alternative pju', 
	    // 	(
	    // 		(levFactor + BASE_UNIT).mulWadDown(Instrument(instrument).assetOracle(BASE_UNIT).mulWadDown(perp.inceptionPrice)
	    // 			) 
	    // 	- levFactor.mulWadDown(psu)
	    // 	), pju
	    // 	); 

	}

    
    function roundDown(uint256 rate) public view returns (uint256) {
        return ((rate / Constants.PRICING_ROUND) * Constants.PRICING_ROUND);
    }

    function roundUp(uint256 rate) public view returns (uint256) {
        return (((rate + Constants.PRICING_ROUND - 1) / Constants.PRICING_ROUND) * Constants.PRICING_ROUND);
    }

	struct localVars{

	    uint256 totalAssetsHeldScaled; 
	    uint256 juniorSupply;
	    uint256 seniorSupply; 

	    bool belowThreshold; 
	}

}

