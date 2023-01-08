pragma solidity ^0.8.16;

import "./reputationtoken.sol"; 
import {Controller} from "./controller.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import "forge-std/console.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {VRFConsumerBaseV2} from "../chainlink/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "../chainlink/VRFCoordinatorV2Interface.sol";
import {config} from "../utils/helpers.sol";
import {SyntheticZCBPool} from "../bonds/synthetic.sol"; 
import {ERC4626} from "../vaults/mixins/ERC4626.sol";
import {Vault} from "../vaults/vault.sol"; 
import {ReputationManager} from "./reputationmanager.sol"; 

contract MarketManager 
 // VRFConsumerBaseV2 
 {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  // Chainlink state variables
  // VRFCoordinatorV2Interface COORDINATOR;
  // uint64 private immutable subscriptionId;
  // bytes32 private keyHash;
  // uint32 private callbackGasLimit = 100000;
  // uint16 private requestConfirmations = 3;
  // uint256 total_validator_bought; // should be a mapping no?
  bool private _mutex;

  // ReputationNFT repToken;
  Controller controller;
  ReputationManager reputationManager; 
  CoreMarketData[] public markets;
  address public owner; 

  // mapping(uint256 => uint256) requestToMarketId; // chainlink request id to marketId
  // mapping(uint256 => ValidatorData) validator_data;
  mapping(uint256=>uint256) public redemption_prices; //redemption price for each market, set when market resolves 
  mapping(uint256=>mapping(address=>uint256)) private assessment_prices; 
  mapping(uint256=>mapping(address=>bool)) private assessment_trader;
  mapping(uint256=>mapping(address=>uint256) ) public assessment_probs; 
  mapping(uint256=> MarketPhaseData) public restriction_data; // market ID => restriction data
  mapping(uint256=> MarketParameters) public parameters; //marketId-> params
  mapping(uint256=> mapping(address=>bool)) private redeemed; 
  mapping(uint256=> mapping(address=>uint256)) public longTrades; 
  mapping(uint256=> mapping(address=>uint256)) public shortTrades;
  mapping(uint256=> uint256) public loggedCollaterals;

  struct CoreMarketData {
    SyntheticZCBPool bondPool; 
    ERC20 longZCB;
    ERC20 shortZCB; 
    string description; // instrument description
    uint256 creationTimestamp;
    uint256 resolutionTimestamp;
    bool isPool; 
  }

  struct MarketPhaseData {
    bool duringAssessment;
    bool onlyReputable;
    bool resolved;
    bool alive;
    bool atLoss;
    // uint256 min_rep_score;
    uint256 base_budget;
  }

  /// @param N: upper bound on number of validators chosen.
  /// @param sigma: validators' stake
  /// @param alpha: minimum managers' stake
  /// @param omega: high reputation's stake 
  /// @param delta: Upper and lower bound for price which is added/subtracted from alpha 
  /// @param r: reputation percentile for reputation constraint phase
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
    require(address(controller) == msg.sender || msg.sender == owner || msg.sender == address(this), "!controller"); 
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
    address _controllerAddress,
    address _vrfCoordinator, // 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed
    bytes32 _keyHash, // 0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
    uint64 _subscriptionId // 1713, 
  ) 
    //VRFConsumerBaseV2(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed) 
  {
    controller = Controller(_controllerAddress);
    // keyHash = bytes32(0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f);
    // subscriptionId = 1713;
    // COORDINATOR = VRFCoordinatorV2Interface(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed);
    
    // push empty market
    markets.push(
      makeEmptyMarketData()
    );

    owner = msg.sender; 
  }
