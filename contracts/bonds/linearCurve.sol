pragma solidity ^0.8.4;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

struct SwapParams{
  uint256 s; 
  uint256 a; 
  uint256 b; 
  bool up;

  uint256 pieceWisePrice;   
}

/*
@notice linear curves followed by flat curve 
      - - - - 
    /
  /
/
@dev all computations are done in WAD space, any conversion if needed should be made in the parent contract
*/
library LinearPiecewiseCurve{
    uint256 public constant PRECISION = 1e18; 
    using FixedPointMathLib for uint256; 

    function outGivenArea(
        uint256 amount, 
        SwapParams memory vars
        ) internal pure returns(uint256 amountDelta, uint256 resultPrice){
        uint256 x = ((vars.a.mulWadDown(vars.s) + vars.b) ** 2)/PRECISION; 
        uint256 y = 2*( vars.a.mulWadDown(amount)); 
        uint256 x_y_sqrt = ((x+y)*PRECISION).sqrt();
        uint256 z = (vars.a.mulWadDown(vars.s) + vars.b); 
        amountDelta = (x_y_sqrt-z).divWadDown(vars.a);
        resultPrice = vars.a.mulWadDown(amountDelta + vars.s) + vars.b; 
    }

    function outGivenSupply(
        uint256 amount,
        uint256 s, 
        uint256 a, 
        uint256 b
        ) internal pure returns(uint256 amountDelta, uint256 resultPrice){
        uint256 z = b + a.mulWadDown(s) - a.mulWadDown(amount)/2;  
        amountDelta = amount.mulWadDown(z); 
        resultPrice = a.mulWadDown(s-amount) + b; 
    }

    /// @dev tokens returned = [((a*s + b)^2 + 2*a*p)^(1/2) - (a*s + b)] / a
    /// @param amount: amount of base in
    /// returns amountDelta wanted token returned 
    function amountOutGivenIn( 
        uint256 amount,
        SwapParams memory vars
        ) 
        public 
        view 
        returns(uint256 amountDelta, uint256 resultPrice) {
        
        if(vars.pieceWisePrice ==0){
            if (vars.up){
                //TODO overflow on small amount 
                uint256 x = ((vars.a.mulWadDown(vars.s) + vars.b) ** 2)/PRECISION; 
                uint256 y = 2*( vars.a.mulWadDown(amount)); 
                uint256 x_y_sqrt = ((x+y)*PRECISION).sqrt();
                uint256 z = (vars.a.mulWadDown(vars.s) + vars.b); 
                amountDelta = (x_y_sqrt-z).divWadDown(vars.a);
                resultPrice = vars.a.mulWadDown(amountDelta + vars.s) + vars.b; 
            } else{
                uint256 z = vars.b + vars.a.mulWadDown(vars.s) - vars.a.mulWadDown(amount)/2;  
                amountDelta = amount.mulWadDown(z); 
                resultPrice = vars.a.mulWadDown(vars.s-amount) + vars.b; 
            }
        } else{     
            uint256 pieceWisePoint = (vars.pieceWisePrice-vars.b).divWadDown(vars.a); 
            if(vars.up){
                // get maximum area till piecewiseprice
                // if amount is larger, then cap it to maximum area 
                // amount-maximum area will be used as remainder 

                // Haven't cross to second curve yet 
                if(pieceWisePoint> vars.s){
                    uint256 maximumArea = areaUnderCurve(pieceWisePoint-vars.s, vars.s,vars.a,vars.b  ); 
                    (amountDelta, resultPrice) = maximumArea >= amount
                        ? outGivenArea(amount, vars)
                        : (pieceWisePoint - vars.s + (amount - maximumArea).divWadDown(vars.pieceWisePrice), vars.pieceWisePrice);
                } else{
                    amountDelta = amount.divWadDown(vars.pieceWisePrice); 
                    resultPrice = vars.pieceWisePrice; 
                }
            } else{
                if(pieceWisePoint> vars.s){
                    (amountDelta, resultPrice) = outGivenSupply(amount, vars.s, vars.a, vars.b); 
                } else{ 

                    uint256 maximumArea = (vars.s - pieceWisePoint).divWadDown(vars.pieceWisePrice); 

                    (amountDelta, resultPrice) = maximumArea >= amount
                        ? (amount.mulWadDown(vars.pieceWisePrice), vars.pieceWisePrice)
                        : ((maximumArea).mulWadDown(vars.pieceWisePrice) 
                        + areaUnderCurveDown(amount-maximumArea, pieceWisePoint, vars.a, vars.b)
                        , vars.a.mulWadDown(vars.s-amount) + vars.b); 
                }
            }
        }
    }

    // @notice amount is in supply 
    function areaUnderCurveDown(
        uint256 amount,
        uint256 s, 
        uint256 a, 
        uint256 b
        ) public pure returns(uint256 area){
        uint256 z = b + a.mulWadDown(s) - a.mulWadDown(amount)/2;  
        area = amount.mulWadDown(z); 
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

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a <= b ? a : b;
    }

    function xMax(uint256 curPrice, uint256 b, uint256 a) public pure returns(uint256){
        if(a==0) return type(uint256).max; 
        return (curPrice-b).divWadDown(a); 
    }

}








