

// library TradeLib{
//   function buyBond(

//     ) external returns(uint256 amountIn, uint256 amountOut){
    
//   }

//  event BondBuy(uint256 indexed marketId, address indexed trader, uint256 amountIn, uint256 amountOut);
//   /// @notice main entry point for longZCB buys 
//   /// @param _amountIn is negative if specified in zcb quantity
//   function buyBond(
//     uint256 _marketId, 
//     int256 _amountIn, 
//     uint256 _priceLimit, 
//     bytes calldata _tradeRequestData 
//     ) external _lock_ returns(uint256 amountIn, uint256 amountOut){
//     require(!restriction_data[_marketId].resolved, "!resolved");
//     _canBuy(msg.sender, _amountIn, _marketId);
//     //TODO return readable error on why it reverts
//     CoreMarketData memory marketData = markets[_marketId]; 
//     SyntheticZCBPool bondPool = marketData.bondPool; 
    

//     // During assessment, real bonds are issued from utilizer, they are the sole LP 
//     if (restriction_data[_marketId].duringAssessment){
//       // TODO fix pricelimit  

//       (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender)); 

//       // uint256 upperBound = bondPool.upperBound(); 
//       if( bondPool.upperBound() !=0 &&  bondPool.upperBound() < bondPool.getCurPrice()) revert("Exceeds Price Bound"); 

//       //Need to log assessment trades for updating reputation scores or returning collateral when market denied 
//       _logTrades(_marketId, msg.sender, amountIn, 0, true, true);

//       // Get implied probability estimates by summing up all this manager bought for this market 
//       reputationManager.recordPull(msg.sender, _marketId, amountOut,
//         amountIn, getTraderBudget(_marketId, msg.sender), marketData.isPool); 

//       // assessment_probs[_marketId][msg.sender] = controller.calcImpliedProbability(
//       //     getZCB(_marketId).balanceOf(msg.sender) + leveragePosition[_marketId][msg.sender].amount, 
//       //     longTrades[_marketId][msg.sender], 
//       //     getTraderBudget(_marketId, msg.sender) 
//       // ); 

//       // Phase Transitions when conditions met
//       if(restriction_data[_marketId].onlyReputable){
//         uint256 total_bought = loggedCollaterals[_marketId];

//         if (total_bought >= parameters[_marketId].omega.mulWadDown(
//               controller
//               .getVault(_marketId)
//               .fetchInstrumentData(_marketId)
//               .principal)
//         ) {
//           restriction_data[_marketId].onlyReputable = false;
//           emit MarketPhaseSet(_marketId, restriction_data[_marketId]);
//         }
//       }
//     }

//     // Synthetic bonds are issued (liquidity provision are amortized as counterparties)
//     else{
//       (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender));

//       // TODO check if valid slippage 
//       // TODO check liquidity, revert if not
//       // TODO reputation while trading post assessment? 
//       // (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
//       // if(isTaker)

//       //   (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender));
//       // else{
//       //   (uint256 escrowAmount, uint128 crossId) = bondPool.makerOpen(point, uint256(_amountIn), true, msg.sender); 
//       // }
//     }

//     uint amountIn_ = _amountIn> 0? uint256(_amountIn) : uint256(-_amountIn); 
//     if(_amountIn> 0)require(amountIn_ == amountIn , "AMM not enough Liq") ; 
//     else require(amountIn_==amountOut, "AMM not enough Liq"); 

//     emit BondBuy(_marketId, msg.sender, amountIn, amountOut); // get current price as well.
// }