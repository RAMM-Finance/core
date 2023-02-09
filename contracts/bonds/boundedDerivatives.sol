// pragma solidity ^0.8.9;
// import "./GBC.sol"; 
// // import {BoundedDerivativesPool, LinearCurve} from "./GBC.sol"; 
// import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
// import {ERC20} from "./libraries.sol"; 
// import "forge-std/console.sol";

// /// @notice Uses AMM as a derivatives market,where the price is bounded between two price
// /// and mints/burns tradeTokens. 
// /// stores all baseTokens for trading, and also stores tradetokens when providing liquidity, 
// /// @dev Short loss is bounded as the price is bounded, no need to program liquidations logic 
// contract BoundedDerivativesPool is GranularBondingCurve{
//     using FixedPointMath for uint256;
//     using SafeCast for uint256; 
//     // using Position for Position.Info;
//     // uint256 constant PRECISION = 1e18; 
//     ERC20 public  BaseToken; 
//     ERC20 public  TradeToken; 
//     ERC20 public  s_tradeToken; 
//     uint256 public constant maxPrice = 1e18; 

//     bool immutable noCallBack; 
//     constructor(
//         address base, 
//         address trade, 
//         address s_trade, 
//         bool _noCallBack
//         // address _pool 
//         ) GranularBondingCurve(base, trade){
//         BaseToken =  ERC20(base);
//         TradeToken = ERC20(trade);
//         s_tradeToken = ERC20(s_trade);
//         noCallBack = _noCallBack; 
//     }

//     /// @notice recipient recieves amountOut in exchange for giving this contract amountIn (base)
//     function mintAndPull(address recipient, uint256 amountOut, uint256 amountIn, bool isLong) internal  {
        
//         // Mint and Pull 
//         if(isLong) TradeToken.mint(recipient, amountOut); 
//         else s_tradeToken.mint(recipient, amountOut); 
//         BaseToken.transferFrom(recipient,address(this), amountIn); 
//     }

//     function burnAndPush(address recipient, uint256 amountOut, uint256 amountIn, bool isLong) internal  {
//         // Burn and Push 
//         if(isLong) TradeToken.burn(recipient, amountIn); 
//         else s_tradeToken.burn(recipient, amountIn); 
   
//         BaseToken.transfer(recipient, amountOut); 
//     }

//     function baseBal() public view returns(uint256){
//         return BaseToken.balanceOf(address(this)); 
//     }

//     /// @notice Long up the curve, or short down the curve 
//     /// @param amountIn is base if long, trade if short
//     /// @param priceLimit is slippage tolerance
//     function takerOpen(
//         bool isLong, 
//         int256 amountIn,
//         uint256 priceLimit, 
//         bytes calldata data
//         ) external  returns(uint256 poolamountIn, uint256 poolamountOut ){
//         if(isLong){
//             // Buy up 
//             (poolamountIn, poolamountOut) = trade(
//                 msg.sender, 
//                 true, 
//                 amountIn, 
//                 priceLimit, 
//                 data
//             ); 
//             if (noCallBack) mintAndPull(msg.sender, poolamountOut, poolamountIn, true);

//             else {
//                 uint256 bal = baseBal(); 
//                 iTradeCallBack(msg.sender).tradeCallBack(poolamountIn, data); 
//                 require(baseBal() >= poolamountIn + bal, "balERR"); 
//                 TradeToken.mint(abi.decode(data, (address)), poolamountOut); 
//             }
//         }

//         else{
//             // just shift pool state
//             (poolamountIn, poolamountOut) = trade(
//                 address(this), 
//                 false, 
//                 amountIn, 
//                 priceLimit, 
//                 data
//             ); 
//             uint b = baseBal(); 
//             console.log('basebal',b , poolamountOut); 
//             require(poolamountOut <= baseBal(), "!ammLiq"); 
//             uint256 cached_poolamountOut = poolamountOut; 
//             // poolamountIn is the number of short tokens minted, poolamountIn * maxprice - poolamountOut is the collateral escrowed
//             poolamountOut = poolamountIn.mulWadDown(maxPrice) - poolamountOut;

