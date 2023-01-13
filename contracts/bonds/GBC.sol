// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;
// Uncomment this line to use console.log
// import "hardhat/console.sol";
// import {ERC20} from "./aave/Libraries.sol"; 
import {SafeCast, FixedPointMath, ERC20} from "./libraries.sol"; 
import "forge-std/console.sol";

/// @notice AMM for a token pair (trade, base), only tracks price denominated in trade/base  
/// and point-bound(limit order) and range-bound(multiple points, also known as concentrated) liquidity 
/// @dev all funds will be handled in the child contract 
contract GranularBondingCurve{
    using FixedPointMath for uint256;
    using Tick for mapping(uint16 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using SafeCast for uint256; 


    modifier onlyEntry(){
        require(entry == msg.sender  ,"Not Entry"); 
        _;
    }
    
    bool private _mutex;
    modifier _lock_() {
        require(!_mutex, "ERR_REENTRY");
        _mutex = true;
        _;
        _mutex = false;
    }

    constructor(
        address _baseToken,
        address _tradeToken
        //uint256 _priceDelta
        ) {
        tradeToken = _tradeToken; 
        baseToken = _baseToken; 
        //priceDelta = _priceDelta; 
        fee =0; 
        factory = address(0); 
        tickSpacing = 0; 
        //Start liquidity 
        liquidity = 100 * uint128(PRECISION); 

        owner = msg.sender; 
    }

    address public immutable owner; 
    uint24 public immutable  fee;
    Slot0 public slot0; // global state?
    address public immutable  factory;
    address public immutable  tradeToken;
    address public immutable  baseToken;
    int24 public immutable  tickSpacing; // only ticks/price points divisible by tickSpacing can be initialized.

    uint128 public liquidity;

    mapping(uint16 => Tick.Info) public  ticks;

    mapping(bytes32 => Position.Info) public  positions;

    // mapping(uint16=> PricePoint) Points; 

    uint256 public  constant priceDelta = 1e16; //difference in price for two adjacent ticks => 0.01 base token.
    uint256 public constant ROUNDLIMIT = 1e4; 
    uint256 public constant PRECISION = 1e18; 
    address public entry; 

    /// @notice previliged function called by the market maker 
    /// if he is the one providing all the liquidity 
    function setLiquidity(uint128 liq) internal  
    //onlyEntry
    {
        liquidity = liq; 
    }

    function setEntry(address _entry) external onlyEntry{
        entry = _entry; 
    }
    function lock() external onlyEntry{
        slot0.unlocked = !slot0.unlocked; 
    }

    function positionIsFilled(
        address recipient, 
        uint16 point, 
        bool isAsk
    ) 
        public view returns(bool){
        Position.Info storage position = positions.get(recipient, point, point+1);

        uint128 numCross = ticks.getNumCross(point, isAsk); 
        uint128 crossId = isAsk? position.askCrossId : position.bidCrossId; 
        uint128 liq = isAsk? position.askLiq : position.bidLiq;

        return (liq>0 && numCross > crossId); 
    }

    function setPriceAndPoint(uint256 price) internal  
    //onlyOwner
    {
        slot0.point = priceToPoint(price);         
        slot0.curPrice = price.toUint160(); 
    }

    function getCurPrice() external view returns(uint256){
        return slot0.curPrice; 
    }

    function getOneTimeLiquidity(uint16 point, bool moveUp) external view returns(uint256){
        return uint256(ticks.oneTimeLiquidity(point)); 
    }    

    function getNumCross(uint16 point, bool moveUp) external view returns(uint256){
        return ticks.getNumCross(point, moveUp); 
    }


    struct Slot0 {
        // the current price
        uint160 curPrice;
        // the current tick
        uint16 point;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;

        // Whether liquidity provision is amortized 
        bool amortized; 

        // Where to modify liquidity 
        uint16 modifyLiqPoint; 
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        uint256 amountCalculated;
        // current sqrt(price)
        uint256 curPrice;
        // the tick associated with the current price
        uint16 point;
        // the global fee growth of the input token
        uint256 feeGrowthGlobal;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
        uint128 liquidityStart; 


    }

    struct StepComputations {
        // the price at the beginning of the step
        uint256 priceStart;
        // the next tick to swap to from the current tick in the swap direction
        uint16 pointNext;
        // whether tickNext is initialized or not
        bool initialized;
        // price for the next tick (1/0)
        uint256 priceNextLimit;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;

        uint128 liqDir; 
    }

    struct swapVars{
        uint256 a;
        uint256 s; 
        uint256 b; 
    }

    /// param +amountSpecified is in base if moveUp, else is in trade (+ if input asset, - if output asset)
    /// -amountSpecified is in trade if moveUp, else is in base 
    /// returns amountIn if moveUp, cash, else token
    /// returns amountOut if moveUp, token, else cash 
    function trade(
        address recipient, 
        bool moveUp, 
        int256 amountSpecified, 
        uint256 priceLimit, 
        bytes calldata data
        ) public onlyEntry _lock_ returns(uint256 amountIn, uint256 amountOut){
        console.logString('---New Trade---'); 

        Slot0 memory slot0Start = slot0; 
        uint256 pDelta = priceDelta; 

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified, 
            amountCalculated: 0, 
            curPrice: uint256(slot0Start.curPrice),
            feeGrowthGlobal: moveUp? feeGrowthGlobalBase: feeGrowthGlobalTrade,//moveup is base in for trade out
            protocolFee: 0, 
            liquidity: liquidity, 
            liquidityStart: liquidity,
            point: slot0.point
            }); 
        swapVars memory vars = swapVars({
            a:0,
            b:0,
            s:0
            });

        bool exactInput = amountSpecified > 0;

        // increment price by 1/1e18 if at boundary, and go back up a point,
        // should be negligible compared to fees TODO 
        if (mod0(state.curPrice, pDelta) && !moveUp) {
            state.curPrice += 1; 
            state.point = priceToPoint(state.curPrice);
            slot0.point = state.point; 
            slot0Start.point = state.point; 
        }
        
        require(moveUp? priceLimit>= state.curPrice : priceLimit<= state.curPrice, "plimitERR" ); 
        priceLimit = pointToPrice(priceToPoint(priceLimit)); 

        while (state.amountSpecifiedRemaining !=0 && state.curPrice != priceLimit){
            StepComputations memory step; 
            step.priceStart = state.curPrice; 
            step.priceNextLimit = getNextPriceLimit(state.point, pDelta, moveUp); 

            step.pointNext = moveUp? state.point + 1 : state.point-1; 

            // Need liquidity for both move up and move down for path independence within a 
            // given point range. Either one of them should be 0 
            step.liqDir = ticks.oneTimeLiquidity(state.point);
            vars.a = exactInput 
                ? inv(state.liquidity + step.liqDir)
                : invRoundUp(state.liquidity + step.liqDir); 
            vars.b = yInt(state.curPrice, moveUp); 
            vars.s = xMax(state.curPrice, vars.b, vars.a); 
 
            //If moveup, amountIn is in cash, amountOut is token and vice versa 
            (state.curPrice, step.amountIn, step.amountOut, step.feeAmount) = LinearCurve.swapStep(
                state.curPrice, 
                step.priceNextLimit,    
                state.amountSpecifiedRemaining, 
                fee, 
                vars               
                ); 

            {console.log('________'); 
            console.log('CURPRICE', state.curPrice); 
            console.log('trading; liquidity, amountleft', state.liquidity); 
            console.log(uint256(state.amountSpecifiedRemaining));
            console.log('nextpricelimit/pointnext', step.priceNextLimit, step.pointNext);           
            console.log('a', vars.a); }
            console.log('amountinandout', step.amountIn, step.amountOut); 
            console.log('s,b', vars.s, vars.b); 

            if (exactInput){
                state.amountSpecifiedRemaining -= int256(step.amountIn); 
            }
            else{
                state.amountSpecifiedRemaining += int256(step.amountIn); 
            }
            state.amountCalculated += step.amountOut; 

            if (state.liquidity>0)
                state.feeGrowthGlobal += step.feeAmount.divWadDown(uint256(state.liquidity)); 

            // If next limit reached, cross price range and change slope(liquidity)
            if (state.curPrice == step.priceNextLimit){

                // If crossing UP, asks are all filled so need to set askLiquidity to 0 and increment numCross
                // Else if crossing DOWN, bids are all filled 
                if (step.liqDir!=0) ticks.deleteOneTimeLiquidity(state.point, moveUp); 

                int128 liquidityNet = ticks.cross(
                    step.pointNext, 
                    feeGrowthGlobalBase,
                    feeGrowthGlobalTrade
                    ); 

                if (!slot0Start.amortized && step.pointNext == slot0Start.modifyLiqPoint)
                    liquidityNet = liquidityNet += dynamicLiq[step.pointNext]; 
                    console.log('dynamicLiq', uint256(int256(dynamicLiq[step.pointNext])), uint256(int256(liquidityNet))); 

                if (!moveUp) liquidityNet = -liquidityNet; 


                state.liquidity = addDelta(state.liquidity,liquidityNet);
                state.point = step.pointNext;  
            }
        }

        slot0.curPrice = state.curPrice.toUint160(); 
        if(state.point != slot0Start.point) slot0.point = state.point; 
            
        if (state.liquidityStart != state.liquidity) liquidity = state.liquidity;

        if (moveUp) feeGrowthGlobalBase = state.feeGrowthGlobal; 
            
        // (amountIn, amountOut) = exactInput
        //                         ? moveUp ? (uint256(amountSpecified-state.amountSpecifiedRemaining ) + ROUNDLIMIT, state.amountCalculated)//TODO roundfixes
        //                                  : (uint256(amountSpecified-state.amountSpecifiedRemaining ), state.amountCalculated)
        //                         : (state.amountCalculated + ROUNDLIMIT, uint256(-amountSpecified+state.amountSpecifiedRemaining )); 

        (amountIn, amountOut) = exactInput
                                ? moveUp ? (uint256(amountSpecified-state.amountSpecifiedRemaining ) , state.amountCalculated)//TODO roundfixes
                                         : (uint256(amountSpecified-state.amountSpecifiedRemaining ), state.amountCalculated)
                                : (state.amountCalculated + ROUNDLIMIT, uint256(-amountSpecified+state.amountSpecifiedRemaining )); 
                    console.log('???', uint256(state.amountSpecifiedRemaining) , uint256(amountSpecified)); 

    }

    function placeLimitOrder(
        address recipient, 
        uint16 point, 
        uint128 amount,
        bool isAsk  
        ) public onlyEntry _lock_ returns(uint256 amountToEscrow, uint128 numCross ){   
        //TODO mint NFT 
        // Should only accept asks for price above the current point range
        if(isAsk && pointToPrice(point) <= slot0.curPrice) revert("ask below prie"); 
        else if(!isAsk && pointToPrice(point) >= slot0.curPrice) revert("bids above prie"); 

        Position.Info storage position = positions.get(recipient, point, point+1);

        numCross = ticks.getNumCross(point, isAsk); 
        position.updateLimit(int128(amount), isAsk, numCross); 

        ticks.updateOneTimeLiquidity( point, int128(amount), isAsk); 

        // If placing bids, need to escrow baseAsset, vice versa 
        address tokenToEscrow = isAsk? tradeToken : baseToken;

        amountToEscrow = isAsk
                ? tradeGivenLiquidity(
                    pointToPrice(point+1), 
                    pointToPrice(point), 
                    uint256(amount) 
                    )
            
                : baseGivenLiquidity(
                    pointToPrice(point+1), 
                    pointToPrice(point), 
                    uint256(amount) 
                    ); 

        console.log('amountbid', amountToEscrow); 

    }

    function reduceLimitOrder(
        address recipient, 
        uint16 point, 
        uint128 amount,
        bool isAsk 
        ) public onlyEntry _lock_  returns(uint256 amountToReturn) {
        require(priceToPoint(uint256(slot0.curPrice)) != point, "Can't reduce order for current tick"); 

        Position.Info storage position = positions.get(msg.sender, point, point+1);

        position.updateLimit(-int128(amount), isAsk, 0); 

        ticks.updateOneTimeLiquidity(point, -int128(amount), isAsk); 

        address tokenToReturn = isAsk? tradeToken : baseToken;
        
        amountToReturn = isAsk
            ? tradeGivenLiquidity(
                pointToPrice(point+1), 
                pointToPrice(point), 
                uint256(amount) 
                )
         
            : baseGivenLiquidity(
                pointToPrice(point+1), 
                pointToPrice(point), 
                uint256(amount) 
                );
    }

    /// @notice called when maker wants to claim when the the price is at the 
    /// point he submitted the order
    function claimPartiallyFilledOrder(
        address recipient, 
        uint16 point,
        bool isAsk
        ) public onlyEntry _lock_ returns(uint256 baseAmount, uint256 tradeAmount){
        Slot0 memory _slot0 = slot0; 

        Position.Info storage position = positions.get(recipient, point, point+1);
        require(priceToPoint(uint256(_slot0.curPrice)) == point, "Not cur price"); 

        // Assume trying to withdraw all liquidity provided 
        uint128 liqToWithdraw = isAsk ? position.askLiq : position.bidLiq; 
       
        position.updateLimit(-int128(liqToWithdraw), isAsk, 0); 

        ticks.updateOneTimeLiquidity(point, -int128(liqToWithdraw), isAsk); 

        // Get total trade filled OR remaining
        tradeAmount = tradeGivenLiquidity(
            pointToPrice(point+1),
            _slot0.curPrice, 
            liqToWithdraw
        ); 
           
        // Get total base filled OR remaining 
        baseAmount = baseGivenLiquidity(
            _slot0.curPrice, 
            pointToPrice(point), 
            liqToWithdraw
            ); 

    }

    /// @notice Need to check if the ask/bids were actually filled, which is equivalent to
    /// the condition that numCross > crossId, because numCross only increases when crossUp 
    /// or crossDown 
    function claimFilledOrder(
        address recipient, 
        uint16 point, 
        bool isAsk 
        ) public onlyEntry _lock_  returns(uint256 claimedAmount){
        Position.Info storage position = positions.get(recipient, point, point+1);

        uint128 numCross = ticks.getNumCross(point, isAsk); 
        uint128 crossId = isAsk? position.askCrossId : position.bidCrossId; 
        require(numCross > crossId, "Position not filled");

        uint128 liq = isAsk? position.askLiq : position.bidLiq;

        // Sold to base when asks are filled
        if(isAsk) claimedAmount = baseGivenLiquidity(
                pointToPrice(point+1), 
                pointToPrice(point), 
                uint256(liq) 
                ); 

        // Bought when bids are filled so want tradeTokens
        else claimedAmount = tradeGivenLiquidity(
                pointToPrice(point+1), 
                pointToPrice(point), 
                uint256(liq) 
                ); 

        position.updateLimit(-int128(liq), isAsk, 0); 
        
        // Need to burn AND 

    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        uint16 pointLower;
        uint16 pointUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    /// @notice provides liquidity in range or adds limit order if pointUpper = pointLower + 1
    function provide(
        address recipient, 
        uint16 pointLower, 
        uint16 pointUpper, 
        uint128 amount, 
        bytes calldata data 
        ) public onlyEntry _lock_ returns(uint256 amount0, uint256 amount1 ){
        require(amount > 0, "0 amount"); 

        (,  amount0,  amount1) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient, 
                pointLower : pointLower, 
                pointUpper: pointUpper, 
                liquidityDelta: int128(amount)//.toInt128()
                })
            ); 

        //mintCallback

    }

    function remove(
        address recipient, 
        uint16 pointLower, 
        uint16 pointUpper, 
        uint128 amount
        ) public onlyEntry _lock_ returns(uint256 , uint256 ){

        (Position.Info storage position,  uint256 amount0, uint256 amount1) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient, 
                pointLower : pointLower, 
                pointUpper: pointUpper, 
                liquidityDelta: -int128(amount)//.toInt128()
                })
            ); 

        if(amount0>0 || amount1> 0){
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + amount0,
                position.tokensOwed1 + amount1
            );
        }
        return (amount0, amount1); 
    }

    function collect(
        address recipient,
        uint16 tickLower,
        uint16 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public onlyEntry _lock_  returns (uint256 amount0, uint256 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
        }
    }


    function _modifyPosition(ModifyPositionParams memory params)
    private 
    returns(
        Position.Info storage position, 
        uint256 baseAmount, 
        uint256 tradeAmount
        )
    {
        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition(
            params.owner,
            params.pointLower,
            params.pointUpper,
            params.liquidityDelta,
            _slot0.point
        );

        if (params.liquidityDelta != 0){
            if (_slot0.point < params.pointLower){
                // in case where liquidity is just asks waiting to be sold into, 
                // so need to only provide tradeAsset 
                tradeAmount = tradeGivenLiquidity(
                    pointToPrice(params.pointUpper), 
                    pointToPrice(params.pointLower), 
                    params.liquidityDelta >= 0
                        ? uint256(int256(params.liquidityDelta))
                        : uint256(int256(-params.liquidityDelta))
                    ); 
            } else if( _slot0.point < params.pointUpper){
                uint128 liquidityBefore = liquidity; 

                // Get total asks to be submitted above current price
                tradeAmount = tradeGivenLiquidity(
                    pointToPrice(params.pointUpper),
                    _slot0.curPrice, 
                    params.liquidityDelta >= 0
                        ? uint256(int256(params.liquidityDelta))
                        : uint256(int256(-params.liquidityDelta))
                    ); 

                // Get total bids to be submitted below current price 
                baseAmount = baseGivenLiquidity(
                    _slot0.curPrice, 
                    pointToPrice(params.pointLower), 
                    params.liquidityDelta >= 0
                        ? uint256(int256(params.liquidityDelta))
                        : uint256(int256(-params.liquidityDelta))
                    ); 

                // Slope changes since current price is in this range 
                liquidity = addDelta(liquidityBefore, params.liquidityDelta);

            } else{
                // liquidity is just bids waiting to be bought into 
                baseAmount = baseGivenLiquidity(
                    pointToPrice(params.pointUpper), 
                    pointToPrice(params.pointLower), 
                    params.liquidityDelta >= 0
                        ? uint256(int256(params.liquidityDelta))
                        : uint256(int256(-params.liquidityDelta))
                ); 
            }
        }
    }

    uint256 public feeGrowthGlobalBase;
    uint256 public feeGrowthGlobalTrade;

    function _updatePosition(
        address owner, 
        uint16 pointLower, 
        uint16 pointUpper, 
        int128 liquidityDelta, 
        uint16 point 
        ) private returns(Position.Info storage position){

        position = positions.get(owner, pointLower, pointUpper); 

        uint256 _feeGrowthGlobalBase = feeGrowthGlobalBase; 
        uint256 _feeGrowthGlobalTrade = feeGrowthGlobalTrade; 

        if(liquidityDelta != 0){

            ticks.update(
                pointLower, 
                point, 
                liquidityDelta, 
                feeGrowthGlobalBase,
                feeGrowthGlobalTrade,
                false
                ); 

            ticks.update(
                pointUpper, 
                point, 
                liquidityDelta, 
                feeGrowthGlobalBase,
                feeGrowthGlobalTrade,
                true
                ); 
        } 
        (uint256 feeGrowthInsideBase, uint256 feeGrowthInsideTrade) =
            ticks.getFeeGrowthInside(pointLower, pointUpper, point, _feeGrowthGlobalBase, _feeGrowthGlobalTrade);
        position.update(liquidityDelta, feeGrowthInsideBase,feeGrowthInsideTrade); 
    }


    mapping(uint16=> int128) dynamicLiq; 
    function setDynamicLiquidity(uint16 point, int128 liq) internal {
        dynamicLiq[point] = liq; 
    }
    function setModifyLiqPoint(uint16 point) internal{
        slot0.modifyLiqPoint = point;  
    }
    function amortizeLiq() internal{
        slot0.amortized = true; 
    }

    function tradeGivenLiquidity(uint256 p2, uint256 p1, uint256 L) public pure returns(uint256){
        require(p2>=p1, "price ERR"); 
        return (p2-p1).mulWadDown(L); 
    }

    function baseGivenLiquidity(uint256 p2, uint256 p1, uint256 L) public pure returns(uint256) {
        require(p2>=p1, "price ERR"); 
        return LinearCurve.areaUnderCurve(tradeGivenLiquidity(p2, p1, L), 0, inv(L), p1); 
    }

    function liquidityGivenTrade(uint256 p2, uint256 p1, uint256 T) public pure returns(uint256){
        require(p2>=p1, "price ERR"); 
        return T.divWadDown(p2-p1); 
    }
    function liquidityGivenBase(uint256 p2, uint256 p1, uint256 B) public pure returns(uint256){
        require(p2>=p1, "price ERR"); 
        return B.divWadDown((p2-p1).mulWadDown((p2+p1)/2)); 
    }

    function pointToPrice(uint16 point) public pure returns(uint160){
        return(uint256(point) * priceDelta).toUint160(); 
    }

    /// @notice will round down to nearest integer 
    function priceToPoint(uint256 price) public pure returns(uint16){
        return uint16((price.divWadDown(priceDelta))/PRECISION); 
    }

    function xMax(uint256 curPrice, uint256 b, uint256 a) public pure returns(uint256){
        if(a==0) return type(uint256).max; 
        return (curPrice-b).divWadDown(a); 
    }
    function xMaxRoundUp(uint256 curPrice, uint256 b, uint256 a) public pure returns(uint256){
        return (curPrice-b).divWadUp(a); 
    }

    /// @notice get the lower bound of the given price range, or the y intercept of the curve of
    /// the current point
    function yInt(uint256 curPrice, bool moveUp) public pure returns(uint256){
        uint16 point = priceToPoint(curPrice); 

        // If at boundary when moving down, decrement point by one
        return (!moveUp && (curPrice%point == 0))? pointToPrice(point-1) : pointToPrice(point); 
    }

    function getNextPriceLimit(uint16 point, uint256 pDelta, bool moveUp) public pure returns(uint256){
        if (moveUp) return uint256(point+1) * pDelta; 
        else return uint256(point) * pDelta; 
    }

    function inv(uint256 l) internal pure returns(uint256){
        return l==0? PRECISION.divWadDown(l+1) : PRECISION.divWadDown(l) ; 
    }
    function invRoundUp(uint256 l) internal pure returns(uint256){
        return l==0? PRECISION.divWadUp(l+1) : PRECISION.divWadUp(l) ; 
    }
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
    function mod0(uint256 a, uint256 b) internal pure returns(bool){
        return (a%b ==0); 
    }
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    /// @param x The liquidity before change
    /// @param y The delta by which liquidity should be changed
    /// @return z The liquidity delta
    function addDelta(uint128 x, int128 y) public pure returns (uint128 z) {
        if (y < 0) {
            require((z = x - uint128(-y)) < x, 'LS');
        } else {
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }
    function getLiq(address to, uint16 point, bool isAsk) public view returns(uint128){
        return  isAsk
                ? positions.get(to, point, point+1).askLiq
                : positions.get(to, point, point+1).bidLiq; 
    }

}

