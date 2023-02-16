pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/global/types.sol"; 
import {LinearPiecewiseCurve, SwapParams} from "../contracts/bonds/linearCurve.sol"; 
import {CustomTestBase} from "./testbase.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract CurveTest is CustomTestBase {
    using FixedPointMathLib for uint256; 
    using stdStorage for StdStorage;
    using LinearPiecewiseCurve for uint256; 

    uint256 public pieceWisePrice; 
    uint256 public netSupply; 
    uint256 public a_initial;
    uint256 public b_initial; // b without discount cap 
    uint256 public b;
    uint256 public discount_cap; 
    uint256 public discountedReserves; 
    uint256 public upperBound; 


    function setUp() public {
        // a_initial = 
    }
   

    function testLinearUp(
        uint P,
        uint I, 
        uint poolamountIn, 
        uint netSupplyInput) public {
        vm.assume(I>=P/1000); 
        vm.assume(poolamountIn>=1e14); 

        P = constrictToRange(P, 1e18, 1000000000e18); 
        I = constrictToRange(I, 5e17, 200000000e18); 
        poolamountIn = constrictToRange(poolamountIn,1e14, P); 
   
        b_initial = (2*P).divWadDown(P+I) >= precision
            ? (2*P).divWadDown(P+I) - precision
            : 5e17; 
        a_initial = (precision-b_initial).divWadDown(P+I); 

        (discount_cap, b) =  P.mulWadDown(sigma).amountOutGivenIn(SwapParams(0, a_initial, b_initial, true, 0));

        (uint poolamountOut, uint resultPrice ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a_initial, b, true, 0 )); 

        // Correct within 
        assertApproxEqBasis(poolamountIn, b.mulWadDown(poolamountOut)+ poolamountOut.mulWadDown(resultPrice-b)/2, 10); 
        assertApproxEqAbs(resultPrice, poolamountOut.mulWadDown(netSupply + a_initial)+ b, 10);

    }

    function testLinearDown(
        uint P,
        uint I, 
        uint poolamountIn, 
        uint netSupply
        ) public {
        vm.assume(I>=P/1000); 
        vm.assume(poolamountIn>=1e14); 

        P = constrictToRange(P, 1e18, 1000000000e18); 
        I = constrictToRange(I, 5e17, 200000000e18); 
        netSupply = constrictToRange(netSupply, 1e17, P); 
        poolamountIn = constrictToRange(poolamountIn,1e14, netSupply); 
        console.log('P, I, netSupply, poolamountIn', P, I); 
        console.log(netSupply, poolamountIn); 
        // uint P = 90e18; 
        // uint I = 11e18; 
        // uint poolamountIn = 13e18; 
        // uint netSupply = poolamountIn*2; 

        b_initial = (2*P).divWadDown(P+I) >= precision
            ? (2*P).divWadDown(P+I) - precision
            : 5e17; 
        a_initial = (precision-b_initial).divWadDown(P+I); 

        // Calculate and store maximum tokens for discounts, and get new initial price after saving for discounts
        (discount_cap, b) =  P.mulWadDown(sigma).amountOutGivenIn(SwapParams(0, a_initial, b_initial, true, 0));

        (uint poolamountOut, uint resultPrice ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a_initial, b, false, 0 )); 
        uint priorPrice = netSupply.mulWadDown(a_initial) + b; 

        assertApproxEqBasis(poolamountOut, 
            resultPrice.mulWadDown(poolamountIn)+ poolamountIn.mulWadDown(priorPrice - resultPrice)/2, 10); 
        assertApproxEqAbs(resultPrice, (netSupply - poolamountIn).mulWadDown(a_initial)+ b, 10); 
    }

    function testPieceWiseLinearUp() public{

        uint pieceWisePrice = 8e17; 
        uint b = 7e17; 
        uint saleAmount = 100e18; 

        uint256 saleAmountQty = (2*saleAmount).divWadDown(pieceWisePrice +b); 
        uint256 a = (pieceWisePrice - b).divWadDown(saleAmountQty); 

        uint256 poolamountIn = 120e18; 

        (uint poolamountOut, uint resultPrice ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a, b, true, pieceWisePrice)); 

        if(saleAmount< poolamountIn){
            assertApproxEqAbs(resultPrice,pieceWisePrice, 10 ); 
            assertApproxEqAbs((poolamountOut - saleAmountQty).mulWadDown(pieceWisePrice),
             poolamountIn - saleAmount, 1000); 
        }else if(saleAmount == poolamountIn){
            assertApproxEqAbs(resultPrice, pieceWisePrice, 10); 
            assertApproxEqAbs(poolamountOut, saleAmountQty, 10); 
        }else{
            assert(resultPrice < pieceWisePrice); 
            assert(poolamountOut< saleAmountQty); 
            (uint poolamountOutNP,uint resultPriceNP ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a, b, true, 0 )); 
            assertEq(poolamountOut, poolamountOutNP); 
            assertEq(resultPrice, resultPriceNP); 
        }
    }

    function testPieceWiseLinearDown() public{
        uint pieceWisePrice = 8e17; 
        uint b = 7e17; 

        uint saleAmount = 100e18; 
        uint256 poolamountIn = 130e18; 

        uint256 saleAmountQty = (2*saleAmount).divWadDown(pieceWisePrice +b); 
        uint256 a = (pieceWisePrice - b).divWadDown(saleAmountQty); 
        uint256 netSupply = saleAmountQty*2; 

        (uint poolamountOut, uint resultPrice ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a, b, false, pieceWisePrice)); 

        // start at flat curve, end at flat curve
        if(netSupply> saleAmountQty && poolamountIn < netSupply -saleAmountQty){
            assertApproxEqAbs(resultPrice, pieceWisePrice, 10); 
            assertApproxEqAbs(poolamountOut, poolamountIn.mulWadDown(pieceWisePrice), 100); 

        } else if(netSupply> saleAmountQty && poolamountIn>= netSupply - saleAmountQty){
            uint256 pieceWisePoint = (pieceWisePrice-b).divWadDown(a); 

            // start at flat curve, end at linear curve  
            assert(resultPrice < pieceWisePrice); 
            assertApproxEqAbs(resultPrice, (netSupply - poolamountIn).mulWadDown(a) + b, 100); 
            assertApproxEqAbs(poolamountOut,
             (netSupply-saleAmountQty).mulWadDown(pieceWisePrice) + (poolamountIn-(netSupply-saleAmountQty)).areaUnderCurveDown(
                pieceWisePoint, a, b) , 500) ; 
            // assertApproxEqAbs(poolamountOut, )
        } else if(netSupply < saleAmountQty){
            //start at linear, end at linear
            assert(resultPrice< pieceWisePrice); 
            (uint poolamountOutNP, uint resultPriceNP ) = poolamountIn.amountOutGivenIn(
            SwapParams(netSupply, a, b, false, 0)); 
            assertEq(poolamountOut, poolamountOutNP); 
            assertEq(resultPrice, resultPriceNP); 


        }
    }

   

}

// contract UtilizerCycle is FullCycleTest{


// }