//             // One s_tradeToken is a representation of debt+sell of one tradetoken
//             // Escrow collateral required for shorting, where price for long + short = maxPrice, 
//             // so (maxPrice-price of trade) * quantity
//             if (noCallBack) mintAndPull(msg.sender, poolamountIn, poolamountOut, false);

//             else{
//                 uint256 bal = baseBal(); 
//                 iTradeCallBack(msg.sender).tradeCallBack(poolamountOut, data); 
//                 require(baseBal() >= poolamountOut + bal, "balERR"); 
//                 s_tradeToken.mint(abi.decode(data,(address)), poolamountIn); 

//                 // need to send cached poolamountOut(the area under the curve) data for accounting purposes
//                 poolamountIn = cached_poolamountOut; 
//             }

//             // BaseToken.transferFrom(msg.sender, address(this), poolamountIn.mulWadDown(maxPrice) - poolamountOut); 
//             // s_tradeToken.mint(msg.sender, uint256(amountIn)); 
//         }

//     }

//     /// @param amountIn is trade if long, ALSO trade if short, since getting rid of s_trade 
//     function takerClose(
//         bool isLong, 
//         int256 amountIn,
//         uint256 priceLimit, 
//         bytes calldata data
//         ) external returns(uint256 poolamountIn, uint256 poolamountOut){

//         // Sell down
//         if(isLong){
//             (poolamountIn, poolamountOut) = trade(
//                 msg.sender,
//                 false, 
//                 amountIn, //this should be trade tokens
//                 priceLimit, 
//                 data
//             ); 

//             if (noCallBack) burnAndPush(msg.sender, poolamountOut, poolamountIn, true);

//             else burnAndPush(abi.decode(data, (address)), poolamountOut, poolamountIn, true );                             
//         }

//         else{            
//             // buy up with the baseToken that was transferred to this contract when opened, in is base out is trade
//             (poolamountIn, poolamountOut) = trade(
//                 msg.sender, 
//                 true, 
//                 amountIn, 
//                 priceLimit, 
//                 data
//             ); 
//             uint256 cached_poolamountIn = poolamountIn; 

//             // collateral used to buy short 
//             poolamountIn = poolamountOut.mulWadDown(maxPrice) - poolamountIn; 

//             if (noCallBack) burnAndPush(msg.sender, poolamountIn,poolamountOut, false);
//             else {
//                 burnAndPush(abi.decode(data, (address)), poolamountIn, poolamountOut,false ); 
//                 poolamountOut = cached_poolamountIn; 
//             }

//             // s_tradeToken.burn(msg.sender, poolamountOut); 
//             // BaseToken.transfer(msg.sender, poolamountOut.mulWadDown(maxPrice) - poolamountIn);
//         }
//     }

//     /// @notice provides oneTimeliquidity in the range (point,point+1)
//     /// @param amount is in base if long, trade if in short  
//     function makerOpen(
//         uint16 point, 
//         uint256 amount,
//         bool isLong,
//         address recipient
//         )external  returns(uint256 toEscrowAmount, uint128 crossId){

//         if(isLong){
//             // escrowAmount is base 
//             (toEscrowAmount, crossId) = placeLimitOrder(
//                 recipient,
//                 point, 
//                 uint128(liquidityGivenBase(pointToPrice(point+1), pointToPrice(point), amount)), 
//                 false
//                 ); 
//             BaseToken.transferFrom(recipient, address(this), toEscrowAmount); 
//         }

//         // need to set limit for sells, but claiming process is different then regular sells 
//         else{
//             // escrowAmount is trade 
//             (toEscrowAmount, crossId) = placeLimitOrder(
//                 recipient, 
//                 point,
//                 uint128(liquidityGivenTrade(pointToPrice(point+1), pointToPrice(point),amount)) , 
//                 true
//                 ); 

