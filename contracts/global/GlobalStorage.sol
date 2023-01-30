pragma solidity ^0.8.16;
import "./types.sol"; 
import {PerpTranchePricer} from "../libraries/pricerLib.sol"; 


contract StorageHandler{
	using PerpTranchePricer for PricingInfo; 

	uint256 constant BASE_UNIT = 1e18; 

	mapping(uint256=> PricingInfo) public PricingInfos; 
	mapping(uint256=> InstrumentData) public InstrumentDatas; 
	mapping(uint256=>CoreMarketData) public MarketDatas; 
  	CoreMarketData[] public markets;


    modifier onlyProtocol() {
        
        _;
    }


	/// @notice called at market creation 
	function setNewInstrument(
		uint256 marketId, 
		uint256 initialPrice, 
		uint256 multiplier, 
		bool constantRF, 
		InstrumentData memory idata, 
		CoreMarketData memory mdata) external onlyProtocol{
		PricingInfos[marketId].setNewPrices(initialPrice, multiplier, marketId, constantRF); 

		storeNewProposal(marketId, idata); 
		storeNewMarket(marketId, mdata); 
	}


    //--- Pricing ---// 

	function getPricingInfo(uint256 marketId) public view returns(PricingInfo memory){
		return PricingInfos[marketId]; 
	}

	function updatePricingInfo(uint256 marketId, PricingInfo memory newInfo) external onlyProtocol{
		PricingInfos[marketId] = newInfo; 
	}

	function refreshPricing(uint256 marketId, uint256 uRate) public onlyProtocol{
		PricingInfos[marketId].storeNewPSU(uRate); 
	}

	function viewCurrentPricing(uint256 marketId) public view returns(uint256, uint256, uint256) {
		PricingInfos[marketId].viewCurrentPricing(
			InstrumentDatas[marketId].poolData, 
			markets[marketId].longZCB.totalSupply()
			 ); 
	}




	//--- Instrument ---//

	function storeNewProposal(uint256 marketId, InstrumentData memory data) public onlyProtocol{
		InstrumentDatas[marketId] = data; 
	}


	//--- Market ---//
	function storeNewMarket(uint256 marketId, CoreMarketData memory data) public onlyProtocol{
		MarketDatas[marketId] = data; 
		// uint256 base_budget = 1000 * BASE_UNIT; //TODO 

		// setMarketPhase(marketId, true, true, base_budget);

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