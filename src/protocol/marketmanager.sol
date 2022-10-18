pragma solidity ^0.8.4;

import "./owned.sol";
import "./reputationtoken.sol"; 
import {BondingCurve} from "../bonds/bondingcurve.sol";
import {Controller} from "./controller.sol";
import {OwnedERC20} from "../turbo/OwnedShareToken.sol";
//import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import "forge-std/console.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {LinearShortZCB, ShortBondingCurve} from "../bonds/LinearShortZCB.sol"; 
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {VRFConsumerBaseV2} from "../chainlink/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "../chainlink/VRFCoordinatorV2Interface.sol";
import {config} from "./helpers.sol";
import {SyntheticZCBPool} from "../bonds/synthetic.sol"; 

contract MarketManager is Owned
 // VRFConsumerBaseV2 
 {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  // Chainlink state variables
  VRFCoordinatorV2Interface COORDINATOR;
  uint64 private immutable subscriptionId;
  bytes32 private keyHash;
  uint32 private callbackGasLimit = 100000;
  uint16 private requestConfirmations = 3;
  uint256 total_validator_bought; // should be a mapping no?
  bool private _mutex;

  ReputationNFT rep;
  Controller controller;
  CoreMarketData[] public markets;

  mapping(uint256 => uint256) requestToMarketId; // chainlink request id to marketId
  mapping(uint256 => ValidatorData) validator_data; //marketId-> total amount of zcb validators can buy 
  mapping(uint256=> mapping(address=> uint256)) sale_data; //marketId-> total amount of zcb bought
  mapping(uint256=>uint256) private redemption_prices; //redemption price for each market, set when market resolves 
  mapping(uint256=>mapping(address=>uint256)) private assessment_collaterals;  //marketId-> trader->collateralIn
  mapping(uint256=>mapping(address=>uint256)) private assessment_prices; 
  mapping(uint256=>mapping(address=>bool)) private assessment_trader;
  mapping(uint256=>mapping(address=>uint256) ) public assessment_probs; 
  mapping(uint256=> MarketPhaseData) public restriction_data; // market ID => restriction data
  mapping(uint256=> uint256) collateral_pot; // marketID => total collateral recieved
  mapping(uint256=> MarketParameters) private parameters; //marketId-> params
  mapping(uint256=> mapping(address=>bool)) private redeemed; 
  mapping(uint256=>mapping(address=>bool)) isShortZCB; //marketId-> address-> isshortZCB
  mapping(uint256=>mapping(address=>uint256) )assessment_shorts; // short collateral during assessment
  mapping(uint256=> mapping(address=>uint256)) longTrades; 
  mapping(uint256=> mapping(address=>uint256)) shortTrades;
  mapping(uint256=> uint256) public loggedCollaterals;

  struct CoreMarketData {
    SyntheticZCBPool bondPool; 
    ERC20 longZCB;
    ERC20 shortZCB; 
    string description; // instrument description
    uint256 creationTimestamp;
    uint256 resolutionTimestamp;
    uint256 assessmentBound; 
  }

  struct MarketPhaseData {
    bool duringAssessment;
    bool onlyReputable;
    bool resolved;
    bool alive;
    bool atLoss;
    uint256 min_rep_score;
    uint256 base_budget;
  }

  struct ValidatorData{
    uint256 val_cap;// total zcb validators can buy at a discount
    uint256 avg_price; //price the validators can buy zcb at a discount 
    address[] candidates; // possible validators
    mapping(address=>boolean) isCandidate;
    address[] validators;
    uint8 confirmations;
    bool requested; // true if already requested random numbers from array.
    mapping(address => uint256) sales; // amount of zcb bought per validator
    mapping(address => bool) staked; // true if address has staked vt.
    uint256 totalSales; // total amount of zcb bought;
    uint256 totalStaked; // total amount of vault token staked.
    uint256 numApprovedValidators;
    uint256 amount; // amount staked
  }

  /// @param N: upper bound on number of validators chosen.
  /// @param sigma: validators' stake
  /// @param alpha: minimum managers' stake
  /// @param omega: high reputation's stake 
  /// @param delta: Upper and lower bound for price which is added/subtracted from alpha 
  /// @param r:  reputation ranking for onlyRep phase
  /// @param s: senior coefficient; how much senior capital the managers can attract at approval 
  /// @param steak: steak*approved_principal is the staking amount.
  /// param beta: how much volatility managers are absorbing 
  /// param leverage: how much leverage managers can apply 
  /// param base_budget: higher base_budget means lower decentralization, 
  /// @dev omega always <= alpha
  struct MarketParameters{
    uint256 N;
    uint256 sigma; 
    uint256 alpha; 
    uint256 omega;
    uint256 delta; 
    uint256 r;
    uint256 s;
    uint256 steak;
  }

  modifier onlyController(){
    require(address(controller) == msg.sender || msg.sender == owner || msg.sender == address(this), "is not controller"); 
    _;
  }

  modifier onlyControllerOwnerInternal(){
    require(address(controller) == msg.sender || msg.sender == owner || msg.sender == address(this), "is not controller"); 
    _;
  }

  modifier _lock_() {
    require(!_mutex, "ERR_REENTRY");
    _mutex = true;
    _;
    _mutex = false;
  }

  constructor(
    address _creator_address,
    address reputationNFTaddress,  
    address _controllerAddress,
    address _vrfCoordinator, // 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed
    bytes32 _keyHash, // 0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
    uint64 _subscriptionId // 1713, 
  ) 
    Owned(_creator_address) 
    //VRFConsumerBaseV2(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed) 
  {
    rep = ReputationNFT(reputationNFTaddress);
    controller = Controller(_controllerAddress);
    keyHash = bytes32(0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f);
    subscriptionId = 1713;
    COORDINATOR = VRFCoordinatorV2Interface(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed);
    
    // push empty market
    markets.push(
      makeEmptyMarketData()
    );
  }

  function makeEmptyMarketData() public pure returns (CoreMarketData memory) {
    return CoreMarketData(
        SyntheticZCBPool(address(0)),
        ERC20(address(0)),
        ERC20(address(0)),
        "",
        0,
        0, 
        0
      );
  }

  function marketCount() public view returns (uint256) {
    return markets.length;
  }

  function getMarket(uint256 _id) public view returns (CoreMarketData memory) {
    if (_id >= markets.length) {
        return makeEmptyMarketData();
    } else {
        return markets[_id];
    }
  }

  /// @notice parameters have to be set prior 
  function newMarket(
    uint256 marketId, 
    uint256 principal, 
    uint256 expectedYield, 
    SyntheticZCBPool bondPool,  
    address _longZCB, 
    address _shortZCB, 
    string calldata _description, 
    uint256 _creationTimestamp
    ) external onlyController {

    markets.push(CoreMarketData(
      bondPool, 
      ERC20(_longZCB), 
      ERC20(_shortZCB),  
      _description,
      _creationTimestamp,
      0, 
      principal.mulWadDown(parameters[marketId].alpha+ parameters[marketId].delta)
    ));

    uint256 base_budget = 1000 * config.WAD; //TODO 
    setMarketPhase(marketId, true, true, base_budget);
    _setValidatorAmount(marketId, principal);
    _setValidatorCap(marketId, principal); 
    // setUpperBound(marketId, principal.mulWadDown(parameters[marketId].alpha+ parameters[marketId].delta));  
  }

  /*----Phase Functions----*/

  /// @notice list of parameters in this system for each market, should vary for each instrument 
  /// @dev calculates market driven s from utilization rate. If u-r high,  then s should be low, as 1) it disincentivizes 
  /// managers to approving as more proportion of the profit goes to the LP, and 2) disincentivizes the borrower 
  /// to borrow as it lowers approved principal and increases interest rate 
  function setParameters(
    MarketParameters memory param,
    uint256 utilizationRate,
    uint256 marketId 
    ) public onlyControllerOwnerInternal{
    parameters[marketId] = param; 
    parameters[marketId].s = param.s.mulWadDown(config.WAD - utilizationRate); // experiment
  }

  /// @notice sets market phase data
  /// @dev called on market initialization by controller
  /// @param base_budget: base budget (amount of vault tokens to spend) as a market manager during the assessment stage
  function setMarketPhase(
    uint256 marketId, 
    bool duringAssessment,
    bool _onlyReputable,
    uint256 base_budget
    ) public onlyControllerOwnerInternal{
    MarketPhaseData storage data = restriction_data[marketId]; 
    data.onlyReputable = _onlyReputable; 
    data.duringAssessment = duringAssessment;
    data.min_rep_score = calcMinRepScore(marketId);
    data.base_budget = base_budget;
    data.alive = true;
  }

  /// @notice when market is initialized 
  function setUpperBound(
    uint256 marketId, 
    uint256 new_upper_bound
    ) public onlyControllerOwnerInternal {
    markets[marketId].assessmentBound = new_upper_bound;
  }

  /// @notice used to transition from reputationphases 
  function setReputationPhase(
    uint256 marketId,
    bool _onlyReputable
  ) public onlyControllerOwnerInternal {
    require(restriction_data[marketId].alive, "market must be alive");
    restriction_data[marketId].onlyReputable = _onlyReputable;
  }

  /// @notice Called when market should end, a) when denied b) when maturity 
  /// @param resolve is true when instrument does not resolve prematurely
  function deactivateMarket(
    uint256 marketId, 
    bool atLoss, 
    bool resolve) public onlyControllerOwnerInternal{
    restriction_data[marketId].resolved = resolve; 
    restriction_data[marketId].atLoss = atLoss; 
    restriction_data[marketId].alive = false; //TODO alive should be true, => alive is false when everyone has redeemed.
  } 

  /// @notice denies market from validator 
  function denyMarket(
    uint256 marketId
  ) external onlyControllerOwnerInternal {
    require(marketActive(marketId), "Market Not Active"); 
    require(restriction_data[marketId].duringAssessment, "Not in assessment"); 
    MarketPhaseData storage data = restriction_data[marketId]; 
    data.duringAssessment = false;
  }

  /// @notice main approval function called by controller
  /// @dev if market is alive and market is not during assessment, it is approved. 
  function approveMarket(uint256 marketId) public onlyControllerOwnerInternal {
    require(restriction_data[marketId].alive, "phaseERR");
    restriction_data[marketId].duringAssessment = false; 
  }

  /// @notice gets the top percentile reputation score threshold 
  function calcMinRepScore(uint256 marketId) internal view returns(uint256){
    return rep.getMinRepScore(parameters[marketId].r, marketId); 
  }

  function getPhaseData(
    uint256 marketId
  ) public view returns (MarketPhaseData memory)  {
    return restriction_data[marketId];
  }
  
  function getMinRepScore(uint256 marketId) public view returns(uint256){
    return restriction_data[marketId].min_rep_score;
  }
  
  /// @dev verification of trader initializes reputation score at 0, to gain reputation need to participate in markets.
  function isVerified(address trader) public view returns(bool){
    return (controller.isVerified(trader) || trader == owner);
  }

  function isReputable(address trader, uint256 marketId) public view returns(bool){
    return (restriction_data[marketId].min_rep_score <= rep.getReputationScore(trader) || trader == owner); 
  }

  function duringMarketAssessment(uint256 marketId) public view returns(bool){
    return restriction_data[marketId].duringAssessment; 
  }

  function onlyReputable(uint256 marketId) public view returns(bool){
    return restriction_data[marketId].onlyReputable; 
  }

  function isMarketApproved(uint256 marketId) public view returns(bool){
    return(!restriction_data[marketId].duringAssessment && restriction_data[marketId].alive);  
  }

  function marketActive(uint256 marketId) public view returns(bool){
    return restriction_data[marketId].alive; 
  }

  /// @notice returns true if amount bought is greater than the insurance threshold
  function marketCondition(uint256 marketId) public view returns(bool){
    uint256 principal = controller.getVault(marketId).fetchInstrumentData(marketId).principal;
    uint256 total_bought = loggedCollaterals[marketId]; 
    return (total_bought >= principal.mulWadDown(parameters[marketId].alpha)); 
  }

  /// @notice returns whether current market is in phase 
  /// 1: onlyReputable, which also means market is in assessment
  /// 2: not onlyReputable but in asseessment 
  /// 3: in assessment but canbeapproved 
  /// 4: post assessment(accepted or denied), amortized liquidity 
  function getCurrentMarketPhase(uint256 marketId) public view returns(uint256){
    if (onlyReputable(marketId)){
      assert(!marketCondition(marketId) && !isMarketApproved(marketId) && duringMarketAssessment(marketId) ); 
      return 1; 
    }

    else if (duringMarketAssessment(marketId) && !onlyReputable(marketId)){
      assert(!isMarketApproved(marketId)); 
      if (marketCondition(marketId)) return 3; 
      return 2; 
    }

    else if (isMarketApproved( marketId)){
      assert (!duringMarketAssessment(marketId) && marketCondition(marketId)); 
      return 4; 
    }
  }

  /// @notice get trade budget = f(reputation), returns in collateral_dec
  /// sqrt for now
  function getTraderBudget(uint256 marketId, address trader) public view returns(uint256){
    uint256 repscore = rep.getReputationScore(trader); 

    if (repscore==0) return 0; 

    return restriction_data[marketId].base_budget + (repscore*config.WAD).sqrt();
  }
  
  /// @notice computes the price for ZCB one needs to short at to completely
  /// hedge for the case of maximal loss, function of principal and interest
  function getHedgePrice(uint256 marketId) public view returns(uint256){
    uint256 principal = controller.getVault(marketId).fetchInstrumentData(marketId).principal; 
    uint256 yield = controller.getVault(marketId).fetchInstrumentData(marketId).expectedYield; 
    uint256 den = principal.mulWadDown(config.WAD - parameters[marketId].alpha); 
    return config.WAD - yield.divWadDown(den); 
  }

  /// @notice computes maximum amount of quantity that trader can short while being hedged
  /// such that when he loses his loss will be offset by his gains  
  function getHedgeQuantity(address trader, uint256 marketId) public view returns(uint256){
    uint num = controller.getVault(marketId).fetchInstrumentData(marketId)
              .principal.mulWadDown(config.WAD - parameters[marketId].alpha); 
    return num.mulDivDown(controller.getVault(marketId).balanceOf(trader), 
              controller.getVault(marketId).totalSupply()); 
  }

  function getParameters(uint256 marketId) public view returns(MarketParameters memory){
    return parameters[marketId]; 
  }

  function getPool(uint256 marketId) public view returns(SyntheticZCBPool){
    return markets[marketId].bondPool; 
  }

  function getZCB(uint256 marketId) public view returns (ERC20) {
    return markets[marketId].longZCB;
  }

  function getShortZCB(uint256 marketId) public view returns (ERC20) {
    return markets[marketId].shortZCB;
  }
  
  function get_redemption_price(uint256 marketId) public view returns(uint256){
    return redemption_prices[marketId]; 
  }

  /// @notice performs checks for buy function
  /// @param amount: collateral used to buy ZCB.
  function _canBuy(
    address trader,
    int256 amount,
    uint256 marketId
  ) internal view {
    //If after assessment there is a set buy threshold, people can't buy above this threshold
    require(marketActive(marketId), "Market Not Active");

    bool _duringMarketAssessment = duringMarketAssessment(marketId);
    bool _onlyReputable =  onlyReputable(marketId);
    if(amount>0){
      if (_duringMarketAssessment){
        if (!isVerified(trader)) 
          revert("not verified");
        if (loggedCollaterals[marketId] + uint256(amount) >= markets[marketId].assessmentBound) 
          revert("exceeds limit"); 
        if (!(getTraderBudget(marketId, trader)>= uint256(amount) + rep.balances(marketId, trader))) 
          revert("budget limit");
      }
    }

    //During the early risk assessment phase only reputable can buy 
    if (_onlyReputable){
      if (!isReputable(trader, marketId)){ 
        revert("insufficient reputation");
      }
    }
  }

  /// @notice amount is in zcb_amount_in TODO 
  function _canSell(
    address trader,
    uint256 amount, 
    uint256 marketId
  ) internal view returns(bool) {
    require(marketActive(marketId), "Market Not Active");

    // For current onchain conditions, the estimated collateral 
    // trader would obtain should be less than budget  
    // if (!(getTraderBudget(marketId, trader) >= zcb.calculateSaleReturn(amount))) return false; 
    
    return true; 
  }

  /// @notice called when market initialized, calculates the average price and quantities of zcb
  /// validators will buy at a discount when approving
  /// valcap = sigma * princpal.
  function _setValidatorCap(
    uint256 marketId,
    uint256 principal
  ) internal {
    SyntheticZCBPool bondingPool = markets[marketId].bondPool; 
    require(config.isInWad(parameters[marketId].sigma) && config.isInWad(principal), "paramERR");

    uint256 valColCap = (parameters[marketId].sigma.mulWadDown(principal)); 

    // Get how much ZCB validators need to buy in total, which needs to be filled for the market to be approved 
    uint256 discount_cap = bondingPool.discount_cap();
    uint256 avgPrice = valColCap.divWadDown(discount_cap);

    validator_data[marketId].val_cap = discount_cap;
    validator_data[marketId].avg_price = avgPrice; 
  }

  function _setValidatorAmount(uint256 marketId, uint256 principal) internal {
    validator_data[marketId].amount = parameters[marketId].steak.mulWadDown(principal);
  }

  function isValidator(uint256 marketId, address user) view public returns(bool){
    address[] storage _validators = validator_data[marketId].validators;
    for (uint i = 0; i < _validators.length; i++) {
      if (_validators[i] == user) {
        return true;
      }
    }
    return false;
  }

  function _removeValidator(uint256 marketId, address user) internal {
    address[] storage arr = validator_data[marketId].validators;
    uint256 length = arr.length;
    
    for (uint i = 0; i < length; i++) {
      if (user == arr[i]) {
        arr[i] = arr[length - 1];
        arr.pop();
        return;
      }
    }
  }

  /**
   @notice randomly choose validators for market approval, async operation => fulfillRandomness is the callback function.
   @dev called when phase changes onlyRep => false
   */
  function _getValidators(uint256 marketId) internal {

    validator_data[marketId].requested = true;

    //TODO N is currently upper bound on number of validators.
    if (validator_data[marketId].candidates.length <= parameters[marketId].N) {
      validator_data[marketId].validators = validator_data[marketId].candidates;
      return;
    }

    uint256 _requestId = COORDINATOR.requestRandomWords(
      keyHash,
      subscriptionId,
      requestConfirmations,
      callbackGasLimit,
      uint32(parameters[marketId].N)
    );

    requestToMarketId[_requestId] = marketId;
  }

  /**
   @notice chainlink callback function, sets validators.
   */
  function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) 
  internal 
  //override 
  {
    uint256 marketId = requestToMarketId[requestId];
    assert(randomWords.length == parameters[marketId].N);

    address[] memory temp = validator_data[marketId].candidates;
    uint256 _N = parameters[marketId].N;
    uint256 length = _N;
    
    // get validators
    for (uint8 i=0; i<_N; i++) {
      uint256 j = _weightedRetrieve(temp, length, randomWords[i]);
      validator_data[marketId].validators.push(temp[j]);
      temp[j] = temp[length - 1];
      length--;
    }
  }

  function _weightedRetrieve(address[] memory group, uint256 length, uint256 randomWord) view internal returns (uint256) {
    uint256 sum_weights;

    for (uint8 i=0; i<length; i++) {
      sum_weights += rep.getReputationScore(group[i]);
    }

    uint256 tmp = randomWord % sum_weights;

    for (uint8 i=0; i<length; i++) {
      uint256 wt = rep.getReputationScore(group[i]);
      if (tmp < wt) {
        return i;
      }
      unchecked {
        tmp -= wt;
      }
      
    }
    console.log("should never be here");
  }

  function getValidatorRequiredCollateral(uint256 marketId) public view returns(uint256){
    uint256 val_cap =  validator_data[marketId].val_cap; 
    uint256 zcb_for_sale = val_cap/parameters[marketId].N; 
    return zcb_for_sale.mulWadDown(validator_data[marketId].avg_price); 
  }

  function numValidatorLeftToApproval(uint256 marketId) public view returns(uint256){
    return parameters[marketId].N - validator_data[marketId].numApprovedValidators;
  }

  /// @notice allows validators to buy at a discount 
  /// They can only buy a fixed amount of ZCB, usually a at lot larger amount 
  /// @dev get val_cap, the total amount of zcb for sale and each validators should buy 
  /// val_cap/num validators zcb 
  /// They also need to hold the corresponding vault, so they are incentivized to assess at a systemic level and avoid highly 
  /// correlated instruments 
  function validatorBuy(
    uint256 marketId
  ) external  {
    require(marketCondition(marketId), "Market can't be approved"); 
    // require(isValidator(marketId, msg.sender), "Not Validator");
    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    uint256 val_cap =  validator_data[marketId].val_cap; 
    uint256 zcb_for_sale = val_cap/parameters[marketId].N; 
    uint256 collateral_required = zcb_for_sale.mulWadDown(validator_data[marketId].avg_price); 

    require(validator_data[marketId].sales[msg.sender] <= zcb_for_sale, "already approved");

    validator_data[marketId].sales[msg.sender] += zcb_for_sale;
    validator_data[marketId].totalSales += (zcb_for_sale +1);  //since division rounds down 
    validator_data[marketId].numApprovedValidators += 1; 
    loggedCollaterals[marketId] += collateral_required; 

    bondPool.BaseToken().transferFrom(msg.sender, address(bondPool), collateral_required); 
    bondPool.trustedDiscountedMint(msg.sender, zcb_for_sale); 

    // Last validator pays more gas, is fair because earlier validators are more uncertain 
    if (validatorApprovalCondition(marketId)) controller.approveMarket(marketId);
  }

  // function validatorStake(
  //   uint256 marketId
  // ) external {
  //   require(isValidator(marketId, msg.sender), "Caller is not validator for this market");
  //   require(marketCondition(marketId), "Market can't be approved");
  //   // require(!validator_data[marketId].staked[msg.sender], "caller already staked for this market");

  //   // stake vault token to market manager contract.
  //   ERC20(controller.getVaultAd(marketId)).safeTransferFrom(msg.sender, address(this), validator_data[marketId].amount);

  //   validator_data[marketId].totalStaked += validator_data[marketId].amount;
  //   validator_data[marketId].numApprovedValidators ++; // redundant bc of confirmations
  //   validator_data[marketId].confirmations ++;
  //   validator_data[marketId].staked[msg.sender] = true;

  //   if (validatorApprovalCondition(marketId)) {
  //     controller.approveMarket(marketId);
  //   }
  // }

  // function validatorResolution(uint256 marketId) external view returns {
  // }

  function validatorApprovalCondition(uint256 marketId ) public view returns(bool){
    return (validator_data[marketId].totalSales >= validator_data[marketId].val_cap);
    //return (validator_data[marketId].confirmations == validator_data[marketId].validators.length) // approved if number of stakes == number of validators
  }



  /// @notice log how much collateral trader has at stake, 
  /// to be used for redeeming, restricting trades
  function _logTrades(
    uint256 marketId,
    address trader, 
    uint256 collateral,
    uint256 shortCollateral,  
    bool isBuy, 
    bool isLong
    ) internal {

    if (isLong){
      if (isBuy) {
        longTrades[marketId][trader] += collateral; 
        loggedCollaterals[marketId] += collateral; 
      }
      else {
        longTrades[marketId][trader] -= collateral;
        loggedCollaterals[marketId] -= collateral; 
      } 
    }

    else{
      if (isBuy) {
        // shortCollateral is amount trader pays to buy shortZCB
        shortTrades[marketId][trader] += shortCollateral;

        // collateral is the area under the curve that is subtracted due to the (short)selling
        loggedCollaterals[marketId] -= collateral; 
      } 
      else {
        // revert if underflow, which means trader sold short at a profit, which is not allowed during assessment 
        shortTrades[marketId][trader] -= shortCollateral; 
        loggedCollaterals[marketId] += collateral; 
      } 
    }
  }

  /// @notice general limitorder claim + liquidity provision funnels used post-assessment, 
  /// which will be recorded if necessary 
  /// param type: 1 if open long, 2 if close long, 3 if open short, 4 if close short
  /// type 5: partially claim 
  function claimFunnel(
    uint256 marketId, 
    uint16 point, 
    uint256 funnel
    ) external returns(uint256 claimedAmount){
    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    if (funnel == 1) claimedAmount = bondPool.makerClaimOpen(point,true, msg.sender); 
    else if (funnel == 2) claimedAmount = bondPool.makerClaimClose(point,true, msg.sender);
    else if (funnel == 3) claimedAmount = bondPool.makerClaimOpen(point,false, msg.sender); 
    else if (funnel == 4) claimedAmount = bondPool.makerClaimClose(point,false, msg.sender); 
  }

  /// @notice called by pool when buying, transfers funds from trader to pool 
  function tradeCallBack(uint256 amount, bytes calldata data) external{
    SyntheticZCBPool(msg.sender).BaseToken().transferFrom(abi.decode(data, (address)), msg.sender, amount); 
  }

  function deduct_selling_fee() internal {}

  /// @notice main entry point for longZCB buys 
  /// @param _amountIn is negative if specified in zcb quantity
  function buyBond(
    uint256 _marketId, 
    int256 _amountIn, 
    uint256 _priceLimit, 
    bytes calldata _tradeRequestData 
    ) external _lock_ returns(uint256 amountIn, uint256 amountOut){
    require(!restriction_data[_marketId].resolved, "must not be resolved");
    _canBuy(msg.sender, _amountIn, _marketId);

    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    // During assessment, real bonds are issued from utilizer, they are the sole LP 
    if (duringMarketAssessment(_marketId)){
      // Phase Transitions when conditions met
      if(onlyReputable(_marketId)){
        uint256 total_bought = loggedCollaterals[_marketId];

        if(!validator_data[_marketId].isCandidate[msg.sender]) {
          validator_data[_marketId].isCandidate[msg.sender] = true;
          validator_data[_marketId].candidates.push(msg.sender);
        }

        if (total_bought >= parameters[_marketId].omega.mulWadDown(
              controller
              .getVault(_marketId)
              .fetchInstrumentData(_marketId)
              .principal)
        ) {
          restriction_data[_marketId].onlyReputable = false;
          _getValidators(_marketId);
        }
      }
      (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender)); 

      //Need to log assessment trades for updating reputation scores or returning collateral when market denied 
      _logTrades(_marketId, msg.sender, amountIn, 0, true, true);
    }

    // Synthetic bonds are issued (liquidity provision are amortized as counterparties)
    else{
      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if(isTaker)
        (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender));
      else{
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerOpen(point, uint256(_amountIn), true, msg.sender); 
      }
    }
  }

  /// @notice longZCB sells  
  /// @param _amountIn quantity in longZCB 
  function sellBond(
      uint256 _marketId,
      uint256 _amountIn, 
      uint256 _priceLimit, 
      bytes calldata _tradeRequestData 
    ) external _lock_ returns (uint256 amountIn, uint256 amountOut){
    require(!restriction_data[_marketId].resolved, "must not be resolved");
    require(_canSell(msg.sender, _amountIn, _marketId),"Trade Restricted");
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    if (duringMarketAssessment(_marketId)){
      deduct_selling_fee(); //TODO 

      _logTrades(_marketId, msg.sender, amountIn, 0, false, true );                                          

      (amountIn, amountOut) = bondPool.takerClose(
                                    true, int256(_amountIn), _priceLimit, abi.encode(msg.sender));
    }
    else{
      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if(isTaker) (amountIn, amountOut) = bondPool.takerClose(
              true, int256(_amountIn), _priceLimit, abi.encode(msg.sender));
      else {
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerClose(point, uint256(_amountIn), false, msg.sender);        
      }
    }
  } 

  /// _amountIn amount of short trader is willing to buy
  function shortBond(
    uint256 _marketId, 
    uint256 _amountIn, 
    uint256 _priceLimit,
    bytes calldata _tradeRequestData 
    ) external _lock_ returns (uint256 amountIn, uint256 amountOut){
    require(_canSell(msg.sender, _amountIn, _marketId),"Trade Restricted");
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    if (duringMarketAssessment(_marketId)){

      // amountOut is base collateral down the curve, amountIn is collateral used to buy shortZCB 
      (amountOut, amountIn) = bondPool.takerOpen(false, int256(_amountIn), _priceLimit, abi.encode(msg.sender));

      _logTrades(_marketId, msg.sender, amountOut, amountIn, true, false);

      deduct_selling_fee(); 
    }
    else{
      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if (isTaker)
        (amountOut, amountIn) = bondPool.takerOpen(false, int256(_amountIn), _priceLimit, abi.encode(msg.sender));
      
      else{
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerOpen(point, uint256(_amountIn), false, msg.sender);
      }
    }
  }
  /// @param _amountIn is amount of short trader is willing to cover 
  function coverBondShort(
    uint256 _marketId, 
    uint256 _amountIn, 
    uint256 _priceLimit,
    bytes calldata _tradeRequestData 
    ) external _lock_ returns (uint256 amountIn, uint256 amountOut){
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    if (duringMarketAssessment(_marketId)){

      // amountOut is collateral up the curve, amountIn is collateral returned from closing  
      (amountOut, amountIn) = bondPool.takerClose(false, -int256(_amountIn), _priceLimit, abi.encode(msg.sender));

      _logTrades(_marketId, msg.sender, amountOut, amountIn, true, false); 
      deduct_selling_fee(); 
    }
    else{
      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if (isTaker)
        (amountOut, amountIn) = bondPool.takerClose(false, int256(_amountIn), _priceLimit, abi.encode(msg.sender));
      
      else{
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerClose(point, _amountIn, false, msg.sender);
      }
    }
  }


  /// @notice called by traders when market is denied or resolve before maturity 
  function redeemDeniedMarket(
    uint256 marketId, 
    bool isLong
  ) external _lock_ {
    require(!restriction_data[marketId].alive, "Market Still During Assessment"); // TODO
    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    uint256 collateral_amount;
    uint256 balance; 
    // Get collateral at stake in shorts, which will be directly given back to traders
    if(!isLong){
      balance = markets[marketId].shortZCB.balanceOf(msg.sender); 
      require(balance >= 0, "Empty Balance");

      // TODO this means if trader's loss will be refunded if loss was realized before denied market
      collateral_amount = shortTrades[marketId][msg.sender]; 
      delete shortTrades[marketId][msg.sender]; 

      //Burn all their balance
      bondPool.trustedBurn(msg.sender, balance, false);
    } 

    // Get collateral at stake in longs, which will be directly given back to traders
    else {
      balance = markets[marketId].longZCB.balanceOf(msg.sender); 
      require(balance >= 0, "Empty Balance");

      // TODO this means if trader's loss will be refunded if loss was realized before denied market
      if (isValidator(marketId, msg.sender)) {
        collateral_amount = validator_data[marketId].sales[msg.sender].mulWadDown(validator_data[marketId].avg_price);
        delete validator_data[marketId].sales[msg.sender];
      }
      else{
        collateral_amount = longTrades[marketId][msg.sender]; 
        delete longTrades[marketId][msg.sender]; 
      }

      // Burn all their balance 
      bondPool.trustedBurn(msg.sender, balance, true); 
    }

    // Before redeem_transfer is called all funds for this instrument should be back in the vault
    controller.redeem_transfer(collateral_amount, msg.sender, marketId);
    //TODO need to check if last redeemer, so can kill market.
  }

  
  /// @dev Redemption price, as calculated (only once) at maturity,
  /// depends on total_repayed/(principal + predetermined yield)
  /// If total_repayed = 0, redemption price is 0
  /// @param atLoss: defines circumstances where expected returns are higher than actual
  /// @param loss: facevalue - returned amount => non-negative always?
  /// @param extra_gain: any extra yield not factored during assessment. Is 0 yield is as expected
  function update_redemption_price(
    uint256 marketId,
    bool atLoss, 
    uint256 extra_gain, 
    uint256 loss, 
    bool premature
  ) external  onlyController {  
    if (atLoss) assert(extra_gain == 0); 

    uint256 total_supply = markets[marketId].longZCB.totalSupply(); 
    uint256 total_shorts = (extra_gain >0) ?  markets[marketId].shortZCB.totalSupply() :0; 

    if(!atLoss)
      redemption_prices[marketId] = config.WAD + extra_gain.divWadDown(total_supply + total_shorts); 
    
    else {
      if (config.WAD <= loss.divWadDown(total_supply)){
        redemption_prices[marketId] = 0; 
      }
      else {
        redemption_prices[marketId] = config.WAD - loss.divWadDown(total_supply);
      }
    }

    deactivateMarket(marketId, atLoss, !premature); 

    // TODO edgecase redemption price calculations  
  }

  /// @notice trader will redeem entire balance of ZCB
  /// Needs to be called at maturity, market needs to be resolved first(from controller)
  function redeem(
    uint256 marketId
    ) external _lock_ returns(uint256 collateral_redeem_amount){
    require(!marketActive(marketId), "Market Active"); 
    require(restriction_data[marketId].resolved, "Market not resolved"); 
    require(!redeemed[marketId][msg.sender], "Already Redeemed");
    redeemed[marketId][msg.sender] = true; 

    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    if (isValidator(marketId, msg.sender)) delete validator_data[marketId].sales[msg.sender]; 

    uint256 zcb_redeem_amount = markets[marketId].longZCB.balanceOf(msg.sender); 
    uint256 redemption_price = get_redemption_price(marketId); 
    collateral_redeem_amount = redemption_price.mulWadDown(zcb_redeem_amount); 

    if (!isValidator(marketId, msg.sender)) {
      bool increment = redemption_price >= config.WAD? true: false;
      controller.updateReputation(marketId, msg.sender, increment);
    }

    bondPool.trustedBurn(msg.sender, zcb_redeem_amount, true); 
    controller.redeem_transfer(collateral_redeem_amount, msg.sender, marketId); 
  }

  /// @notice called by short buyers when market is resolved  
  function redeemShortZCB(
    uint256 marketId 
    ) external _lock_ returns(uint256 collateral_redeem_amount){
    require(!marketActive(marketId), "Market Active"); 
    require(restriction_data[marketId].resolved, "Market not resolved"); 
    require(!redeemed[marketId][msg.sender], "Already Redeemed");
    redeemed[marketId][msg.sender] = true; 

    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    uint256 shortZCB_redeem_amount = markets[marketId].shortZCB.balanceOf(msg.sender); 
    uint256 long_redemption_price = get_redemption_price(marketId);
    uint256 redemption_price = long_redemption_price >= config.WAD 
                               ? 0 
                               : config.WAD - long_redemption_price; 
    collateral_redeem_amount = redemption_price.mulWadDown(shortZCB_redeem_amount);

    bondPool.trustedBurn(msg.sender, shortZCB_redeem_amount, false); 
    controller.redeem_transfer(collateral_redeem_amount, msg.sender, marketId); 
  }