//TODO setcontroller
  function makeEmptyMarketData() public pure returns (CoreMarketData memory) {
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
  event MarketCreated(uint256 indexed marketId, address bondPool, address longZCB, address shortZCB, string description, bool isPool);

  function newMarket(
    uint256 marketId,
    SyntheticZCBPool bondPool,  
    address _longZCB, 
    address _shortZCB, 
    string calldata _description, 
    // uint256 _duration, 
    bool isPool
    ) external onlyController {
    uint256 creationTimestamp = block.timestamp;
    
    emit MarketCreated(marketId, address(bondPool), _longZCB, _shortZCB, _description, isPool);

    markets.push(CoreMarketData(
      bondPool, 
      ERC20(_longZCB),
      ERC20(_shortZCB),  
      _description,
      creationTimestamp,
      0, //TODO resolution timestamp, 
      isPool 
    ));

    uint256 base_budget = 1000 * config.WAD; //TODO 
    setMarketPhase(marketId, true, true, base_budget);

   // _validatorSetup(marketId, principal, creationTimestamp, _duration, isPool);
  }


  /*----Phase Functions----*/

  event MarketParametersSet(uint256 indexed marketId, MarketParameters params);
  /// @notice list of parameters in this system for each market, should vary for each instrument 
  /// @dev calculates market driven s from utilization rate. If u-r high,  then s should be low, as 1) it disincentivizes 
  /// managers to approving as more proportion of the profit goes to the LP, and 2) disincentivizes the borrower 
  /// to borrow as it lowers approved principal and increases interest rate 
  function setParameters(
    MarketParameters memory param,
    uint256 utilizationRate,
    uint256 marketId 
    ) public onlyController{
    parameters[marketId] = param; 
    parameters[marketId].s = param.s.mulWadDown(config.WAD - utilizationRate); // experiment
    emit MarketParametersSet(marketId, param);
  }

  function setReputationManager(address _reputationManager) external onlyController{
      reputationManager = ReputationManager(_reputationManager);
  }

  /**
   @dev in the event that the number of traders in X percentile is less than the specified number of validators
   parameter N is changed to reflect this
   */
  function setN(uint256 marketId, uint256 _N) external onlyController {
    parameters[marketId].N = _N;
  }

event MarketPhaseSet(uint256 indexed marketId, bool duringAssessment, bool onlyReputable, uint256 base_budget);

  /// @notice sets market phase data
  /// @dev called on market initialization by controller
  /// @param base_budget: base budget (amount of vault tokens to spend) as a market manager during the assessment stage
  function setMarketPhase(
    uint256 marketId, 
    bool duringAssessment,
    bool _onlyReputable,
    uint256 base_budget
    ) public onlyController{
    MarketPhaseData storage data = restriction_data[marketId]; 
    data.onlyReputable = _onlyReputable; 
    data.duringAssessment = duringAssessment;
    // data.min_rep_score = calcMinRepScore(marketId);
    data.base_budget = base_budget;
    data.alive = true;
    emit MarketPhaseSet(marketId, duringAssessment, _onlyReputable, base_budget);
  }

  event MarketReputationSet(uint256 indexed marketId, bool onlyReputable);

  /// @notice used to transition from reputationphases 
  function setReputationPhase(
    uint256 marketId,
    bool _onlyReputable
  ) public onlyController {
    restriction_data[marketId].onlyReputable = _onlyReputable;
    emit MarketReputationSet(marketId, _onlyReputable);
  }


event DeactivatedMarket(uint256 indexed marketId, bool atLoss, bool resolve, uint256 rp);
  /// @notice Called when market resolves 
  /// @param resolve is true when instrument does not resolve prematurely
  function deactivateMarket(
    uint256 marketId, 
    bool atLoss, 
    bool resolve, 
    uint256 rp) public onlyController{
    restriction_data[marketId].resolved = resolve; 
    restriction_data[marketId].atLoss = atLoss; 
    restriction_data[marketId].alive = false;
    redemption_prices[marketId] = rp; 
    emit DeactivatedMarket(marketId, atLoss, resolve, rp);
  } 

event MarketDenied(uint256 indexed marketId); 

  /// @notice called by validator only
  function denyMarket(
    uint256 marketId
  ) external onlyController {
    //TODO should validators be able to deny even though they've approved.
    require(restriction_data[marketId].duringAssessment, "!assessment");
    MarketPhaseData storage data = restriction_data[marketId]; 
    data.alive = false;
    data.resolved = true;
    emit MarketDenied(marketId);
  }

  event MarketApproved(uint256 indexed marketId);
  /// @notice main approval function called by controller
  /// @dev if market is alive and market is not during assessment, it is approved. 
  function approveMarket(uint256 marketId) onlyController external {
    restriction_data[marketId].duringAssessment = false;    
    emit MarketApproved(marketId);
  }

  function getPhaseData(
    uint256 marketId
  ) public view returns (MarketPhaseData memory)  {
    return restriction_data[marketId];
  }

  

  function isMarketApproved(uint256 marketId) public view returns(bool){
    return(!restriction_data[marketId].duringAssessment && restriction_data[marketId].alive);  
  }



  /// @notice returns whether current market is in phase 
  /// 1: onlyReputable, which also means market is in assessment
  /// 2: not onlyReputable but in asseessment 
  /// 3: in assessment but canbeapproved 
  /// 4: post assessment(accepted or denied), amortized liquidity 
  function getCurrentMarketPhase(uint256 marketId) public view returns(uint256){
    if (restriction_data[marketId].onlyReputable){
      // assert(!controller.marketCondition(marketId) && !isMarketApproved(marketId) && restriction_data[marketId].duringAssessment ); 
      return 1; 
    }

    else if (restriction_data[marketId].duringAssessment && !restriction_data[marketId].onlyReputable){
      // assert(!isMarketApproved(marketId)); 
      if (controller.marketCondition(marketId)) return 3; 
      return 2; 
    }

    else if (isMarketApproved( marketId)){
      // assert (!restriction_data[marketId].duringAssessment && controller.marketCondition(marketId)); 
      return 4; 
    }
  }

  /// @notice get trade budget = f(reputation), returns in collateral_dec
  /// sqrt for now
  function getTraderBudget(uint256 marketId, address trader) public view returns(uint256){
    uint256 repscore = reputationManager.trader_scores(trader);
    if (repscore==0) return 0;
    return restriction_data[marketId].base_budget + (repscore*config.WAD).sqrt();
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
  

  /// @notice whether new longZCB can be issued 
  function _canIssue(
    address trader,
    int256 amount,
    uint256 marketId
    ) internal view {
    //TODO per market queue 
    //if(queuedRepUpdates[trader] > queuedRepThreshold)
    //  revert("rep queue"); 

    // if (!controller.isVerified(trader)) 
    //   revert("!verified");

    if (getTraderBudget(marketId, trader) <= uint256(amount))
      revert("budget");

    if (controller.getTraderScore(trader) == 0)
      revert("!rep"); 
  }

  /// @notice performs checks for buy function
  /// @param amount: collateral used to buy ZCB.
  function _canBuy(
    address trader,
    int256 amount,
    uint256 marketId
  ) internal view {
    //If after assessment there is a set buy threshold, people can't buy above this threshold
    require(restriction_data[marketId].alive, "!Active");
    // TODO: upper bound 
    // TODO: check if this is correct
    // require(controller.getVault(marketId).fetchInstrumentData(marketId).maturityDate > block.timestamp, "market maturity reached");
    // TODO: check if enough liquidity 
    bool _duringMarketAssessment = restriction_data[marketId].duringAssessment;
    bool _onlyReputable =  restriction_data[marketId].onlyReputable;

    if(amount>0){
      if (_duringMarketAssessment){
        _canIssue(trader, amount, marketId); 
      }
    }

    //During the early risk assessment phase only reputable can buy 
    if (_onlyReputable){
      if (!controller.isReputable(trader, parameters[marketId].r)){
        revert("insufficient rep");
      }
    }
  }

  /// @notice amount is in zcb_amount_in TODO 
  function _canSell(
    address trader,
    uint256 amount, 
    uint256 marketId
  ) internal view returns(bool) {
    require(restriction_data[marketId].alive, "!Active");

    //TODO: check if this is correct
    // require(controller.getVault(marketId).fetchInstrumentData(marketId).maturityDate > block.timestamp, "market maturity reached");

    if(restriction_data[marketId].duringAssessment) {
      // restrict attacking via disapproving the utilizer by just shorting a bunch
     // if(amount>= hedgeAmount) return false; 

      //else return true;
    }
    else{
      // restrict naked CDS amount
      
      // 
    } 

    return true; 
  }

  // VALIDATOR FUNCTIONS

  /**
   @notice called when the validator votes to approve the market => stakes vt + recieves discounted ZCB
   the staked amount goes to the controller while the discounted ZCB goes to the market manager.
   */
  function validatorApprove(
    uint256 marketId, 
    uint256 collateral_required,
    uint256 zcb_for_sale,
    address validator
  ) external onlyController {
    loggedCollaterals[marketId] += collateral_required;
    SyntheticZCBPool bondPool = getPool(marketId); 
    bondPool.BaseToken().transferFrom(validator, address(bondPool), collateral_required); 
    bondPool.trustedDiscountedMint(validator, zcb_for_sale);
  }


  event MarketCollateralUpdate(uint256 marketId, uint256 totalCollateral);
  event TraderLongCollateralUpdate(uint256 marketId, address manager, uint256 totalCollateral);
  event TraderShortCollateralUpdate(uint256 marketId, address manager, uint256 totalCollateral);
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
      // TODO queuerep needs to be per market 
      // If buying bond during assessment, trader is manager, so should update 
      if (isBuy) {
        longTrades[marketId][trader] += collateral; 
        loggedCollaterals[marketId] += collateral; 
        queuedRepUpdates[trader] += 1; 
        } else {
        longTrades[marketId][trader] -= collateral;
        loggedCollaterals[marketId] -= collateral; 
        }
        emit TraderLongCollateralUpdate(marketId, trader, longTrades[marketId][trader]);
      } else{
      if (isBuy) {
        // shortCollateral is amount trader pays to buy shortZCB
        shortTrades[marketId][trader] += shortCollateral;

        // collateral is the area under the curve that is subtracted due to the (short)selling
        loggedCollaterals[marketId] -= collateral; 
        } else {
        // revert if underflow, which means trader sold short at a profit, which is not allowed during assessment 
        shortTrades[marketId][trader] -= shortCollateral; 
        loggedCollaterals[marketId] += collateral;
      } 
      emit TraderShortCollateralUpdate(marketId, trader, shortTrades[marketId][trader]);
    }
    emit MarketCollateralUpdate(marketId, loggedCollaterals[marketId]);
  }

  /// @notice general limitorder claim + liquidity provision funnels used post-assessment, 
  /// which will be recorded if necessary 
  /// param type: 1 if open long, 2 if close long, 3 if open short, 4 if close short
  /// type 5: partially claim , TODO do all possible trading functions 
  function claimFunnel(
    uint256 marketId, 
    uint16 point, 
    uint256 funnel
    ) external returns(uint256 claimedAmount){
    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    // if (funnel == 1) claimedAmount = bondPool.makerClaimOpen(point,true, msg.sender); 
    // else if (funnel == 2) claimedAmount = bondPool.makerClaimClose(point,true, msg.sender);
    // else if (funnel == 3) claimedAmount = bondPool.makerClaimOpen(point,false, msg.sender); 
    // else if (funnel == 4) claimedAmount = bondPool.makerClaimClose(point,false, msg.sender); 
  }

  /// @notice called by pool when buying, transfers funds from trader to pool 
  function tradeCallBack(uint256 amount, bytes calldata data) external{
    SyntheticZCBPool(msg.sender).BaseToken().transferFrom(abi.decode(data, (address)), msg.sender, amount); 
  }



  /// @notice after assessment, let managers buy newly issued longZCB if the instrument is pool based 
  /// funds + funds * levFactor will be directed to the instrument 
  function issuePoolBond(
    uint256 _marketId, 
    uint256 _amountIn
    ) external _lock_ returns(uint256 issueQTY){
    require(!restriction_data[_marketId].duringAssessment, "Pre Approval"); 
    // TODO doesn't work for first approved, and 1 
    _canIssue(msg.sender, int256(_amountIn), _marketId);  
    Vault vault = controller.getVault(_marketId); 
    ERC20 underlying = ERC20(address(markets[_marketId].bondPool.BaseToken())); 

    // Get price and sell longZCB with this price
    (uint256 psu, uint256 pju, uint256 levFactor ) = vault.poolZCBValue(_marketId);

    underlying.transferFrom(msg.sender, address(this), _amountIn);
    // underlying.approve(address(vault.Instruments(_marketId)), _amountIn); 
    // vault.Instruments(_marketId).pullRawFunds(_amountIn); 

    issueQTY = _amountIn.divWadDown(pju); 
    markets[_marketId].bondPool.trustedDiscountedMint(msg.sender, issueQTY); 

    // Need to transfer funds automatically to the instrument, seniorAmount is longZCB * levFactor * psu  
    vault.depositIntoInstrument(_marketId, issueQTY.mulWadDown(config.WAD + levFactor).mulWadDown(psu), true); 
    console.log('how much??', issueQTY.mulWadDown(levFactor).mulWadDown(psu)); 
    //TODO Need totalAssets and exchange rate to remain same assertion 

    reputationManager.recordPull(msg.sender, _marketId, issueQTY,
       _amountIn, getTraderBudget( _marketId, msg.sender), true); 
      
  }

  /// @notice when a manager redeems a poollongzcb, redeemAmount*levFactor are automatically 
  /// withdrawn from the instrument
  function redeemPoolLongZCB(
    uint256 marketId, 
    uint256 redeemAmount
    ) external _lock_ returns(uint256 collateral_redeem_amount, uint256 seniorAmount){
    // TODO conditions/restrictions-> need some time to pass to call this + need some liquidity in pool 
    Vault vault = controller.getVault(marketId); 
    CoreMarketData memory market = markets[marketId]; 

    require(market.isPool, "!pool"); 
    require(market.longZCB.balanceOf(msg.sender) >= redeemAmount, "insufficient bal"); 

    (uint256 psu, uint256 pju, uint256 levFactor ) = vault.poolZCBValue(marketId);
    collateral_redeem_amount = pju.mulWadDown(redeemAmount); 
    seniorAmount = redeemAmount.mulWadDown(levFactor).mulWadDown(psu); 

    // Need to check if redeemAmount*levFactor can be withdrawn from the pool and do so
    vault.withdrawFromPoolInstrument(marketId, collateral_redeem_amount, msg.sender, seniorAmount); 

    // Update reputation 
    reputationManager.recordPush(msg.sender, marketId, pju, false, redeemAmount); 

    // This means that the sender is a manager
    if (queuedRepUpdates[msg.sender] > 0){
     unchecked{queuedRepUpdates[msg.sender] -= 1;} 
    }
    market.bondPool.trustedBurn(msg.sender, redeemAmount, true); 

    // TODO assert pju stays same 
    // TODO assert need totalAssets and exchange rate to remain same 
  }

  mapping(address => uint8) public queuedRepUpdates; 
  uint8 public constant queuedRepThreshold = 3; // at most 3 simultaneous assessment per manager

  event BondBuy(uint256 indexed marketId, address indexed trader, uint256 amountIn, uint256 amountOut);
  /// @notice main entry point for longZCB buys 
  /// @param _amountIn is negative if specified in zcb quantity
  function buyBond(
    uint256 _marketId, 
    int256 _amountIn, 
    uint256 _priceLimit, 
    bytes calldata _tradeRequestData 
    ) external _lock_ returns(uint256 amountIn, uint256 amountOut){
    require(!restriction_data[_marketId].resolved, "!resolved");
    _canBuy(msg.sender, _amountIn, _marketId);
    //TODO return readable error on why it reverts
    CoreMarketData memory marketData = markets[_marketId]; 
    SyntheticZCBPool bondPool = marketData.bondPool; 
    
    // During assessment, real bonds are issued from utilizer, they are the sole LP 
    if (restriction_data[_marketId].duringAssessment){

      (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender)); 
      //Need to log assessment trades for updating reputation scores or returning collateral when market denied 
      _logTrades(_marketId, msg.sender, amountIn, 0, true, true);

      // Get implied probability estimates by summing up all this manager bought for this market 
      reputationManager.recordPull(msg.sender, _marketId, amountOut,
        amountIn, getTraderBudget(_marketId, msg.sender), marketData.isPool); 

      // assessment_probs[_marketId][msg.sender] = controller.calcImpliedProbability(
      //     getZCB(_marketId).balanceOf(msg.sender) + leveragePosition[_marketId][msg.sender].amount, 
      //     longTrades[_marketId][msg.sender], 
      //     getTraderBudget(_marketId, msg.sender) 
      // ); 

      // Phase Transitions when conditions met
      if(restriction_data[_marketId].onlyReputable){
        uint256 total_bought = loggedCollaterals[_marketId];

        if (total_bought >= parameters[_marketId].omega.mulWadDown(
              controller
              .getVault(_marketId)
              .fetchInstrumentData(_marketId)
              .principal)
        ) {
          restriction_data[_marketId].onlyReputable = false;
          emit MarketPhaseSet(_marketId, restriction_data[_marketId].duringAssessment, restriction_data[_marketId].onlyReputable, getTraderBudget(_marketId, msg.sender));
        }
      }
    }

    // Synthetic bonds are issued (liquidity provision are amortized as counterparties)
    else{
      (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender));

      // TODO check if valid slippage 
      // TODO check liquidity, revert if not
      // TODO reputation while trading post assessment? 
      // (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      // if(isTaker)

      //   (amountIn, amountOut) = bondPool.takerOpen(true, _amountIn, _priceLimit, abi.encode(msg.sender));
      // else{
      //   (uint256 escrowAmount, uint128 crossId) = bondPool.makerOpen(point, uint256(_amountIn), true, msg.sender); 
      // }
    }
    emit BondBuy(_marketId, msg.sender, amountIn, amountOut); // get current price as well.
  }

  
  /// @notice longZCB sells  
  /// @param _amountIn quantity in longZCB 
  function sellBond(
      uint256 _marketId,
      uint256 _amountIn, 
      uint256 _priceLimit, 
      bytes calldata _tradeRequestData 
    ) external _lock_ returns (uint256 amountIn, uint256 amountOut){
    // if (duringMarketAssessment(_marketId)) revert("can't close during assessment"); 
    require(!restriction_data[_marketId].resolved, "!resolved");
    require(_canSell(msg.sender, _amountIn, _marketId),"Restricted");
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    if (restriction_data[_marketId].duringAssessment){

      (amountIn, amountOut) = bondPool.takerClose(
                                    true, int256(_amountIn), _priceLimit, abi.encode(msg.sender));

      _logTrades(_marketId, msg.sender, amountIn, 0, false, true );                                          

    }
    else{
      controller.deduct_selling_fee( _marketId ); //TODO, if validator or manager, deduct reputation 

      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if(isTaker) (amountIn, amountOut) = bondPool.takerClose(
              true, int256(_amountIn), _priceLimit, abi.encode(msg.sender));
      else {
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerClose(point, uint256(_amountIn), true, msg.sender);        
      }
    }

    reputationManager.recordPush(msg.sender, _marketId, bondPool.getCurPrice(), true, amountIn); 

  } 

  /// @param _amountIn: amount of short trader is willing to buy
  /// @param _priceLimit: slippage tolerance on trade
  function shortBond(
    uint256 _marketId,
    uint256 _amountIn, 
    uint256 _priceLimit,
    bytes calldata _tradeRequestData 
    ) external _lock_ returns (uint256 amountIn, uint256 amountOut){
    require(_canSell(msg.sender, _amountIn, _marketId),"Restricted");
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    if (restriction_data[_marketId].duringAssessment){

      // amountOut is base collateral down the curve, amountIn is collateral used to buy shortZCB 
      (amountOut, amountIn) = bondPool.takerOpen(false, int256(_amountIn), _priceLimit, abi.encode(msg.sender));

      _logTrades(_marketId, msg.sender, amountOut, amountIn, true, false);

    }
    else{
      //deduct_selling_fee(); //if naked CDS( staked vault)

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

    if (restriction_data[_marketId].duringAssessment){

      // amountOut is collateral up the curve, amountIn is collateral returned from closing  
      (amountOut, amountIn) = bondPool.takerClose(false, -int256(_amountIn), _priceLimit, abi.encode(msg.sender));

      _logTrades(_marketId, msg.sender, amountOut, amountIn, true, false); 
     // deduct_selling_fee(); 
    }
    else{
      (uint16 point, bool isTaker) = abi.decode(_tradeRequestData, (uint16,bool ));
      if (isTaker)
        (amountOut, amountIn) = bondPool.takerClose(false, -int256(_amountIn), _priceLimit, abi.encode(msg.sender));
      
      else{
        (uint256 escrowAmount, uint128 crossId) = bondPool.makerClose(point, _amountIn, false, msg.sender);
      }
    }
  }

  event RedeemDenied(uint256 marketId, address trader, bool isLong);

  /// @notice called by traders when market is denied before approval TODO
  /// ??? if the market is denied, this function is called and everything is redeemed 
  /// validator will need to call this on denial + isLong = true to redeem their collateral.
  function redeemDeniedMarket(
    uint256 marketId, 
    bool isLong
  ) external _lock_ {
    require(!restriction_data[marketId].alive, "Market Still During Assessment"); // TODO
    require(restriction_data[marketId].duringAssessment, "Market has been approved");
    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    uint256 collateral_amount;
    uint256 balance; 
    // Get collateral at stake in shorts, which will be directly given back to traders
    if(!isLong){
      balance = markets[marketId].shortZCB.balanceOf(msg.sender); 
      require(balance >= 0, "Empty");

      // TODO this means if trader's loss will be refunded if loss was realized before denied market
      collateral_amount = shortTrades[marketId][msg.sender]; 
      delete shortTrades[marketId][msg.sender]; 
      emit RedeemDenied(marketId, msg.sender, false);

      //Burn all their balance
      bondPool.trustedBurn(msg.sender, balance, false);
    } 

    // Get collateral at stake in longs, which will be directly given back to traders
    else {
      balance = markets[marketId].longZCB.balanceOf(msg.sender); 
      require(balance >= 0, "Empty");

      // TODO this means if trader's loss will be refunded if loss was realized before denied market
      if (controller.isValidator(marketId, msg.sender) && controller.hasApproved(marketId, msg.sender)) {
        collateral_amount = controller.deniedValidator(marketId, msg.sender);
      }
      else{
        collateral_amount = longTrades[marketId][msg.sender]; 
        delete longTrades[marketId][msg.sender]; 
        emit RedeemDenied(marketId, msg.sender, true);
      }

      // Burn all their balance 
      bondPool.trustedBurn(msg.sender, balance, true); 
      
      // This means that the sender is a manager
      if (queuedRepUpdates[msg.sender] > 0){
        unchecked{queuedRepUpdates[msg.sender] -= 1;} 
      }    
    }

    // Before redeem_transfer is called all funds for this instrument should be back in the vault
    controller.redeem_transfer(collateral_amount, msg.sender, marketId);
    //TODO need to check if last redeemer, so can kill market.
  }

  /// @notice trader will redeem entire balance of ZCB
  /// Needs to be called at maturity, market needs to be resolved first(from controller)
  function redeem(
    uint256 marketId
    ) external _lock_ returns(uint256 collateral_redeem_amount){
    require(!restriction_data[marketId].alive, "!Active"); 
    require(restriction_data[marketId].resolved, "!resolved"); 
    require(!redeemed[marketId][msg.sender], "Redeemed");
    redeemed[marketId][msg.sender] = true; 

    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    if (controller.isValidator(marketId, msg.sender)) controller.redeemValidator(marketId, msg.sender);

    uint256 zcb_redeem_amount = markets[marketId].longZCB.balanceOf(msg.sender); 
    uint256 redemption_price = redemption_prices[marketId]; 
    collateral_redeem_amount = redemption_price.mulWadDown(zcb_redeem_amount); 

    if (!controller.isValidator(marketId, msg.sender)) { // TODO should validators get reputation if they do ok.
      reputationManager.recordPush(msg.sender, marketId, redemption_price, false, zcb_redeem_amount); 
    }

    // This means that the sender is a manager
    if (queuedRepUpdates[msg.sender] > 0){
     unchecked{queuedRepUpdates[msg.sender] -= 1;} 
   }

    bondPool.trustedBurn(msg.sender, zcb_redeem_amount, true); 
    controller.redeem_transfer(collateral_redeem_amount, msg.sender, marketId); 


  }

  /// @notice called by short buyers when market is resolved  
  function redeemShortZCB(
    uint256 marketId 
    ) external _lock_ returns(uint256 collateral_redeem_amount){
    require(!restriction_data[marketId].alive, "Active"); 
    require(restriction_data[marketId].resolved, "!resolved"); 
    require(!redeemed[marketId][msg.sender], "Redeemed");
    redeemed[marketId][msg.sender] = true; 

    SyntheticZCBPool bondPool = markets[marketId].bondPool; 

    uint256 shortZCB_redeem_amount = markets[marketId].shortZCB.balanceOf(msg.sender); 
    uint256 long_redemption_price = redemption_prices[marketId];
    uint256 redemption_price = long_redemption_price >= config.WAD 
                               ? 0 
                               : config.WAD - long_redemption_price; 
    collateral_redeem_amount = redemption_price.mulWadDown(shortZCB_redeem_amount);

    bondPool.trustedBurn(msg.sender, shortZCB_redeem_amount, false); 
    controller.redeem_transfer(collateral_redeem_amount, msg.sender, marketId); 
  }

  /// @notice returns the manager's maximum leverage 
  function getMaxLeverage(address manager) public view returns(uint256){
    //return (repToken.getReputationScore(manager) * config.WAD).sqrt(); //TODO experiment 
    return (controller.getTraderScore(manager) * config.WAD).sqrt();
  }

  mapping(uint256=>mapping(address=> LeveredBond)) public leveragePosition; 
  struct LeveredBond{
    uint128 debt; //how much collateral borrowed from vault 
    uint128 amount; // how much bonds were bought with the given leverage
  }

  /// @notice for managers that are a) meet certain reputation threshold and b) choose to be more
  /// capital efficient with their zcb purchase. 
  /// @param _amountIn (in collateral) already accounts for the leverage, so the actual amount manager is transferring
  /// is _amountIn/_leverage 
  /// @dev the marketmanager should take custody of the quantity bought with leverage
  /// and instead return notes of the levered position 
  /// TODO do + instead of creating new positions and implied prob cumulative 
  function buyBondLevered(
    uint256 _marketId, 
    uint256 _amountIn, 
    uint256 _priceLimit, 
    uint256 _leverage //in 18 dec 
    ) external _lock_ returns(uint256 amountIn, uint256 amountOut){
    require(restriction_data[_marketId].duringAssessment, "PhaseERR"); 
    require(!restriction_data[_marketId].resolved, "!resolved");
    require(_leverage <= getMaxLeverage(msg.sender) && _leverage >= config.WAD, "!leverage");
    _canBuy(msg.sender, int256(_amountIn), _marketId);
    SyntheticZCBPool bondPool = markets[_marketId].bondPool; 

    // stack collateral from trader and borrowing from vault 
    uint256 amountPulled = _amountIn.divWadDown(_leverage); 
    bondPool.BaseToken().transferFrom(msg.sender, address(this), amountPulled); 
    controller.pullLeverage(_marketId, _amountIn - amountPulled); 

    // Buy with leverage, zcb transferred here
    bondPool.BaseToken().approve(address(this), _amountIn); 
    (amountIn, amountOut) = bondPool.takerOpen(true, int256(_amountIn), _priceLimit, abi.encode(address(this))); 

    //Need to log assessment trades for updating reputation scores or returning collateral when market denied 
    _logTrades(_marketId, msg.sender, _amountIn, 0, true, true);

    // Get implied probability estimates by summing up all this managers bought for this market 
    // assessment_probs[_marketId][msg.sender] = controller.calcImpliedProbability(
    //     amountOut, 
    //     amountIn, 
    //     getTraderBudget(_marketId, msg.sender) 
    // ); 

    // Phase Transitions when conditions met
    if(restriction_data[_marketId].onlyReputable){
      uint256 total_bought = loggedCollaterals[_marketId];

      if (total_bought >= parameters[_marketId].omega.mulWadDown(
            controller
            .getVault(_marketId)
            .fetchInstrumentData(_marketId)
            .principal)
      ) {
        restriction_data[_marketId].onlyReputable = false;
      }
    }
    // create note to trader 
    leveragePosition[_marketId][msg.sender] = LeveredBond(uint128(_amountIn - amountPulled ),uint128(amountOut)) ; 
  }

  function redeemLeveredBond(uint256 marketId) public{
    require(!restriction_data[marketId].alive, "!Active"); 
    require(restriction_data[marketId].resolved, "!resolved"); 
    require(!redeemed[marketId][msg.sender], "Redeemed");
    redeemed[marketId][msg.sender] = true; 

    if (controller.isValidator(marketId, msg.sender)) controller.redeemValidator(marketId, msg.sender); 

    LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
    require(position.amount>0, "ERR"); 

    uint256 redemption_price = redemption_prices[marketId]; 
    uint256 collateral_back = redemption_price.mulWadDown(position.amount) ; 
    uint256 collateral_redeem_amount = collateral_back >= uint256(position.debt)  
        ? collateral_back - uint256(position.debt) : 0; 

    if (!controller.isValidator(marketId, msg.sender)) {
      // bool increment = redemption_price >= config.WAD? true: false;
      // controller.updateReputation(marketId, msg.sender, increment);
      // reputationManager.recordPush(msg.sender, marketId, redemption_price, false, zcb_redeem_amount); 

    }

    // This means that the sender is a manager
    if (queuedRepUpdates[msg.sender] > 0){
     unchecked{queuedRepUpdates[msg.sender] -= 1;} 
    }

    leveragePosition[marketId][msg.sender].amount = 0; 
    markets[marketId].bondPool.trustedBurn(address(this), position.amount, true); 
    controller.redeem_transfer(collateral_redeem_amount, msg.sender, marketId); 
  }

  function redeemDeniedLeveredBond(uint256 marketId) public returns(uint collateral_amount){
    LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
    require(position.amount>0, "ERR"); 
    leveragePosition[marketId][msg.sender].amount = 0; 

    // TODO this means if trader's loss will be refunded if loss was realized before denied market
    if (controller.isValidator(marketId, msg.sender)) {
      collateral_amount = controller.deniedValidator(marketId, msg.sender);
    }
    else{
      collateral_amount = longTrades[marketId][msg.sender]; 
      delete longTrades[marketId][msg.sender]; 
    }

    // Burn all their position, 
    markets[marketId].bondPool.trustedBurn(address(this), position.amount, true); 

    // This means that the sender is a manager
    if (queuedRepUpdates[msg.sender] > 0){
      unchecked{queuedRepUpdates[msg.sender] -= 1;} 
    }    

    // Before redeem_transfer is called all funds for this instrument should be back in the vault
    controller.redeem_transfer(collateral_amount - uint256(position.debt), msg.sender, marketId);
  }
}

