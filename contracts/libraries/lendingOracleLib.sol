pragma solidity ^0.8.16;
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Controller} from "../protocol/controller.sol"; 
import {Vault} from "../vaults/vault.sol"; 
import  "../global/types.sol"; 
import {Instrument} from "../vaults/instrument.sol"; 
import "forge-std/console.sol";
	
/// @notice use managers to price risk of colalterals 
library CollateralPricer{
	using FixedPointMathLib for uint256; 

	uint256 public constant BASE_UNIT = 1e18; 

	/// @notice needs to be updated whenver BEFORE utilization rate is updated 
	/// returns new LTV after utilization rate has been updated 
 	function storeNewLTV(
 		PoolPricingParam storage _self,  
 		uint256 uRate
 		) internal returns(uint256){

	    uint256 accruedMax; 

	    if(_self.prevURate> _self.urateUpper) 
	    	accruedMax = (BASE_UNIT - _self.incrementRate).rpow(block.timestamp - _self.prevAccrueTime, BASE_UNIT); 
	    else if(_self.prevURate < _self.urateLower)
	    	accruedMax = (BASE_UNIT + _self.incrementRate).rpow(block.timestamp - _self.prevAccrueTime, BASE_UNIT); 
	    else accruedMax = BASE_UNIT; 

	    _self.maxBorrowable = _self.maxBorrowable.mulWadDown(accruedMax); 
	    _self.prevAccrueTime = block.timestamp; 
	    _self.prevURate = uRate; 

	    return _self.maxBorrowable; 
	}





}