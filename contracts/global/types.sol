pragma solidity ^0.8.16;

struct PricingInfo{
	uint256 psu; 

	uint256 prevAccrueTime; 
	uint256 prevIntervalRp; //per second compounding promised return, function of urate 

	// Constants for a given market 
	uint256 URATE_MULTIPLIER; 
	uint256 ID; 

	bool constantRF; 
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