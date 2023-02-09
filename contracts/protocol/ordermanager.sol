pragma solidity ^0.8.16;
import "../global/types.sol";
import {StorageHandler} from "../global/GlobalStorage.sol"; 
import {Controller} from "./controller.sol"; 
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

contract OrderManager{
	using FixedPointMathLib for uint256; 

	uint256 public constant PRECISION = 1e18; 
	uint256 Id; 
	uint256 public MAXPRICE = 1e18; 
  	uint256 constant priceDelta = 1e16; 

  	StorageHandler public Data; 

  	Controller controller; 
  	address owner; 

  	constructor(address _controller){
  		controller = Controller(_controller); 
  		owner = msg.sender; 
  	}

  	function setDataStore(address dataStore) public {
  		require(msg.sender== address(controller), "unauthorized"); 
    	Data = StorageHandler(dataStore); 
  	}

	event OrderSubmitted(uint256 indexed marketId, uint256 indexed price, address owner, Order order);
  	event OrderFilled(uint256 indexed marketId, uint256 indexed price, Order order, uint256 amount);

  	mapping(bytes32=>uint256[]) idsByPriceAndDir; 
  	mapping(uint256=>Order) ordersById; //orderId-> orderId 

  	/// @notice post assessment function. amountIn is in longZCB or shortZCb
  	function submitOrder(
   	 	uint256 marketId, 
    	uint256 amount, 
    	bool isLong, 
    	uint256 price
    	) public returns(uint256){
  		// TODO conditions : only postassessment, shortzcb, longzcb 
    	CoreMarketData memory market = Data.getMarket(marketId); 
    	Order memory order = Order(isLong, price, amount, Id, msg.sender); 

    	uint256 pullCollateral = isLong? amount.mulWadDown(price): amount.mulWadDown(MAXPRICE - price); 

    	ERC20(market.bondPool.baseToken()).transferFrom(msg.sender, address(controller), amount.mulWadDown(price));

    	ordersById[Id] = order; 
    	idsByPriceAndDir[keccak256(abi.encodePacked(pointToPrice(price), isLong ))].push(Id); 
    	Id++; 

    	emit OrderSubmitted(marketId, price, msg.sender, order); 
    	return Id-1; 
  	}

  	function removeOrder(uint256 marketId, uint256 orderId, uint256 amount ) public {
     	Order memory order = ordersById[orderId]; 
     	require(msg.sender == order.owner, "not submitter");
     	require(amount<= order.amount, "insufficient order amount"); 
    	unchecked{ordersById[orderId].amount -= amount;}
    	controller.redeem_transfer(amount.mulWadDown(order.price), msg.sender, marketId); 
  	}

  	function fillCompleteSingleOrderMint(uint256 marketId, uint256 orderId) public {
    	fillSingleOrderMint(marketId, ordersById[orderId], ordersById[orderId].amount); 
  	}	

	/// @notice fill mutiple orders in a given price 
	function fillMultipleOrders(
		uint256 marketId, 
		uint256 price, 
		uint256 fillAmount, 
		bool fillLong
		) public {
		Order memory order; 
		uint256[] memory ids = idsByPriceAndDir[keccak256(abi.encodePacked(pointToPrice(price), fillLong))]; 
		console.log('id', ids.length); 
		for (uint i=0; i< ids.length; i++){

		  order = ordersById[ids[i]]; 
		  fillSingleOrderMint(marketId, order, min(order.amount, fillAmount) ); 
		  fillAmount = fillAmount> order.amount? fillAmount - order.amount : 0; 

		  if(fillAmount == 0) break; 
		}
	}

	/// @notice When an order is filled for longZCB,
	/// need to mint an equivalent amount of shortZCB and vice versa 
	function fillSingleOrderMint(
		uint256 marketId,
		Order memory order, 
		uint256 fillAmount) internal {
		CoreMarketData memory market = Data.getMarket(marketId); 
		require(order.amount>= fillAmount, "not enough fill liq"); 

		// TODO require maxprice less than order price even if max price changes? 
		uint256 fillerAmount = fillAmount.mulWadDown(MAXPRICE - order.price); 

		ERC20(market.bondPool.baseToken()).transferFrom(msg.sender, address(controller), fillerAmount); // funds should go to the?

		market.bondPool.trustedMint(order.owner, fillAmount, order.isLong); 
		market.bondPool.trustedMint(msg.sender, fillAmount, !order.isLong); 

		ordersById[order.orderId].amount -= fillAmount; 

		emit OrderFilled(marketId, order.price, order, fillAmount); 
	}

	function viewOpenOrdersByPrice(uint256 price, bool isLong) public view returns(uint256[] memory){
		// uint256[] memory id; 
		// return id; 
		return idsByPriceAndDir[keccak256(abi.encodePacked(pointToPrice(price), isLong ))]; 
	}

	function pointToPrice(uint256 point) public pure returns(uint256){
	 	return(uint256(point) * priceDelta); 
	}

	/// @notice will round down to nearest integer 
	function priceToPoint(uint256 price) public pure returns(uint256){
	 	return (price.divWadDown(priceDelta))/PRECISION; 
	}

	function min(uint256 a, uint256 b) internal pure returns (uint256) {
	 	return a <= b ? a : b;
	}

}