// ////DEPRECATED
//   /// @notice called by user to repay shorts
//   /// @param close_amount is in of shortZCB, 18dec 
//   function closeShort(
//     uint256 marketId, 
//     uint256 close_amount, 
//     uint256 min_collateral_out
//     ) external _lock_ {


    
//     ShortBondingCurve shortZCB = markets[marketId].short; //ShortBondingCurve(shortZCBs[marketId]);

//     _repayForShort(msg.sender, marketId, close_amount);

//     shortZCB.transferFrom(msg.sender, address(this), close_amount);

//     // This will buy close_amount worth of longZCB to the shortZCB contract 
//     (uint256 returned_collateral, uint256 tokenToBeBurned) = shortZCB.trustedClose(address(this), close_amount, min_collateral_out);  
//      _logTrades(marketId, msg.sender, returned_collateral, false, false); 

//     if(duringMarketAssessment(marketId)){
//       assessment_shorts[marketId][msg.sender] -= returned_collateral;  
//     }

//     // Now burn the contract's bought longZCB imediately  
//     markets[marketId].long.trustedDiscountedBurn(address(shortZCB), tokenToBeBurned);

//     // Return collateral to trader 
//     WrappedCollateral(shortZCB.getCollateral()).redeem(address(this), msg.sender, returned_collateral); 


