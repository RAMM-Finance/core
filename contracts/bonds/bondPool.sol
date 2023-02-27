pragma solidity ^0.8.9;
import { LinearPiecewiseCurve, SwapParams} from "./linearCurve.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {oERC20} from "../utils/ownedERC20.sol"; 
import "forge-std/console.sol";

contract SyntheticZCBPool{
    using FixedPointMathLib for uint256;
    using LinearPiecewiseCurve for uint256; 

    constructor(address base, 
        address trade, 
        address s_trade, 
        address _entry, 
        address _controller
        ){
        baseToken =  ERC20(base);
        tradeToken = oERC20(trade);
        s_tradeToken = oERC20(s_trade);

        entry = _entry; 
        controller = _controller; 
    }

    /// @notice Long up the curve, or short down the curve 
    /// @param amountIn if isLong, amountIn > 0 means it is in base, amountIn < 0 means it is in trade
    /// @param priceLimit is slippage tolerance
    /// @param data is abi.encode(address) -> address receives the long or short zcb
    function takerOpen(
        bool isLong, 
        int256 amountIn,
        uint256 priceLimit, 
        bytes calldata data
        ) external  returns(uint256 poolamountIn, uint256 poolamountOut)
    {
        uint256 bal = baseBal(); 
        bool exactInput = amountIn>=0;
        if(isLong){
            // amountIn is base, out is trade
            poolamountIn = exactInput ? uint256(amountIn) : uint256(-amountIn);

            (poolamountOut, curPrice) = !exactInput
            	? (poolamountIn.areaUnderCurve(netSupply, a_initial, b), 
            		(netSupply + poolamountIn).mulWadDown(a_initial) + b)
            	: poolamountIn.amountOutGivenIn( SwapParams(netSupply, a_initial, b, true, pieceWisePrice )); 

            if(exactInput) netSupply += poolamountOut; 
            else netSupply += poolamountIn;

            if(exactInput){ 
            	iTradeCallBack(msg.sender).tradeCallBack(poolamountIn, data); 
            	require(baseBal() >= poolamountIn + bal, "balERR"); 
            	tradeToken.mint(abi.decode(data, (address)), poolamountOut); 
        	}else{
            	iTradeCallBack(msg.sender).tradeCallBack(poolamountOut, data); 
            	require(baseBal() >= poolamountOut + bal, "balERR"); 
            	tradeToken.mint(abi.decode(data, (address)), poolamountIn); 
       			// for return values 
        		uint256 cachedOut = poolamountOut; 
        		poolamountOut = poolamountIn;
        		poolamountIn = cachedOut; 
        	}
        } else{
        	// TODO do exact input 
        	require(netSupply>=uint256(amountIn), "not enough liquidity"); 
            //amount in is trade out is base 
            (poolamountOut,curPrice) = uint256(amountIn).amountOutGivenIn(
                SwapParams(netSupply, a_initial, b, false, pieceWisePrice)); 
            netSupply -= uint256(amountIn); 

            require(poolamountOut <= bal, "not enough liquidity"); 
            uint256 cached_poolamountOut = poolamountOut; 
            // poolamountIn is the number of short tokens minted, poolamountIn * maxprice - poolamountOut is the collateral escrowed
            poolamountOut = uint256(amountIn).mulWadDown(maxPrice) - poolamountOut;

            iTradeCallBack(msg.sender).tradeCallBack(poolamountOut, data); 
            require(baseBal() >= poolamountOut + bal, "balERR"); 
            s_tradeToken.mint(abi.decode(data,(address)), uint256(amountIn)); 
            poolamountIn = cached_poolamountOut; 


            // need to send cached poolamountOut(the area under the curve) data for accounting purposes
        }

    }

    /// @notice calculate and store initial curve params that takes into account
    /// validator rewards(from discounted zcb). For validator rewards, just skew up the initial price
    /// These params are used for utilizer bond issuance, but a is set to 0 after issuance phase 
    /// @param sigma is the proportion of P that is going to be bought at a discount  
    function calculateInitCurveParams(
        uint256 P, 
        uint256 I, 
        uint256 sigma,
        uint256 alpha, 
        uint256 delta) external {
        require(msg.sender == controller, "unauthorized"); 
        b_initial = (2*P).divWadDown(P+I) >= precision
            ? (2*P).divWadDown(P+I) - precision
            : MIN_INIT_PRICE;         
        a_initial = (precision-b_initial).divWadDown(P+I); 

        discount_cap_collateral = P.mulWadDown(0); //sigma =0 TODO

        // Calculate and store maximum tokens for discounts, and get new initial price after saving for discounts
       (discount_cap, b) = discount_cap_collateral.amountOutGivenIn(SwapParams(0, a_initial, b_initial, true, 0));
        (, upperBound) = P.mulWadDown(alpha+delta).amountOutGivenIn(SwapParams(0, a_initial, b_initial,true, 0)); 
        curPrice = b;
        // (discount_cap, b) = LinearCurve.amountOutGivenIn(P.mulWadDown(sigma), 0, a_initial, b_initial, true);
        // (, upperBound )= LinearCurve.amountOutGivenIn(P.mulWadDown(alpha+delta), 0, a_initial, b_initial,true); 
    }

    /// @notice calculates initparams for pool based instruments 
    /// param endPrice is the inception Price of longZCB, or its price when there is no discount
    /// endPrice -> inceptionPrice.
    /// saleAmount is in underlying.
    /// initPrice and inceptionPrice are denominated in ZCB (X trade per 1 base)
    function calculateInitCurveParamsPool(
        uint256 saleAmount, 
        uint256 initPrice, 
        uint256 endPrice, 
        uint256 sigma
        ) external returns(uint256){
        require(msg.sender == controller, "unauthorized"); 

        uint256 a = a_initial = ((endPrice-initPrice).mulWadDown(endPrice+initPrice)).divWadDown(2*saleAmount) ; 
        (saleAmountQty,  ) = saleAmount.amountOutGivenIn( SwapParams(0, a, initPrice,true, 0)); 

        //Set discount cap as saleAmount * sigma 
        (discount_cap, ) = saleAmount.mulWadDown(sigma).amountOutGivenIn(SwapParams(0, a, initPrice,true, 0)); 
        // (discount_cap, ) = LinearCurve.amountOutGivenIn(saleAmount.mulWadDown(sigma),0, a, initPrice,true ); 
        curPrice = b = initPrice; 

        // How much total discounts are validators and managers getting
        // uint256 x = discount_cap.mulWadDown(endPrice) + saleAmountQty.mulWadDown(endPrice) ; 
        // uint256 y = saleAmount.mulWadDown(sigma)  +saleAmount ; 
        // // For rounding errors cases
        // managementFee = x>=y? x-y : 0;
        managementFee = saleAmountQty.mulWadDown(endPrice) >= saleAmount
            ?saleAmountQty.mulWadDown(endPrice) - saleAmount
            :0; 

        console.log('managementFee', managementFee);

        pieceWisePrice = endPrice; 

        return managementFee; 

    }

    /// @notice computes area between the curve and max price for given storage parameters
    function areaBetweenCurveAndMax(uint256 amount) public view returns(uint256){
        (uint256 amountDelta, ) = amount.amountOutGivenIn(SwapParams(0, a_initial, b_initial, true, 0)); 
        return amountDelta.mulWadDown(maxPrice) - amount; 
    }

    /// @notice mints new zcbs 
    function trustedDiscountedMint(
        address receiver, 
        uint256 amount 
        ) external{
        require(msg.sender == entry, "entryERR"); 

        tradeToken.mint(receiver, amount);
        discountedReserves += amount;
    }

    function trustedMint(address receiver, uint256 amount, bool long) external{
        if(long) tradeToken.mint(receiver, amount); 
        else s_tradeToken.mint(receiver, amount); 
    }

    function trustedBurn(
        address trader, 
        uint256 amount, 
        bool long
        ) external {
        require(msg.sender == entry, "entryERR"); 
        if (long) tradeToken.burn(trader, amount); 
        else s_tradeToken.burn(trader, amount);
    }

    function flush(address flushTo, uint256 amount) external {
        require(msg.sender == controller, "entryERR"); 
        if (amount == type(uint256).max) baseToken.transfer(flushTo, baseBal()); 
        else baseToken.transfer(flushTo, amount); 
    }

    function baseBal() public view returns(uint256){
        return baseToken.balanceOf(address(this)); 
    }

    function getCurPrice() external view returns(uint256){
    	return curPrice; 
    }


    uint256 curPrice; 

    uint256 public pieceWisePrice; 
    uint256 public netSupply; 
    uint256 public a_initial;
    uint256 public b_initial; // b without discount cap 
    uint256 public b;
    uint256 public discount_cap; // max trade from validators.
    uint256 public discount_cap_collateral; // max base from validators
    uint256 public discountedReserves; 
    uint256 public upperBound; 
    uint256 public saleAmountQty; 
    uint256 public managementFee; 
    ERC20 public  baseToken; 
    oERC20 public  tradeToken; 
    oERC20 public  s_tradeToken; 

    address public immutable entry; 
    address public immutable controller; 
    uint256 public constant precision = 1e18; 
    uint256 public constant maxPrice = 1e18; 
    uint256 public constant MIN_INIT_PRICE = 5e17;
}



       // saleAmountQty = (2*saleAmount).divWadDown(initPrice +endPrice); 
        // uint256 a =a_initial= (endPrice - initPrice).divWadDown(saleAmountQty); 







interface iTradeCallBack{
    function tradeCallBack(
        uint256 amount0,
 bytes calldata data    ) external;
} 