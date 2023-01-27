pragma solidity ^0.8.16;
import "./types.sol"; 
import {PerpTranchePricer} from "../libraries/pricerLib.sol"; 


contract StorageHandler{
	using PerpTranchePricer for PricingInfo; 

	mapping(uint256=> PricingInfo) public PricingInfos; 

    modifier onlyProtocol() {
        
        _;
    }

	function getPricingInfo(uint256 marketId) public view returns(PricingInfo memory){
		return PricingInfos[marketId]; 
	}
	function setNewPricingInfo(uint256 marketId, uint256 initialPrice, uint256 multiplier, 
		bool constantRF) external onlyProtocol{
		PricingInfos[marketId].setNewPrices(initialPrice, multiplier, marketId, constantRF); 
	}

	function updatePricingInfo(uint256 marketId, PricingInfo memory newInfo) external onlyProtocol{
		PricingInfos[marketId] = newInfo; 
	}

	function refreshPricing(uint256 marketId, uint256 uRate) public onlyProtocol{
		PricingInfos[marketId].storeNewPSU(
 		 uRate
 		); 

	}


}




// library GlobalStorage{

//    /// @dev Offset for the initial slot in lib storage, gives us this number of storage slots
//     /// available in StorageLayoutV1 and all subsequent storage layouts that inherit from it.
//     uint256 private constant STORAGE_SLOT_BASE = 1000000;


//     /// @dev Storage IDs for storage buckets. Each id maps to an internal storage
//     /// slot used for a particular mapping
//     ///     WARNING: APPEND ONLY
//     enum StorageId {
//            Unused,

//         _PricingInfo 
//     }


// 	function PricingInfos() public returns(mapping(uint256=> PricingInfo) storage store) {
//         uint256 slot = _getStorageSlot(StorageId._PricingInfo);
//         assembly { store.slot := slot }
//     }


//     /// @dev Get the storage slot given a storage ID.
//     /// @param storageId An entry in `StorageId`
//     /// @return slot The storage slot.
//     function _getStorageSlot(StorageId storageId)
//         private
//         pure
//         returns (uint256 slot)
//     {
//         // This should never overflow with a reasonable `STORAGE_SLOT_EXP`
//         // because Solidity will do a range check on `storageId` during the cast.
//         return uint256(storageId) + STORAGE_SLOT_BASE;
//     }

// }