//             // escrow amount is (maxPrice - avgPrice) * quantity 
//             uint256 escrowCollateral = toEscrowAmount - baseGivenLiquidity(
//                     pointToPrice(point+1), 
//                     pointToPrice(point), 
//                     uint256(amount) //positive since adding asks, not subtracting 
//                     ); 
//             BaseToken.transferFrom(recipient, address(this), escrowCollateral); 
//             toEscrowAmount = escrowCollateral; 
//         }

//     }

//     function makerClaimOpen(
//         uint16 point, 
//         bool isLong, 
//         address recipient
//         )external returns(uint256 claimedAmount){

//         if(isLong){
//             uint256 claimedAmount = claimFilledOrder(recipient, point, false ); 

//             // user already escrowed funds, so need to send him tradeTokens 
//             TradeToken.mint(recipient, claimedAmount);          
//         }

//         else{           
//             s_tradeToken.mint(recipient, 
//                 tradeGivenLiquidity(
//                     pointToPrice(point+1), 
//                     pointToPrice(point), 
//                     getLiq(msg.sender, point, true)
//                     )
//                 ); 

//             // open short is filled sells, check if sells are filled. If it is,
//             // claimedAmount of basetokens should already be in this contract 
//             claimedAmount = claimFilledOrder(recipient, point, true ); 
//         }

//     }
//     /// @notice amount is trade if long, but ALSO trade if short(since trade quantity also coincides
//     /// with shortTrade quantity )
//     function makerClose(
//         uint16 point, 
//         uint256 amount,
//         bool isLong, 
//         address recipient
//         )external returns(uint256 toEscrowAmount, uint128 crossId){

//         if(isLong){
//             // close long is putting up trades for sells, 
//             (toEscrowAmount, crossId) = placeLimitOrder(
//                 recipient, 
//                 point, 
//                 uint128(liquidityGivenTrade(pointToPrice(point+1), pointToPrice(point),amount)), 
//                 true
//                 ); 
//             //maybe burn it when claiming, and just escrow? 
//             TradeToken.burn(recipient, toEscrowAmount); 
//         }

//         else{
//             // Place limit orders for buys 
//             (toEscrowAmount, crossId) = placeLimitOrder(
//                 recipient, 
//                 point,
//                 uint128(liquidityGivenTrade(pointToPrice(point+1), pointToPrice(point),amount)), 
//                 false
//                 ); 

//             // burn s_tradeTokens, 
//             s_tradeToken.burn(recipient, amount); 

//         }
//     }

//     function makerClaimClose(
//         uint16 point, 
//         bool isLong, 
//         address recipient
//         ) external returns(uint256 claimedAmount){

//         if(isLong){
//             // Sell is filled, so need to transfer back base 
//             claimedAmount = claimFilledOrder(recipient, point, true ); 
//             BaseToken.transfer(recipient, claimedAmount); 
//         }
//         else{
//             uint128 liq = getLiq(recipient, point, false); 

//             // Buy is filled, which means somebody burnt trade, so claimedAmount is in trade
//             claimedAmount = claimFilledOrder(recipient, point, false);
//             claimedAmount = claimedAmount.mulWadDown(maxPrice) 
//                             - baseGivenLiquidity(
//                             pointToPrice(point+1), 
//                             pointToPrice(point), 
//                             liq); 
//             BaseToken.transfer(recipient, claimedAmount);
//         }
//     }    

//     function makerPartiallyClaim(
//         uint16 point, 
//         bool isLong,
//         bool open, 
//         address recipient
//         ) external returns(uint256 baseAmount, uint256 tradeAmount){
   
//         if(open){
//             if(isLong)(baseAmount, tradeAmount) = claimPartiallyFilledOrder(recipient, point, false); 
//             else (baseAmount, tradeAmount) = claimPartiallyFilledOrder(recipient, point, true);
//         }
//         else{
//             if(isLong)(baseAmount, tradeAmount) = claimPartiallyFilledOrder(recipient, point, true); 
//             else (baseAmount, tradeAmount) = claimPartiallyFilledOrder(recipient, point, false);
//         }
        
//         BaseToken.transfer(recipient, baseAmount);
//         TradeToken.mint(recipient, tradeAmount); 
//     }