//   }

//   function _logAssessmentShorts(uint256 marketId, address trader, uint256 collateralIn) internal {
//     assessment_shorts[marketId][trader] += collateralIn; 
//   }
//   /**
//    @param collateralIn: amount of collateral (vt)
//    */
//   function openShort(
//     uint256 marketId,
//     uint256 collateralIn, 
//     uint256 min_amount_out
//   ) external _lock_ {

//     if (duringMarketAssessment(marketId)) assessment_shorts[marketId][trader] += collateralIn;

    
//     //ShortBondingCurve shortZCB = ShortBondingCurve(shortZCBs[marketId]); 
//     ShortBondingCurve shortZCB = markets[marketId].short;
//     WrappedCollateral wCollateral = WrappedCollateral(shortZCB.getCollateral()); 

//     // Mint wCollateral to this address
//     wCollateral.mint(msg.sender, address(this), collateralIn); 
//     wCollateral.approve(address(shortZCB), collateralIn); 

//     // lendAmount: amount of zcb to borrow w/ shortZCB pricing
//     (uint lendAmount, uint c) = shortZCB.calculateAmountGivenSell(collateralIn);
//     _logTrades(marketId, msg.sender, collateralIn, true, false); 

//     // zcb minted to shortzcb contract
//     _lendForShort(msg.sender, marketId, lendAmount);

