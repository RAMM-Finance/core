pragma solidity ^0.8.16;
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Controller} from "../protocol/controller.sol"; 
import {Vault} from "../vaults/vault.sol"; 

library PerpTranchePricer{
    using FixedPointMathLib for uint256;
    using PerpTranchePricer for PerpTranchePricer.PricingInfo; 
    uint256 constant BASE_UNIT = 1e18; 

	struct PricingInfo{
		uint256 psu; 

		uint256 prevAccrueTime; 
		uint256 prevIntervalRp; //per second compounding promised return, function of urate 

		// Constants for a given market 
		uint256 URATE_MULTIPLIER; 
		uint256 ID; 
	}

	function setNewPrices(
		PerpTranchePricer.PricingInfo storage _self, 
		uint256 psu,
		uint256 pju, 
		uint256 multiplier, 
		uint256 id
		) internal {
		_self.psu = psu; 
		_self.URATE_MULTIPLIER = multiplier;  
		_self.ID = id; 
	}

	/// @notice needs to be updated whenver utilization rate is updated 
 	function storeNewPSU(
 		PerpTranchePricer.PricingInfo storage _self, 
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
		return uRate.mulWadDown(multiplier); 
	}

	function refreshViewCurrentPricing(
		PerpTranchePricer.PricingInfo storage _self, 
		uint256 uRate, 
		address vault_ad, address controller_ad
		) public returns(uint256 psu, uint256 pju, uint256 levFactor){
		_self.storeNewPSU(uRate); 
		return viewCurrentPricing(_self, vault_ad, controller_ad ); 
	}

	function viewCurrentPricing(
		PerpTranchePricer.PricingInfo storage _self,
		address vault_ad, 
		address controller_ad
		) public view returns(uint256 psu, uint256 pju, uint256 levFactor){
	    //TODO should not tick during assessment 
	    localVars memory vars; 
	    uint256 marketId = _self.ID; 
		Vault vault = Vault(vault_ad); 
		Controller controller = Controller(controller_ad); 

	    (vars.promised_return, vars.inceptionTime, vars.inceptionPrice, vars.leverageFactor, 
	      vars.managementFee) = vault.fetchPoolTrancheData(marketId); 

	    require(vars.inceptionPrice > 0, "0"); 

	    vars.juniorSupply = controller.getTotalSupply(marketId); 
	    vars.seniorSupply = vars.juniorSupply.mulWadDown(vars.leverageFactor); 
	    vars.totalAssetsHeldScaled = vault.instrumentAssetOracle(marketId, vars.juniorSupply, vars.seniorSupply)
	      .mulWadDown(vars.inceptionPrice); 

	    if (vars.seniorSupply == 0) return(psu, psu,levFactor); 

		// Check if all seniors can redeem
		psu = _self.psu; 
	    if (vars.totalAssetsHeldScaled < psu.mulWadDown(vars.seniorSupply)){
	    	psu = vars.totalAssetsHeldScaled.divWadDown(vars.seniorSupply); 
	    	vars.belowThreshold = true; 
	    }

	    // should be 0 otherwise 
	    if(!vars.belowThreshold) pju = (vars.totalAssetsHeldScaled 
	      - psu.mulWadDown(vars.seniorSupply)).divWadDown(vars.juniorSupply); 
	}

	struct localVars{
	    uint256 promised_return; 
	    uint256 inceptionTime; 
	    uint256 inceptionPrice; 
	    uint256 leverageFactor; 
	    uint256 managementFee; 

	    uint256 totalAssetsHeldScaled; 
	    uint256 juniorSupply;
	    uint256 seniorSupply; 

	    bool belowThreshold; 
	}

}