library LinearCurve{
    uint256 public constant PRECISION = 1e18; 
    using FixedPointMath for uint256; 


    /// @notice Compute results of swap given amount in and params
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// b is 0 and s is curPrice/a during variable liquidity phase
    function swapStep(
        uint256 curPrice, 
        uint256 targetPrice, 
        int256 amountRemaining, 
        uint24 feePips,    
        GranularBondingCurve.swapVars memory vars       
        ) 
        public 
        pure 
        returns(uint256 nextPrice, uint256 amountIn, uint256 amountOut, uint256 feeAmount ){

        bool moveUp = targetPrice >= curPrice; 
        bool exactInput = amountRemaining >= 0; 

        // If move up and exactInput, amountIn is base, amountOut is trade 
        if (exactInput){
            // uint256 amountRemainingLessFee = uint256(amountRemaining).mulDivDown(1e6-feePips, 1e6);

            if (moveUp){
                (amountOut, nextPrice) = amountOutGivenIn(uint256(amountRemaining),vars.s,vars.a,vars.b, true); 

                // If overshoot go to next point
                if (nextPrice >= targetPrice){
                    nextPrice = targetPrice; 

                    // max amount out for a given price range is Pdelta / a 
                    amountOut = (targetPrice - curPrice).divWadDown(vars.a); 
                    amountIn = areaUnderCurve(amountOut, vars.s,vars.a,vars.b).mulDivDown(1e6+feePips, 1e6); 
                }            
                else {
                    amountIn = uint256(amountRemaining).mulDivDown(1e6+feePips, 1e6); 
                }   
            }

            // amountIn is trade, amountOut is base 
            else {
                // If amount is greater than s, then need to cap it 
                (amountOut, nextPrice) = amountOutGivenIn(min(uint256(amountRemaining),vars.s), vars.s,vars.a,vars.b,false); 
                // If undershoot go to previous point 
                if(nextPrice <= targetPrice && vars.a > 0){//TODO might introduce bugs 
                    nextPrice = targetPrice; 

                    // max amount out is area under curve 
                    amountIn = (curPrice - targetPrice).divWadDown(vars.a);
                    amountOut = areaUnderCurve(amountIn, 0,vars.a,vars.b); 
                    amountIn = amountIn.mulDivDown(1e6+feePips, 1e6); 

                }
                else{
                    amountIn = uint256(amountRemaining).mulDivDown(1e6+feePips, 1e6); 
                }
            }
            feeAmount = amountIn.mulDivDown(uint256(feePips).mulDivDown(1e6,1e6+feePips), 1e6); 
        }

        else {
            if(moveUp){
                uint256 remaining = uint256(-amountRemaining); 
                nextPrice = vars.a.mulWadUp(remaining) + curPrice; 

                // if overshoot
                if(nextPrice>=targetPrice){
                    amountIn = xMax(targetPrice, curPrice,  vars.a); 
                    nextPrice = targetPrice; 

                    // Prevent stuck cases where point is almost filled but not quite 
                    if(remaining - amountIn<=1e4){
                        amountIn = remaining; 
                    } 
                }
                else amountIn = remaining; 

                amountOut = areaUnderCurveRoundUp(amountIn, 0, vars.a, curPrice); //you want this to be more, so round up

            }
            else{
                //TODO 
            }
            feeAmount = amountOut.mulDivDown(feePips, 1e6);
            amountOut = amountOut + feeAmount;
        }
    }


    /// @dev tokens returned = [((a*s + b)^2 + 2*a*p)^(1/2) - (a*s + b)] / a
    /// @param amount: amount of base in
    /// returns amountDelta wanted token returned 
    function amountOutGivenIn( 
        uint256 amount,
        uint256 s, 
        uint256 a, 
        uint256 b, 
        bool up
        ) 
        public 
        pure 
        returns(uint256 amountDelta, uint256 resultPrice) {
        
        // If liquidity is not infinite 
        if(a > 0){
            if (up){
                //TODO overflow on small amount 
                uint256 x = ((a.mulWadDown(s) + b) ** 2)/PRECISION; 
                uint256 y = 2*( a.mulWadDown(amount)); 
                uint256 x_y_sqrt = ((x+y)*PRECISION).sqrt();
                uint256 z = (a.mulWadDown(s) + b); 
                amountDelta = (x_y_sqrt-z).divWadDown(a);
                resultPrice = a.mulWadDown(amountDelta + s) + b; 
            } else{
                uint256 z = b + a.mulWadDown(s) - a.mulWadDown(amount)/2;  
                amountDelta = amount.mulWadDown(z); 
                resultPrice = a.mulWadDown(s-amount) + b; 
            }
        }

        // When a = 0, infinite liquidity and constant price
        else{     
            if(up){
                amountDelta = amount.divWadDown(b); 
            } else{
                amountDelta = amount.mulWadDown(b); 
            }
            resultPrice = b;             
        }
    }

    /// @notice calculates area under the curve from s to s+amount
     /// result = a * amount / 2  * (2* supply + amount) + b * amount
     /// returned in collateral decimals
    function areaUnderCurve(
        uint256 amount, 
        uint256 s, 
        uint256 a, 
        uint256 b) 
        public
        pure 
        returns(uint256 area){
        area = ( a.mulWadDown(amount) / 2 ).mulWadDown(2 * s + amount) + b.mulWadDown(amount); 
    }
    function areaUnderCurveRoundUp(
        uint256 amount, 
        uint256 s, 
        uint256 a, 
        uint256 b) 
        public
        pure 
        returns(uint256 area){
        // you want area to be big for a given amount 
        area = ( a.mulWadUp(amount) / 2 ).mulWadUp(2 * s + amount) + b.mulWadUp(amount); 
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a <= b ? a : b;
    }

    function xMax(uint256 curPrice, uint256 b, uint256 a) public pure returns(uint256){
        if(a==0) return type(uint256).max; 
        return (curPrice-b).divWadDown(a); 
    }

}

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    using FixedPointMath for uint256;

    // info stored for each user's position
    struct Info {
        uint128 bidCrossId; 
        uint128 askCrossId; 
        uint128 askLiq; 
        uint128 bidLiq; 

        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint256 tokensOwed0;
        uint256 tokensOwed1;

        
    }

    function updateLimit(
        Info storage self,
        int128 limitLiqudityDelta, 
        bool isAsk, 
        uint128 crossId
        ) internal {

        if (isAsk) {
            self.askLiq = addDelta(self.askLiq, limitLiqudityDelta);
            if( limitLiqudityDelta > 0) self.askCrossId = crossId; 
        } 

        else {
            self.bidLiq = addDelta(self.bidLiq, limitLiqudityDelta); 
            if( limitLiqudityDelta > 0) self.bidCrossId = crossId; 
        }
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        uint16 tickLower,
        uint16 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidity > 0, 'NP'); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = addDelta(_self.liquidity, liquidityDelta);
        }

        // calculate accumulated fees
        uint128 tokensOwed0 = uint128(
                (feeGrowthInside0X128-_self.feeGrowthInside0LastX128)
                .mulDivDown(uint256(_self.liquidity), 1e18)
            );
        uint128 tokensOwed1 =uint128(
                (feeGrowthInside1X128-_self.feeGrowthInside1LastX128)
                .mulDivDown(uint256(_self.liquidity), 1e18)
            );
            
        // update the position
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }

    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            require((z = x - uint128(-y)) < x, 'LS');
        } else {
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }
}

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using FixedPointMath for uint256;

    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutsideBase;
        uint256 feeGrowthOutsideTrade;
        // the cumulative tick value on the other side of the tick
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;

        uint128 askLiquidityGross; 
        uint128 bidLiquidityGross;
        uint128 askNumCross; 
        uint128 bidNumCross; 
    }

    function getNumCross(
        mapping(uint16=> Tick.Info) storage self, 
        uint16 tick, 
        bool isAsk
        ) internal view returns(uint128){
        return isAsk? self[tick].askNumCross : self[tick].bidNumCross; 
    }

    function oneTimeLiquidity(
        mapping(uint16=> Tick.Info) storage self, 
        uint16 tick 
        ) internal view returns(uint128){
        Tick.Info memory info = self[tick]; 
        assert(info.askLiquidityGross==0 || info.bidLiquidityGross==0); 
        return info.askLiquidityGross + info.bidLiquidityGross; 
    }

    function deleteOneTimeLiquidity(
        mapping(uint16=> Tick.Info) storage self, 
        uint16 tick, 
        bool isAsk
        ) internal {
        Tick.Info storage info = self[tick]; 
        if(isAsk) {
            info.askLiquidityGross = 0;
            info.askNumCross++; 
            console.log('tick??', tick); 
        }
        else {
            info.bidLiquidityGross = 0; 
            info.bidNumCross++; 
        }
    }

    function updateOneTimeLiquidity(
        mapping(uint16=> Tick.Info) storage self, 
        uint16 tick, 
        int128 oneTimeLiquidityDelta,
        bool isAsk
        ) internal {
        if (isAsk) self[tick].askLiquidityGross = addDelta(self[tick].askLiquidityGross, oneTimeLiquidityDelta); 
        else self[tick].bidLiquidityGross = addDelta(self[tick].bidLiquidityGross, oneTimeLiquidityDelta);
    }

    function update(
        mapping(uint16 => Tick.Info) storage self,
        uint16 tick,
        uint16 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobalBase, 
        uint256 feeGrowthGlobalTrade, 
        bool upper
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross; 
        uint128 liquidityGrossAfter = addDelta(liquidityGrossBefore, liquidityDelta); 

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if(liquidityGrossBefore == 0) {
            if(tick<=tickCurrent){
            info.feeGrowthOutsideBase = feeGrowthGlobalBase; 
            info.feeGrowthOutsideTrade = feeGrowthGlobalTrade; 
            }
            info.initialized = true; 
        }
        info.liquidityGross = liquidityGrossAfter;

        info.liquidityNet = upper 
            ? (int256(info.liquidityNet)-liquidityDelta).toInt128()
            : (int256(info.liquidityNet)+liquidityDelta).toInt128(); 
    }

    function clear(mapping(uint16 => Tick.Info) storage self, uint16 tick) internal {
        delete self[tick];
    }

    function cross(
        mapping(uint16 => Tick.Info) storage self,
        uint16 tick, 
        uint256 feeGrowthGlobalBase,
        uint256 feeGrowthGlobalTrade
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick]; 

        liquidityNet = info.liquidityNet; 
        info.feeGrowthOutsideBase = feeGrowthGlobalBase - info.feeGrowthOutsideBase; 
        info.feeGrowthOutsideTrade = feeGrowthGlobalTrade - info.feeGrowthOutsideTrade;
    }

    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            require((z = x - uint128(-y)) < x, 'LS');
        } else {
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }

    function getFeeGrowthInside(
        mapping(uint16 => Tick.Info) storage self,
        uint16 tickLower,
        uint16 tickUpper,
        uint16 tickCurrent,
        uint256 feeGrowthGlobalBase,
        uint256 feeGrowthGlobalTrade
    ) internal view returns (uint256 feeGrowthInsideBase, uint256 feeGrowthInsideTrade) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // calculate fee growth below
        uint256 feeGrowthBelowBase;
        uint256 feeGrowthBelowTrade;
        if (tickCurrent >= tickLower) {
            feeGrowthBelowBase = lower.feeGrowthOutsideBase;
            feeGrowthBelowTrade = lower.feeGrowthOutsideTrade;
        } else {
            feeGrowthBelowBase = feeGrowthGlobalBase - lower.feeGrowthOutsideBase;
            feeGrowthBelowTrade = feeGrowthGlobalTrade - lower.feeGrowthOutsideTrade;
        }

        // calculate fee growth above
        uint256 feeGrowthAboveBase;
        uint256 feeGrowthAboveTrade;
        if (tickCurrent < tickUpper) {
            feeGrowthAboveBase = upper.feeGrowthOutsideBase;
            feeGrowthAboveTrade = upper.feeGrowthOutsideTrade;
        } else {
            feeGrowthAboveBase = feeGrowthGlobalBase - upper.feeGrowthOutsideBase;
            feeGrowthAboveTrade = feeGrowthGlobalTrade - upper.feeGrowthOutsideTrade;
        }

        feeGrowthInsideBase = feeGrowthGlobalBase - feeGrowthBelowBase - feeGrowthAboveBase;
        feeGrowthInsideTrade = feeGrowthGlobalTrade - feeGrowthBelowTrade - feeGrowthAboveTrade;
    }
}