//     if (duringMarketAssessment(marketId)) deduct_selling_fee(); 

//     shortZCB.trustedShort(address(this), collateralIn, min_amount_out); 

//     shortZCB.transfer(msg.sender, lendAmount); 


//   }

//   /// @notice called when short is being opened, it allows shortZCB contract to 
//   /// "borrow" by minting new ZCB to the shortZCB contract. 
//   /// @dev although minting new zcb is different from borrowing from existing zcb holders, 
//   /// in the context of our bonding curve prediction 
//   /// market this is alllowed since we just dont allow longZCB holders 
//   /// to sell when liquidity dries up   
//   function _lendForShort(
//     address trader, 
//     uint256 marketId, 
//     uint256 requested_zcb
//     ) internal {
//     // BondingCurve zcb = BondingCurve(controller.getZCB_ad(marketId));
//     BondingCurve zcb = markets[marketId].long;

//     // Log debt data 
//     CDP storage cdp = debt_pools[marketId];
//     cdp.collateral_amount[trader] += requested_zcb; 
//     cdp.borrowed_amount[trader] += requested_zcb;  
//     cdp.total_debt += requested_zcb; 
//     cdp.total_collateral += requested_zcb; //only ds 
//     collateral_pot[marketId] += requested_zcb; //Total ds collateral 

