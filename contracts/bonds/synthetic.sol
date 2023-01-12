pragma solidity ^0.8.9;
import { LinearCurve} from "./GBC.sol"; 
import {BoundedDerivativesPool} from "./boundedDerivatives.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "./libraries.sol"; 
import "forge-std/console.sol";

contract ZCBFactory{
    function newBond(
        string memory name, 
        string memory description 
        ) public returns(address) {
        ERC20 bondToken = new ERC20(name,description, 18);
        return address(bondToken); 
    }

}
contract SyntheticZCBPoolFactory{
    address public immutable controller;
    address public immutable zcbFactory; 
    constructor(address _controller, address _zcbFactory){
        controller = _controller; 
        zcbFactory = _zcbFactory; 
    }

    event PoolCreated(address pool, address longZCB, address shortZCB);

    /// @notice param base is the collateral used in pool 
    function newPool(
        address base, 
        address entry
        ) external returns(address longZCB, address shortZCB, SyntheticZCBPool pool){
        longZCB = ZCBFactory(zcbFactory).newBond("longZCB", "long");
        shortZCB = ZCBFactory(zcbFactory).newBond("shortZCB", "short");

        pool = new SyntheticZCBPool(
            base, longZCB, shortZCB, entry, controller
        ); 
        emit PoolCreated(address(pool), longZCB, shortZCB);
    }
}

contract SyntheticZCBPool is BoundedDerivativesPool{
    using FixedPointMathLib for uint256;

    uint256 public a_initial;
    uint256 public b_initial; // b without discount cap 
    uint256 public b;
    uint256 public discount_cap; 
    uint256 public discountedReserves; 
    uint256 public upperBound; 
    address public immutable controller; 
    uint256 public constant precision = 1e18; 
    constructor(address base, 
        address trade, 
        address s_trade, 
        address _entry, 
        address _controller
        )BoundedDerivativesPool(base,trade,s_trade, false){
        entry = _entry; 
        controller = _controller; 
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
        b_initial = (2*P).divWadDown(P+I) - precision; 
        a_initial = (precision-b_initial).divWadDown(P+I); 

        // Calculate and store maximum tokens for discounts, and get new initial price after saving for discounts
        (discount_cap, b) = LinearCurve.amountOutGivenIn(P.mulWadDown(sigma), 0, a_initial, b_initial, true);
        (, upperBound )= LinearCurve.amountOutGivenIn(P.mulWadDown(alpha+delta), 0, a_initial, b_initial,true); 

        // Set initial liquidity and price 
        setLiquidity(uint128(precision.divWadDown(a_initial))); 
        setPriceAndPoint(b);
    }

    /// @notice calculates initparams for pool based instruments 
    /// param endPrice is the inception Price of longZCB, or its price when there is no discount
    function calculateInitCurveParamsPool(
        uint256 saleAmount, 
        uint256 initPrice, 
        uint256 endPrice, 
        uint256 sigma
        ) external returns(uint256 managementFee){
        require(msg.sender == controller, "unauthorized"); 
        //TODO these fails at some inputs
        uint256 saleAmountQty = (2*saleAmount).divWadDown(initPrice +endPrice); 
        uint256 a = (endPrice - initPrice).divWadDown(saleAmountQty); 
        
        //Set discount cap as saleAmount * sigma 
        (discount_cap, ) = LinearCurve.amountOutGivenIn(saleAmount.mulWadDown(sigma),0, a, initPrice,true ); 
        b = initPrice; 

        // How much total discounts are validators and managers getting
        // managementFee = discount_cap.mulWadDown(endPrice) 
        //     - saleAmount.mulWadDown(sigma) + saleAmountQty.mulWadDown(endPrice) - saleAmount ; 

        // set initial liquidity and price 
        setLiquidity(uint128(precision.divWadDown(a))); 
        setPriceAndPoint(b); 
        setDynamicLiquidity(priceToPoint(endPrice), type(int128).max); 
        setModifyLiqPoint(priceToPoint(endPrice)); 
    }

    /// @notice computes area between the curve and max price for given storage parameters
    function areaBetweenCurveAndMax(uint256 amount) public view returns(uint256){
        (uint256 amountDelta, ) = LinearCurve.amountOutGivenIn(amount, 0, a_initial, b_initial, true); 
        return amountDelta.mulWadDown(maxPrice) - amount; 
    }

    /// @notice mints new zcbs 
    function trustedDiscountedMint(
        address receiver, 
        uint256 amount 
        ) external{
        require(msg.sender == entry, "entryERR"); 

        TradeToken.mint(receiver, amount);
        discountedReserves += amount;
    }


    function trustedBurn(
        address trader, 
        uint256 amount, 
        bool long
        ) external {
        require(msg.sender == entry, "entryERR"); 

        if (long) TradeToken.burn(trader, amount); 
        else s_tradeToken.burn(trader, amount);
    }

    function flush(address flushTo, uint256 amount) external {
        require(msg.sender == controller, "entryERR"); 
        if (amount == type(uint256).max) BaseToken.transfer(flushTo, baseBal()); 
        else BaseToken.transfer(flushTo, amount); 
    }

    /// @notice resets AMM liquidity to 0 and make it ready to be liq provisioned 
    /// by anyone 
    function resetLiq() external{
        require(msg.sender == controller, "entryERR"); 
        setLiquidity(0); 
        amortizeLiq(); 
    }

}