contract SpotPool is GranularBondingCurve{

    ERC20 BaseToken; //junior
    ERC20 TradeToken; //senior 
    // GranularBondingCurve public pool; 

    constructor(
        address _baseToken, 
        address _tradeToken
        )GranularBondingCurve(_baseToken,_tradeToken){
        BaseToken = ERC20(_baseToken); 
        TradeToken = ERC20(_tradeToken); 
        // pool = new GranularBondingCurve(_baseToken,_tradeToken); 
    }

    function handleBuys(address recipient, uint256 amountOut, uint256 amountIn, bool up) internal {

        if(up){
            console.log('balances', TradeToken.balanceOf(address(this)), BaseToken.balanceOf(address(this)));
            console.log('togive', amountOut, amountIn); 
            TradeToken.transfer(recipient, amountOut); 
            console.log('balofre', BaseToken.balanceOf(recipient));
            BaseToken.transferFrom(recipient, address(this), amountIn);
        }

        else{
            BaseToken.transfer(recipient, amountOut); 
            TradeToken.transferFrom(recipient, address(this), amountIn);
        }
    }

    // function getCurPrice() external view returns(uint256){
    //     return uint256(pool.getCurPrice());
    // }

    /// @notice if buyTradeForBase, move up, and vice versa 
    function takerTrade(
        address recipient, 
        bool buyTradeForBase, 
        int256 amountIn,
        uint256 priceLimit, 
        bytes calldata data        
        ) external returns(uint256 poolamountIn, uint256 poolamountOut){

        (poolamountIn, poolamountOut) = this.trade(
            recipient, 
            buyTradeForBase, 
            amountIn,  
            priceLimit, 
            data
        ); 
        handleBuys(recipient, poolamountOut, poolamountIn, buyTradeForBase); 
    }

    /// @notice specify how much trade trader intends to sell/buy 
    function makerTrade(
        bool buyTradeForBase,
        uint256 amountIn,
        uint16 point
        ) external {
        (uint256 toEscrowAmount, uint128 crossId) 
                = this.placeLimitOrder(msg.sender, 
                    point, 
                    uint128(liquidityGivenTrade(pointToPrice(point+1), pointToPrice(point), amountIn)), 
                    !buyTradeForBase); 

        // Collateral for bids
        if (buyTradeForBase) BaseToken.transferFrom(msg.sender, address(this), toEscrowAmount); 

        // or asks
        else TradeToken.transferFrom(msg.sender, address(this), toEscrowAmount); 
    }

    function makerClaim(
        uint16 point, 
        bool buyTradeForBase
        ) external {
        uint256 claimedAmount = this.claimFilledOrder(
            msg.sender, 
            point, 
            !buyTradeForBase
        ); 

        if (buyTradeForBase) TradeToken.transfer(msg.sender, claimedAmount);
        else BaseToken.transfer(msg.sender, claimedAmount); 

    }
}