//     zcb.trustedDiscountedMint(address(markets[marketId].short), requested_zcb); 
//   }

//    function _repayForShort(
//     address trader, 
//     uint256 marketId, 
//     uint256 repaying_zcb
//     ) internal {
//     // BondingCurve zcb = BondingCurve(controller.getZCB_ad(marketId));
//     BondingCurve zcb = markets[marketId].long;

//     CDP storage cdp = debt_pools[marketId];
//     cdp.collateral_amount[trader] -= repaying_zcb; 
//     cdp.borrowed_amount[trader] -= repaying_zcb; 
//     cdp.total_debt -= repaying_zcb; 
//     cdp.total_collateral -= repaying_zcb; 
//     collateral_pot[marketId] -= repaying_zcb;
//   }
//   function sell(
//       uint256 _marketId,
//       uint256 _zcb_amount_in, 
//       uint256 _min_collateral_out
//     ) external _lock_ returns (uint256 amountOut){
//     require(!restriction_data[_marketId].resolved, "must not be resolved");
//     require(_canSell(msg.sender, 
//       _zcb_amount_in, 
//       _marketId),"Trade Restricted");

//     //BondingCurve zcb = BondingCurve(controller.getZCB_ad(_marketId)); // SOMEHOW GET ZCB
//     BondingCurve zcb = markets[_marketId].long;