//     /// @notice amount is in base if long, trade if short 
//     function makerReduceOpen(
//         uint16 point, 
//         uint256 amount, 
//         bool isLong, 
//         address recipient
//         ) external{
    
//         if(isLong){
//             uint256 returned_amount =reduceLimitOrder(
//                 recipient, 
//                 point, 
//                 liquidityGivenBase(
//                     pointToPrice(point+1), 
//                     pointToPrice(point),
//                     amount
//                     ).toUint128(), 
//                 false
//                 ); 
//             // need to send base back 
//             BaseToken.transfer(recipient, returned_amount); 
//         }
//         else {
//             uint128 liq = liquidityGivenTrade(pointToPrice(point+1), pointToPrice(point), amount).toUint128(); 
//             // Reduce asks 
//             reduceLimitOrder(
//                 recipient, 
//                 point, 
//                 liq, 
//                 true
//                 ); 

//             // Need to send escrowed basetoken back, which is shortTrade quantity - baseGivenLiquidity 
//             BaseToken.transfer(recipient, 
//                 amount - baseGivenLiquidity(pointToPrice(point+1), pointToPrice(point), liq));
//         }
//     }

//     /// @notice amount is in trade if long, ALSO trade if short 
//     function makerReduceClose(      
//         uint16 point, 
//         uint256 amount, 
//         bool isLong,
//         address recipient
//         ) external{

//         if(isLong){
//             uint256 returned_amount = reduceLimitOrder(
//                 recipient, 
//                 point, 
//                 liquidityGivenTrade(
//                     uint256(pointToPrice(point+1)), 
//                     uint256(pointToPrice(point)), amount).toUint128(), 
//                 true
//                 ); 
//             // need to send trade back 
//             TradeToken.mint(recipient, returned_amount); 
//         }

//         else{
//             // reduce limit bids 
//             reduceLimitOrder(
//                 recipient, 
//                 point, 
//                 liquidityGivenTrade(
//                     uint256(pointToPrice(point+1)), 
//                     uint256(pointToPrice(point)), amount).toUint128(), 
//                 false
//             ); 
             
//             s_tradeToken.mint(recipient, amount); 
//         }
//     }

//     // TODO separate contracts 
//     // function provideLiquidity(
//     //     uint16 pointLower,
//     //     uint16 pointUpper,
//     //     uint128 amount, 
//     //     bytes calldata data 
//     //     ) external {

//     //     (uint256 amount0, uint256 amount1) = provide(
//     //         msg.sender, 
//     //         pointLower, 
//     //         pointUpper, 
//     //         amount, 
//     //         data 
//     //     ); 
//     //     BaseToken.transferFrom(msg.sender, address(this), amount0); 
//     //     // TradeToken.transferFrom(msg.sender, address(this), amount1);
//     //     TradeToken.burn(msg.sender, amount1);
//     // }

//     // function withdrawLiquidity(
//     //     uint16 pointLower,
//     //     uint16 pointUpper,
//     //     uint128 amount, 
//     //     bytes calldata data 
//     //     )external{

//     //     (uint256 amountBase, uint256 amountTrade) = remove(
//     //         msg.sender, 
//     //         pointLower, 
//     //         pointUpper, 
//     //         amount
//     //     ); 
      
//     //     collect(
//     //         msg.sender, 
//     //         pointLower,
//     //         pointUpper,
//     //         type(uint128).max,
//     //         type(uint128).max
//     //     ); 

//     //     BaseToken.transfer(msg.sender,  amountBase); 
//     //     TradeToken.mint(msg.sender, amountTrade); 
//     // }

//     //TODO fees, skipping uninit for gas, below functions
//     // possible attacks: manipulation of price with no liquidityregions, add a bid/ask and a naive 
//     // trader fills, and immediately submit a ask much higher/lower
//     // gas scales with number of loops, so need to set ticks apart large, or provide minimal liquidity in each tick

// }

// interface iTradeCallBack{
//     function tradeCallBack(
//         uint256 amount0,
//  bytes calldata data    ) external;
// } 
