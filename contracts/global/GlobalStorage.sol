pragma solidity ^0.8.16;
import "./types.sol"; 
import {PerpTranchePricer} from "../libraries/pricerLib.sol"; 
import {CollateralPricer} from "../libraries/lendingOracleLib.sol"; 

import {Instrument} from "../vaults/instrument.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "forge-std/console.sol";

contract StorageHandler{
	using PerpTranchePricer for PricingInfo;
	using CollateralPricer for PoolPricingParam; 
    using FixedPointMathLib for uint256;

	uint256 constant BASE_UNIT = 1e18; 

    modifier onlyProtocol() {
        
        _;
    }

  	constructor() 
  		{
    // controller = Controller(_controllerAddress);
    // push empty market
    	markets.push(makeEmptyMarketData());

    // owner = msg.sender; 
  	}


	/// @notice called at market creation 
	function setNewInstrument(
		uint256 marketId, 
		uint256 initialPrice, 
		uint256 multiplier, 
		bool constantRF, 
		InstrumentData memory idata, 
		CoreMarketData memory mdata) external onlyProtocol {
		PricingInfos[marketId].setNewPrices(initialPrice, multiplier, marketId, constantRF); 

		storeNewProposal(marketId, idata); 
	}


    //--- Perp Pricing ---// 
	mapping(uint256=> PricingInfo) public PricingInfos; 

	function getPricingInfo(uint256 marketId) public view returns(PricingInfo memory){
		return PricingInfos[marketId]; 
	}

	function updatePricingInfo(uint256 marketId, PricingInfo memory newInfo) external onlyProtocol{
		PricingInfos[marketId] = newInfo; 
	}

	function setRF(uint256 marketId, bool isConstant) external onlyProtocol {
		PricingInfos[marketId].setRF(isConstant); 
	}

	/// @notice updates whenever uRate changes 
	function refreshPricing(uint256 marketId, uint256 uRate) public onlyProtocol{
		PricingInfos[marketId].storeNewPSU(uRate); 
	}

	function viewCurrentPricing(uint256 marketId) public view returns(uint256, uint256, uint256) {
		InstrumentData memory data = InstrumentDatas[marketId]; 
		return (PricingInfos[marketId].viewCurrentPricing(
			data.instrument_address, 
			data.poolData, 
			markets[marketId].longZCB.totalSupply()
		));  
	}

	function checkIsSolventConstantRF(uint256 marketId) public view returns(bool){
		InstrumentData memory data = InstrumentDatas[marketId]; 
		uint256 psu = PerpTranchePricer.constantRF_PSU(
			data.poolData.inceptionPrice, 
			data.poolData.promisedReturn, 
			data.poolData.inceptionTime); 
		return PerpTranchePricer.isSolvent(data.instrument_address, psu, markets[marketId].longZCB.totalSupply(), 
			data.poolData); 
	}


	//--- Instrument ---//
	uint256 public lastTradedRate; 
	uint256 public lastTradedTime; 
	uint256 public constant TIME_WINDOW = 10e18; // for rate oracle 
	mapping(uint256=> PoolPricingParam) PoolPricingParams; 

	mapping(uint256=> ExchangeRateData) storedRates; //marketId-> last exchange rate

	mapping(uint256=> InstrumentData) public InstrumentDatas; 

	function getInstrumentData(uint256 marketId) public view returns(InstrumentData memory){
		return InstrumentDatas[marketId]; 
	}

	function getInstrumentAddress(uint256 marketId) public view returns(address){
		return InstrumentDatas[marketId].instrument_address; 
	}

	function storeNewProposal(uint256 marketId, InstrumentData memory data) public onlyProtocol{
		InstrumentDatas[marketId] = data; 
	}

	/// @notice store instrument exchange rate to get delayed rates 
	/// called whenever instrument exchange rate changes
	function storeExchangeRateOracle(uint256 marketId, uint256 newRate) public onlyProtocol returns(uint256){
		ExchangeRateData storage rateData = storedRates[marketId];

		rateData.lastOracleRate = rateData.initialized? queryExchangeRateOracle(marketId) : newRate; 
		rateData.lastRate = newRate; 
		rateData.lastTime = block.timestamp; 
		rateData.initialized = true; 

		return rateData.lastOracleRate; 
	}

	function queryExchangeRateOracle(uint256 marketId) public view returns(uint256){
		ExchangeRateData memory rateData = storedRates[marketId];
		uint256 timeDiff = (block.timestamp -rateData.lastTime) * BASE_UNIT; 
		uint256 timeDivWindow = timeDiff.divWadDown(TIME_WINDOW); 

		// Liear interpolation of last rate and last oracle rate
		rateData.lastOracleRate = TIME_WINDOW >= timeDiff
			? rateData.lastRate.mulWadDown(min(timeDivWindow, BASE_UNIT)) 
				+ rateData.lastOracleRate.mulWadDown((TIME_WINDOW - timeDiff).divWadDown(TIME_WINDOW))
			: rateData.lastRate;

		return rateData.lastOracleRate; 
	}

	function setPoolPricingParams(uint256 marketId, PoolPricingParam memory params) public onlyProtocol{
		PoolPricingParams[marketId] = params; 
	}

	/// @notice applicable to lending pool instruments only. Needs to be called
	/// whenever utilization rate is about to get updates. i.e while borrowing/
	function refreshAndGetNewLTV(uint256 marketId, uint256 newURate) public onlyProtocol returns(uint256){
		return PoolPricingParams[marketId].storeNewLTV(newURate); 
	}






	//--- Market ---//
  	CoreMarketData[] public markets;

	function storeNewMarket(CoreMarketData memory data) public onlyProtocol  returns(uint256 marketId){
		// MarketDatas[marketId] = data; 
		marketId = markets.length; 
		markets.push(data); 
		// uint256 base_budget = 1000 * BASE_UNIT; //TODO 
		// setMarketPhase(marketId, true, true, base_budget);
	}

	function getMarket(uint256 marketId) public view returns(CoreMarketData memory data){
		return markets[marketId]; 
	}

	function getMarketLength() public view returns(uint256){
		return markets.length; 
	}

	function makeEmptyMarketData() internal pure returns (CoreMarketData memory) {
		return CoreMarketData(
		    SyntheticZCBPool(address(0)),
		    ERC20(address(0)),
		    ERC20(address(0)),
		    "",
		    0,
		    0, 
		    false
		);
	}    

	function zcbMaxPrice(uint256 marketId) public view returns(uint256){
		return 1e18; 
	} 




    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }



}