//     zcb.transferFrom(msg.sender, address(this), _zcb_amount_in); 

//     // wCollateral to this address
//     amountOut = zcb.trustedSell(address(this), _zcb_amount_in, _min_collateral_out);

//     _logTrades(_marketId, msg.sender, amountOut, false, true); 

//     //Send collateral to trader 
//     WrappedCollateral(zcb.getCollateral()).redeem(address(this), msg.sender, amountOut); 

//     if (!duringMarketAssessment(_marketId)) deduct_selling_fee(); 

//     // queuedRepUpdates[msg.sender] -= 1; 

//   }
//   /// @notice main entry point for longZCB buys
//   /// @param _collateralIn: amount of collateral tokens in WAD
//   /// @param _min_amount_out is min quantity of ZCB returned
//   function buy(
//       uint256 _marketId,
//       uint256 _collateralIn,
//       uint256 _min_amount_out
//     ) external _lock_ returns (uint256 amountOut) {
//     require(!restriction_data[_marketId].resolved, "must not be resolved");
//     _canBuy(msg.sender, _collateralIn, _marketId);

//     // BondingCurve zcb = BondingCurve(controller.getZCB_ad(_marketId)); // SOMEHOW GET ZCB
//     BondingCurve zcb = markets[_marketId].long;
//     WrappedCollateral wCollateral = WrappedCollateral(zcb.getCollateral()); 

