pragma solidity ^0.8.4;
import {MarketManager} from "./marketmanager.sol";
import {ReputationNFT} from "./reputationtoken.sol";
import {Vault} from "../vaults/vault.sol";
import {Instrument} from "../vaults/instrument.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {VaultFactory} from "./factories.sol"; 
import "forge-std/console.sol";
import "@interep/contracts/IInterep.sol";
import {config} from "../utils/helpers.sol"; 
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@interep/contracts/IInterep.sol";
import {SyntheticZCBPoolFactory, SyntheticZCBPool} from "../bonds/synthetic.sol"; 


contract Controller {
  using SafeMath for uint256;
  using FixedPointMathLib for uint256;

  struct MarketData {
      address instrument_address;
      address recipient;
  }

  struct ApprovalData{
    uint256 approved_principal; 
    uint256 approved_yield; 
  }
  
  event MarketInitiated(uint256 marketId, address recipient);

  mapping(uint256=>ApprovalData) approvalDatas; 

  function getApprovalData(uint256 marketId) public view returns (ApprovalData memory) {
    approvalDatas[marketId];
  }

  mapping(address => bool) public  verified;
  mapping(uint256 => MarketData) public market_data; // id => recipient
  mapping(address=> uint256) public ad_to_id; //utilizer address to marketId
  mapping(uint256=> Vault) public vaults; // vault id to Vault contract
  mapping(uint256=> uint256) public id_parent; //marketId-> vaultId 
  mapping(uint256=> uint256) public vault_debt; //vault debt for each marketId
  mapping(uint256=>uint256[]) public vault_to_marketIds;

  address creator_address;

  IInterep interep;
  // TrustedMarketFactoryV3 marketFactory;
  MarketManager marketManager;
  // ReputationNFT repNFT; 
  VaultFactory vaultFactory; 
  SyntheticZCBPoolFactory poolFactory; 

  uint256 constant TWITTER_UNRATED_GROUP_ID = 16106950158033643226105886729341667676405340206102109927577753383156646348711;
  bytes32 constant private signal = bytes32("twitter-unrated");
  uint256 constant MIN_DURATION = 1 days;
  
  // Bond Curve Name
  string constant baseName = "Bond";
  string constant baseSymbol = "B";
  string constant s_baseName = "sBond";
  string constant s_baseSymbol = "sB";
  uint256 nonce = 0;

  /* ========== MODIFIERS ========== */
  modifier onlyValidator(uint256 marketId) {
      require(marketManager.isValidator(marketId, msg.sender)|| msg.sender == creator_address, "not validator for market");
      _;
  }

  modifier onlyOwner() {
      require(msg.sender == creator_address, "Only Owner can call this function");
      _;
  }
  modifier onlyManager() {
      require(msg.sender == address(marketManager) || msg.sender == creator_address, "Only Manager can call this function");
      _;
  }

  constructor (
      address _creator_address,
      address _interep_address
  ) {
      creator_address = _creator_address;
      interep = IInterep(_interep_address);
  }

  /*----Setup Functions----*/

  function setMarketManager(address _marketManager) public onlyOwner {
    require(_marketManager != address(0));
    marketManager = MarketManager(_marketManager);
  }

  // function setReputationNFT(address NFT_address) public onlyOwner{
  //   repNFT = ReputationNFT(NFT_address); 
  // }

  function setVaultFactory(address _vaultFactory) public onlyOwner {
    vaultFactory = VaultFactory(_vaultFactory); 
  }

  function setPoolFactory(address _poolFactory) public onlyOwner{
    poolFactory = SyntheticZCBPoolFactory(_poolFactory); 
  }

  function verifyAddress(
      uint256 nullifier_hash, 
      uint256 external_nullifier,
      uint256[8] calldata proof
  ) external  {
      require(!verified[msg.sender], "address already verified");
      interep.verifyProof(TWITTER_UNRATED_GROUP_ID, signal, nullifier_hash, external_nullifier, proof);
      verified[msg.sender] = true;
  }

  function testVerifyAddress() external {
    verified[msg.sender] = true;
  }


  /// @notice called only when redeeming, transfer funds from vault 
  function redeem_transfer(
    uint256 amount, 
    address to, 
    uint256 marketId) 
  external onlyManager{
    vaults[id_parent[marketId]].trusted_transfer(amount,to); 
  }
  
  /// @notice creates vault
  /// @param underlying: underlying asset for vault
  /// @param _onlyVerified: only verified users can mint shares
  /// @param _r: minimum reputation score to mint shares
  /// @param _asset_limit: max number of shares for a single address
  /// @param _total_asset_limit: max number of shares for entire vault
  /// @param default_params: default params for markets created by vault
  function createVault(
    address underlying,
    bool _onlyVerified, 
    uint256 _r, 
    uint256 _asset_limit, 
    uint256 _total_asset_limit, 
    MarketManager.MarketParameters memory default_params 
  ) public {
    (Vault newVault, uint256 vaultId) = vaultFactory.newVault(
     underlying, 
     address(this),
     _onlyVerified, 
     _r, 
     _asset_limit,
     _total_asset_limit,
     default_params
    );

    vaults[vaultId] = newVault;
  }

  /// @notice initiates market, called by frontend loan proposal or instrument form submit button.
  /// @dev Instrument should already be deployed 
  /// @param recipient: utilizer for the associated instrument
  /// @param instrumentData: instrument arguments
  /// @param vaultId: vault identifier
  function initiateMarket(
    address recipient,
    Vault.InstrumentData memory instrumentData, 
    uint256 vaultId
  ) external  {
    require(recipient != address(0), "address0"); 
    require(instrumentData.Instrument_address != address(0), "address0");
    require(address(vaults[vaultId]) != address(0), "address0");

    Vault vault = vaults[vaultId]; 
    uint256 marketId = marketManager.marketCount();
    id_parent[marketId] = vaultId;
    vault_to_marketIds[vaultId].push(marketId);
    market_data[marketId] = MarketData(instrumentData.Instrument_address, recipient);
    marketManager.setParameters(vault.get_vault_params(), vault.utilizationRate(), marketId); //TODO non-default 

    // Create new pool and bonds and store initial price and liquidity for the pool
    (address longZCB, address shortZCB, SyntheticZCBPool pool) 
              = poolFactory.newPool(address(vaults[vaultId].UNDERLYING()), address(marketManager)); 

    if (instrumentData.isPool){
      pool.calculateInitCurveParamsPool(instrumentData.poolData.saleAmount, 
        instrumentData.poolData.initPrice, instrumentData.poolData.inceptionPrice, marketManager.getParameters(marketId).sigma); 
      console.log("?");

      marketManager.newMarket(marketId, instrumentData.poolData.saleAmount, pool, longZCB, shortZCB, instrumentData.description, 
        instrumentData.duration, true); 
      console.log("??");
    }
    else{
      pool.calculateInitCurveParams(instrumentData.principal,
          instrumentData.expectedYield, marketManager.getParameters(marketId).sigma); 

      marketManager.newMarket(marketId, instrumentData.principal, pool, longZCB, shortZCB, instrumentData.description,
                              instrumentData.duration, false);
    }

    // add vault proposal 
    instrumentData.marketId = marketId;
    vault.addProposal(instrumentData);

    emit MarketInitiated(marketId, recipient);
    ad_to_id[recipient] = marketId; //only for testing purposes, one utilizer should be able to create multiple markets
  }

  /// @notice Resolve function 1
  /// @dev Prepare market/instrument for closing, called separately before resolveMarket
  /// this is either called automatically from the instrument when conditions are met i.e fully repaid principal + interest
  /// or, in the event of a default, by validators who deem the principal recouperation is finished
  /// and need to collect remaining funds by redeeming ZCB
  function beforeResolve(uint256 marketId) external 
  //onlyValidator(marketId) 
  {
    vaults[id_parent[marketId]].beforeResolve(marketId);
  }
 
  /// Resolve function 2
  /// @notice main function called at maturity OR premature resolve of instrument(from early default)  
  /// @dev validators call this function from market manager
  /// any funds left for the instrument, irrespective of whether it is in profit or inloss. 
  function resolveMarket(
    uint256 marketId
    ) external onlyValidator(marketId) {
    require(marketManager.resolveCondition(marketId), "resolve condition not met");
    (bool atLoss, uint256 extra_gain, uint256 principal_loss, bool premature) 
          = vaults[id_parent[marketId]].resolveInstrument(marketId);

    marketManager.updateRedemptionPrice(marketId, atLoss, extra_gain, principal_loss, premature);
    marketManager.updateValidatorStake(marketId, approvalDatas[marketId].approved_principal, principal_loss);
    cleanUpDust(marketId);
  }

  /// @notice When market resolves, should collect remaining liquidity and/or dust from  
  /// the pool and send them back to the vault
  /// @dev should be called before redeem_transfer is allowed 
  function cleanUpDust(uint256 marketId) internal {
    marketManager.getPool(marketId).flush(getVaultAd(marketId), type(uint256).max); 
  }

  /// @notice checks for maturity, resolve at maturity
  /// @param marketId: called for anyone.
  function checkInstrument(uint256 marketId) external
  ///onlyKeepers 
   returns (bool) {
    Vault.InstrumentData memory data = vaults[id_parent[marketId]].fetchInstrumentData( marketId);
      
    require(data.marketId > 0 && data.trusted, "instrument must be active");
    require(data.maturityDate > 0, "instrument hasn't been approved yet" );

    if (block.timestamp >= data.maturityDate) {
        // this.resolveMarket(marketId);
        this.beforeResolve(marketId);
        return true;
    }
    return false;
  }

  /// @notice when market is resolved(maturity/early default), calculates score
  /// and update each assessment phase trader's reputation, called by individual traders when redeeming 
  function updateReputation(
    uint256 marketId, 
    address trader, 
    bool increment) 
  external onlyManager {
    uint256 implied_probs = marketManager.assessment_probs(marketId, trader);
    // int256 scoreToUpdate = increment ? int256(implied_probs.mulDivDown(implied_probs, config.WAD)) //experiment 
    //                                  : -int256(implied_probs.mulDivDown(implied_probs, config.WAD));
    uint256 change = implied_probs.mulDivDown(implied_probs, config.WAD);
    
    if (increment) {
      _incrementScore(trader, change);
    } else {
      _decrementScore(trader, change);
    }
  }

  /// @notice function that closes the instrument/market before maturity, maybe to realize gains/cut losses fast
  /// or debt is prematurely fully repaid, or underlying strategy is deemed dangerous, etc. 
  /// After, the resolveMarket function should be called in a new block  
  /// @dev withdraws all balance from the instrument. 
  /// If assets in instrument is not in underlying, need all balances to be divested to underlying 
  /// Ideally this should be called by several validators, maybe implement a voting scheme and have a keeper call it.
  /// @param emergency ascribes cases where the instrument should be forcefully liquidated back to the vault
  function forceCloseInstrument(uint256 marketId, bool emergency) external returns(bool){
    Vault vault = vaults[id_parent[marketId]]; 

    // Prepare for close 
    vault.closeInstrument(marketId); 

    // Harvests/records all profit & losses
    vault.beforeResolve(marketId); 
    return true;
  }

  /// @notice called by the validator when market conditions are met
  /// need to move the collateral in the wCollateral to 
  function approveMarket(
    uint256 marketId
  ) external onlyManager {
    Vault vault = vaults[id_parent[marketId]]; 
    SyntheticZCBPool pool = marketManager.getPool(marketId); 
    
    require(marketManager.getCurrentMarketPhase(marketId) == 3,"!marketCondition");
    require(vault.instrumentApprovalCondition(marketId), "!instrumentCondition");

    bool isPool = marketManager.isInstrumentPool(marketId); 
    uint256 managerCollateral = marketManager.loggedCollaterals(marketId); 

    if (isPool) poolApproval(marketId, managerCollateral, vault.fetchInstrumentData( marketId).poolData.leverageFactor); 

    else {
      if (vault.getInstrumentType(marketId) == 0) creditApproval(marketId, pool); 

      else generalApproval(marketId); 
    }
    // pull from pool to vault, which will be used to fund the instrument
    pool.flush(address(vault), managerCollateral); 

    // Trust and deposit to the instrument contract
    vault.trustInstrument(marketId, approvalDatas[marketId], isPool);

    // Since funds are transfered from pool to vault, set default liquidity in pool to 0 
    pool.resetLiq(); 
  }

  function poolApproval(uint256 marketId, uint256 managerCollateral, uint256 leverageFactor) internal{
    require(leverageFactor > 0, "0 LEV_FACTOR"); 

    approvalDatas[marketId] = ApprovalData(managerCollateral.mulWadDown(leverageFactor), 0 ); 
  }

  /// @notice receives necessary market information. Only applicable for creditlines 
  /// required for market approval such as max principal, quoted interest rate
  function creditApproval(uint256 marketId, SyntheticZCBPool pool) internal{
    (uint256 proposed_principal, uint256 proposed_yield) 
          = vaults[id_parent[marketId]].viewPrincipalAndYield(marketId); 

    // get max_principal which is (s+1) * total long bought for creditline, or just be
    // proposed principal for other instruments 
    uint256 max_principal = min((marketManager.getParameters(marketId).s + config.WAD)
                            .mulWadDown(marketManager.loggedCollaterals(marketId)),
                            proposed_principal ); 

    // Required notional yield amount denominated in underlying  given credit determined by managers
    uint256 quoted_interest = min(pool.areaBetweenCurveAndMax(max_principal), proposed_yield ); 

    approvalDatas[marketId] = ApprovalData(max_principal, quoted_interest); 
  }

  function generalApproval(uint256 marketId) internal {
    (uint256 proposed_principal, uint256 proposed_yield) = vaults[id_parent[marketId]].viewPrincipalAndYield(marketId); 
    approvalDatas[marketId] = ApprovalData(proposed_principal, proposed_yield); 
  }

  function denyMarket(
      uint256 marketId
  ) external  onlyManager{
    vaults[id_parent[marketId]].denyInstrument(marketId);
    cleanUpDust(marketId);
  }

  /*----Reputation Logic----*/
  mapping(address=>uint256) public trader_scores; // trader address => score
  mapping(address=>bool) public isRated;
  address[] public traders;

  /**
   @notice calculates whether a trader meets the requirements to trade during the reputation assessment phase.
   @param percentile: 0-100 w/ WAD.
   */
  function isReputable(address trader, uint256 percentile) view external returns (bool) {
    uint256 k = _findTrader(trader);
    uint256 n = (traders.length - (k+1))*config.WAD;
    uint256 N = traders.length*config.WAD;
    uint256 p = uint256(n).divWadDown(N)*10**2;

    if (p >= percentile) {
      return true;
    } else {
      return false;
    }
  }

  /**
   @notice finds the first trader within the percentile
   @param percentile: 0-100 WAD
   @dev returns 0 on no minimum threshold
   */
  function calculateMinScore(uint256 percentile) view external returns (uint256) {
    uint256 l = traders.length * config.WAD;
    if (percentile / 1e2 == 0) {
      return 0;
    }
    uint256 x = l.mulWadDown(percentile / 1e2);
    x /= config.WAD;
    return trader_scores[traders[x - 1]];
  }

  function setTraderScore(address trader, uint256 score) external {
    uint256 prev_score = trader_scores[trader];
    if (score > prev_score) {
      _incrementScore(trader, score - prev_score);
    } else if (score < prev_score) {
      _decrementScore(trader, prev_score - score);
    }
  }

  /**
   @dev percentile is is wad 0-100
   */
  function filterTraders(uint256 percentile, address utilizer) view external returns (address[] memory) {
    uint256 l = traders.length * config.WAD;
    
    if (percentile / 1e2 == 0) {
      console.log("here");
      if (isRated[utilizer]) {
        address[] memory result = new address[](traders.length - 1);

        uint256 j = 0;
        for (uint256 i=0; i<traders.length; i++) {
          if (utilizer == traders[i]) {
            j = 1;
            continue;
          }
          result[i - j] = traders[i];
        }
        return result;
      } else {
        return traders;
      }
    }

    uint256 x = l.mulWadDown((config.WAD*100 - percentile) / 1e2);
    x /= config.WAD;

    address[] memory selected; 
    if (utilizer == address(0) || !isRated[utilizer]) {
      selected = new address[](x);
      for (uint256 i=0; i<x; i++) {
        selected[i] = traders[i];
      }
    } else {
      selected = new address[](x - 1);
      uint256 j=0;
      for (uint256 i = 0; i<x; i++) {
        if (traders[i] == utilizer) {
          j = 1;
          continue;
        }
        selected[i - j] = traders[i];
      }
    }

    return selected;
  }

  /**
   @notice retrieves all rated traders
   */
  function getTraders() public returns (address[] memory) {
    return traders;
  }

  /**
   @notice increments trader's score
   @dev score >= 0, update > 0
   */
  function _incrementScore(address trader, uint256 update) public {
    trader_scores[trader] += update;
    _updateRanking(trader, true);
  }

  /**
   @notice decrements trader's score
   @dev score >= 0, update > 0
   */
  function _decrementScore(address trader, uint256 update) public {
    if (update >= trader_scores[trader]) {
      trader_scores[trader] = 0;
    } else {
      trader_scores[trader] -= update;
    }
    _updateRanking(trader, false);
  }

  /**
   @notice updates top trader array
   */
  function _updateRanking(address trader, bool increase) internal {
    uint256 score = trader_scores[trader];

    if (!isRated[trader]) {
      isRated[trader] = true;
      if (traders.length == 0) {
        traders.push(trader);
        return;
      }
      for (uint256 i=0; i<traders.length; i++) {
        if (score > trader_scores[traders[i]]) {
          traders.push(address(0));
          _shiftRight(i, traders.length-1);
          traders[i] = trader;
          return;
        }
        if (i == traders.length - 1) {
          traders.push(trader);
          return;
        }
      }
    } else {
      uint256 k = _findTrader(trader);
      //swap places with someone.
      if ((k == 0 && increase)
      || (k == traders.length - 1 && !increase)) {
        return;
      }

      if (increase) {
        for (uint256 i=0; i<k; i++) {
          if (score > trader_scores[traders[i]]) {
            _shiftRight(i,k);
            traders[i] = trader;
            return;
          }
        }
      } else {
        for (uint256 i=traders.length - 1; i>k; i--) {
          if (score < trader_scores[traders[i]]) {
            _shiftLeft(k, i);
            traders[i] = trader;
            return;
          }
        }
      }
    }
  }

  function _findTrader(address trader) internal view returns (uint256) {
    for (uint256 i=0; i<traders.length; i++) {
      if (trader == traders[i]) {
        return i;
      }
    }
  }

  function _shiftRight(uint256 pos, uint256 end) internal {
    for (uint256 i=end; i>pos; i--) {
      traders[i] = traders[i-1];
    }
  }

  function _shiftLeft(uint256 pos, uint256 end) internal {
    for (uint256 i=pos; i<end; i++) {
      traders[i] = traders[i+1];
    }
  }

  function pullLeverage(uint256 marketId, uint256 amount) external onlyManager{
    getVault(marketId).trusted_transfer(amount, address(marketManager)); 
  }

  function getMarketId(address recipient) public view returns(uint256){
    return ad_to_id[recipient];
  }

  function getVault(uint256 marketId) public view returns(Vault){
    return vaults[id_parent[marketId]]; 
  }

  function getVaultAd(uint256 marketId) public view returns(address){
    return address(vaults[id_parent[marketId]]); 
  }

  function isVerified(address addr)  public view returns (bool) {
    return verified[addr];
  }

  function getVaultfromId(uint256 vaultId) public view returns(address){
    return address(vaults[vaultId]); 
  }

  function marketId_to_vaultId(uint256 marketId) public view returns(uint256){
    return id_parent[marketId]; 
  }

  function marketIdToVaultId(uint256 marketId) public view returns(uint256){
    return id_parent[marketId]; 
  }
  function getMarketIds(uint256 vaultId) public view returns (uint256[] memory) {
    return vault_to_marketIds[vaultId];
  }
  function max(uint256 a, uint256 b) internal pure returns (uint256) {
      return a >= b ? a : b;
  }
  function min(uint256 a, uint256 b) internal pure returns (uint256) {
      return a <= b ? a : b;
  }
}