//     // Mint wCollateral to this address
//     wCollateral.mint(msg.sender, address(this), _collateralIn); 
//     wCollateral.approve(address(zcb), _collateralIn); 

//     // reentrant locked and trusted contract with no hooks, so ok 
//     // need to set reuputation phase after the trade 
//     amountOut = zcb.trustedBuy(address(this), _collateralIn, _min_amount_out);

//     //Need to log assessment trades for updating reputation scores or returning collateral
//     //when market denied 
//     _logTrades(_marketId, msg.sender, _collateralIn, true, true); 

//     if (duringMarketAssessment(_marketId)){

//       // rep.incrementBalance(_marketId, msg.sender, _collateralIn);

//       // keep track of amount bought during reputation phase
//       // and make transitions from onlyReputation true->false
//       if(onlyReputable(_marketId)){
//         uint256 principal = controller.getVault(_marketId).fetchInstrumentData(_marketId).principal;
//         uint256 total_bought = zcb.getTotalCollateral();

//         // first time rep user buying.
//         if (!assessment_trader[_marketId][msg.sender]) {
//           validator_data[_marketId].candidates.push(msg.sender);
//         }

//         if (total_bought >= parameters[_marketId].omega.mulWadDown(principal)) {
//           setReputationPhase(_marketId, false);
//           _getValidators(_marketId);
//         }
//       }
      
//       assessment_probs[_marketId][msg.sender] =  zcb.calcImpliedProbability(
//           _collateralIn, 
//           getTraderBudget(_marketId, msg.sender) 
//       ); 
  
//       }

//     zcb.transfer(msg.sender, amountOut); 


//   }
//     /// @notice setup for long and short ZCBs.
//   function setCurves(
//     uint256 marketId
//   ) internal {
//     markets[marketId].longZCB.setShortZCB(address(markets[marketId].short));
//   }
//   /// @notice During assessment phase, need to log the trader's 
//   /// total collateral when he bought zcb. Trader can only redeem collateral in 
//   /// when market is not approved 
//   function _logAssessmentTrade(
//     uint256 marketId, 
//     address trader, 
//     uint256 collateralIn,
//     uint256 probability
//     )
//     internal 
//   { 
//     assessment_trader[marketId][trader] = true; 
//     assessment_collaterals[marketId][trader] += collateralIn;
//     assessment_probs[marketId][trader] = probability; 

//     // queuedRepUpdates[msg.sender] += 1; 

//   }
//   struct CDP{
//     mapping(address=>uint256) collateral_amount;
//     mapping(address=>uint256) borrowed_amount; 
//     uint256 total_debt; 
//     uint256 total_collateral;
//   }
//   /// @notice called by controller when market is approved
//   function setLowerBound(
//     uint256 marketId, 
//     uint256 new_lower_bound
//     ) private {
//     // BondingCurve(controller.getZCB_ad(marketId)).setLowerBound(new_lower_bound);
//     markets[marketId].long.setLowerBound(new_lower_bound);
//   }
//   /// @notice main approval function called by controller
//   /// @dev if market is alive and market is not during assessment, it is approved. 
//   function approveMarket( uint256 marketId) external onlyControllerOwnerInternal {
//     require(restriction_data[marketId].alive, "phaseERR");
//     restriction_data[marketId].duringAssessment = false; 
//   }

//   function getDebtPosition(address trader, uint256 marketId) public view returns(uint256, uint256){
//     CDP storage cdp = debt_pools[marketId];
//     return (cdp.collateral_amount[trader], cdp.borrowed_amount[trader]);
//   }
}

/// @notice simple wrapped collateral to be used in markets instead of 
/// collateral, so that collateral used to buy bonds during assessment 
// /// is used for lending Redeemable for collateral one to one 
// contract WrappedCollateral is OwnedERC20 {

//   ERC20 collateral; 
//   uint256 dec_dif; 
//   constructor (
//       string memory name,
//       string memory symbol,
//       address owner, 
//       address _collateral
//       ) OwnedERC20(name, symbol, owner) {
//       collateral = ERC20(_collateral);

//       // collateral_dec = collateral.decimals();
//       collateral.approve(owner, type(uint256).max); 

//       dec_dif = decimals() - collateral.decimals(); //12 for USDC, 0 for 18
//     }

//   /// @notice called when buying 
//   /// @param _amount is always in 18 
//   function mint(address _from, address _target, uint256 _amount) external {
//     uint256 amount = _amount/(10**dec_dif); 
//     collateral.transferFrom(_from, address(this), amount); 
//     _mint(_target, _amount); 
//   }

//   /// @notice called when selling 
//   function redeem(address _from, address _target, uint256 _amount) external {
//     uint256 amount = _amount/(10**dec_dif); 

//     _burn(_from, _amount); 
//     collateral.transfer(_target, amount); 
//   }

//   function trustedTransfer(address _target, uint256 _amount) external {
//     require(msg.sender == owner, "Not owner"); 
//     uint256 amount = _amount/(10**dec_dif); 
//     collateral.transfer(_target, amount); 
//   }

//   function flush(address flushTo) external onlyOwner{

//     collateral.transfer(flushTo, collateral.balanceOf(address(this))); 
//   }

// }

