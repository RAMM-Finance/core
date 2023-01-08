pragma solidity ^0.8.16;

import {Auth} from "./auth/Auth.sol";
import {ERC4626} from "./mixins/ERC4626.sol";

import {SafeCastLib} from "./utils/SafeCastLib.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";

import {ERC20} from "./tokens/ERC20.sol";
import {Instrument} from "./instrument.sol";
import {PoolInstrument} from "../instruments/poolInstrument.sol";
import {Controller} from "../protocol/controller.sol";
import {MarketManager} from "../protocol/marketmanager.sol"; 
import "openzeppelin-contracts/utils/math/Math.sol";
import "forge-std/console.sol";


contract Vault is ERC4626{
    using SafeCastLib for uint256; 
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;


    /*///////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal BASE_UNIT;
    uint256 totalInstrumentHoldings; //total holdings deposited into all Instruments collateral
    ERC20 public immutable UNDERLYING;
    Controller private controller;
    MarketManager.MarketParameters default_params; 

    ///// For Factory
    bool public onlyVerified; 
    uint256 public r; //reputation ranking  
    uint256 public asset_limit; 
    uint256 public total_asset_limit; 

    mapping(Instrument => InstrumentData) public instrument_data;
    mapping(address => uint256) public  num_proposals;
    mapping(uint256=> Instrument) public Instruments; //marketID-> Instrument
    mapping(uint256 => bool) resolveBeforeMaturity;
    mapping(uint256=>ResolveVar) prepareResolveBlock;

    enum InstrumentType {
        CreditLine,
        CoveredCallShort,
        LendingPool, 
        StraddleBuy, 
        LiquidityProvision, 
        Other
    }


    /// @param trusted Whether the Instrument is trusted.
    /// @param balance The amount of underlying tokens held in the Instrument.
    struct InstrumentData {
      bytes32 name;
      bool isPool; 
      // Used to determine if the Vault will operate on a Instrument.
      bool trusted;
      // Balance of the contract denominated in Underlying, 
      // used to determine profit and loss during harvests of the Instrument.  
      // represents the amount of debt the Instrument has incurred from this vault   
      uint256 balance; // in underlying, IMPORTANT to get this number right as it modifies key states 
      uint256 faceValue; // in underlying
      uint256 marketId;
      uint256 principal; //this is total available allowance in underlying
      uint256 expectedYield; // total interest paid over duration in underlying
      uint256 duration;
      string description;
      address instrument_address;
      InstrumentType instrument_type;
      uint256 maturityDate;
      PoolData poolData; 
    }

    /// @notice probably should have default parameters for each vault
    struct PoolData{
      uint256 saleAmount; 
      uint256 initPrice; // init price of longZCB in the amm 
      uint256 promisedReturn; //per unit time 
      uint256 inceptionTime;
      uint256 inceptionPrice; // init price of longZCB after assessment 
      uint256 leverageFactor; //leverageFactor * manager collateral = capital from vault to instrument
      uint256 managementFee; // sum of discounts for high reputation managers/validators
    }

    struct ResolveVar{
        uint256 endBlock; 
        bool isPrepared; 
    }
    address public owner; 
    constructor(
        address _UNDERLYING,
        address _controller, 
        address _owner, 

        bool _onlyVerified, //
        uint256 _r, //reputation ranking
        uint256 _asset_limit, 
        uint256 _total_asset_limit,

        MarketManager.MarketParameters memory _default_params
    )
        ERC4626(
            ERC20(_UNDERLYING),
            string(abi.encodePacked("Ramm ", ERC20(_UNDERLYING).name(), " Vault")),
            string(abi.encodePacked("RAMM", ERC20(_UNDERLYING).symbol()))
        )  

    {   
        owner = _owner; 
        UNDERLYING = ERC20(_UNDERLYING);
        require(UNDERLYING.decimals() == 18, "decimals"); 
        BASE_UNIT = 1e18; 
        controller = Controller(_controller);
        set_minting_conditions( _onlyVerified,  _r, _asset_limit, _total_asset_limit); 
        default_params = _default_params; 
    }

    function getInstrumentType(uint256 marketId) public view returns(uint256){
        // return 0 if credit line //TODO 
        return 0; 
    }

    function getInstrumentData(Instrument _instrument) public view returns (InstrumentData memory) {
        return instrument_data[_instrument];
    }
    
    modifier onlyController(){
        require(address(controller) == msg.sender || msg.sender == owner || address(this) == msg.sender ,  "is not controller"); 
        _;
    }

    /// @notice called by controller at maturity 
    function controller_burn(uint256 amount, address bc_address) external onlyController {
        _burn(bc_address,amount); 
    }
    /// @notice called by controller at maturity, since redeem amount > balance in bc
    function controller_mint(uint256 amount, address to) external onlyController {
        _mint(to , amount); 
    }
    /// @notice amount is always in WAD, so need to convert if decimals mismatch
    function trusted_transfer(uint256 amount, address to) external onlyController{
        if (decimal_mismatch) amount = decSharesToAssets(amount); 
        UNDERLYING.transfer(to, amount); 
    }

    function balanceInUnderlying(address ad) external view returns(uint256){
        return previewRedeem(balanceOf[ad]); 
    }

    /// @notice burns all balance of address 
    function burnAll(address to) private{
      _burn(to, balanceOf[to]); 
    }

  struct localVars{
    uint256 promised_return; 
    uint256 inceptionTime; 
    uint256 inceptionPrice; 
    uint256 leverageFactor; 
    uint256 managementFee; 

    uint256 srpPlusOne; 
    uint256 totalAssetsHeld; 
    uint256 juniorSupply;
    uint256 seniorSupply; 

    bool belowThreshold; 
  }
  /// @notice get programmatic pricing of a pool based longZCB 
  /// returns psu: price of senior(VT's share of investment) vs underlying 
  /// returns pju: price of junior(longZCB) vs underlying
  function poolZCBValue(uint256 marketId) 
    public 
    view
    returns(uint256 psu, uint256 pju, uint256 levFactor){
      //TODO should not tick during assessment 
    localVars memory vars; 

    (vars.promised_return, vars.inceptionTime, vars.inceptionPrice, vars.leverageFactor, 
      vars.managementFee) = fetchPoolTrancheData(marketId); 
    levFactor = vars.leverageFactor; 

    require(vars.inceptionPrice > 0, "0"); 

    // Get senior redemption price that increments per unit time 
    vars.srpPlusOne = vars.inceptionPrice.mulWadDown((BASE_UNIT+ vars.promised_return)
      .rpow(block.timestamp - vars.inceptionTime, BASE_UNIT));

    // Get total assets held by the instrument 
    vars.juniorSupply = controller.getTotalSupply(marketId); 
    vars.seniorSupply = vars.juniorSupply.mulWadDown(vars.leverageFactor); 
    vars.totalAssetsHeld = instrumentAssetOracle(marketId, vars.juniorSupply, vars.seniorSupply); 

    if (vars.seniorSupply == 0) return(vars.srpPlusOne,vars.srpPlusOne,levFactor); 
    
    // Check if all seniors can redeem
    if (vars.totalAssetsHeld >= vars.srpPlusOne.mulWadDown(vars.seniorSupply))
      psu = vars.srpPlusOne; 
    else{
      psu = vars.totalAssetsHeld.divWadDown(vars.seniorSupply);
      vars.belowThreshold = true;  
    }
    console.log("ok?", vars.totalAssetsHeld, vars.srpPlusOne.mulWadDown(vars.seniorSupply),vars.srpPlusOne); 

    // should be 0 otherwise 
    if(!vars.belowThreshold) pju = (vars.totalAssetsHeld 
      - vars.srpPlusOne.mulWadDown(vars.seniorSupply)).divWadDown(vars.juniorSupply); 
    // uint pju_ = (BASE_UNIT+ vars.leverageFactor).mulWadDown(previewMint(BASE_UNIT*8/10)) 
    //   -  vars.srpPlusOne.mulWadDown(vars.leverageFactor);
    // assert(pju_ >= pju-10 || pju_ <= pju+10); 
        // console.log('ok????'); 

    }

    event InstrumentHarvest(address indexed instrument, uint256 totalInstrumentHoldings, uint256 instrument_balance, uint256 mag, bool sign); //sign is direction of mag, + or -.

    /// @notice Harvest a trusted Instrument, records profit/loss 
    function harvest(address instrument) public {
      require(instrument_data[Instrument(instrument)].trusted, "UNTRUSTED_Instrument");
      InstrumentData storage data = instrument_data[Instrument(instrument)]; 

      uint256 oldTotalInstrumentHoldings = totalInstrumentHoldings; 
      uint256 balanceLastHarvest = data.balance;
      uint256 balanceThisHarvest = Instrument(instrument).balanceOfUnderlying(address(instrument));
      
      if (balanceLastHarvest == balanceThisHarvest) {
          return;
      }

      data.balance = balanceThisHarvest;

      uint256 delta;
      bool net_positive = balanceThisHarvest >= balanceLastHarvest;
      delta = net_positive ? balanceThisHarvest - balanceLastHarvest : balanceLastHarvest - balanceThisHarvest;
      totalInstrumentHoldings = net_positive ? oldTotalInstrumentHoldings + delta : oldTotalInstrumentHoldings - delta;

      emit InstrumentHarvest(instrument, totalInstrumentHoldings, balanceThisHarvest, delta, net_positive);
    }

    event InstrumentDeposit(uint256 indexed marketId, address indexed instrument, uint256 amount, bool isPool);
    /// @notice Deposit a specific amount of float into a trusted Instrument.
    /// Called when market is approved. 
    /// Also has the role of granting a credit line to a credit-based Instrument like uncol.loans 
    function depositIntoInstrument(
      uint256 marketId, 
      uint256 underlyingAmount,
      bool isPool) public virtual
  //onlyManager
    {
      Instrument instrument = fetchInstrument(marketId); 
      require(instrument_data[instrument].trusted, "UNTRUSTED Instrument");

      // if (decimal_mismatch) underlyingAmount = decSharesToAssets(underlyingAmount); 

      uint256 curBalance = UNDERLYING.balanceOf(address(this)); 
      if (underlyingAmount > curBalance) {

        // check if can be pulled from lending pool, if yes do it
        uint256 required = underlyingAmount - curBalance; 
        if(PoolInstrument(address(Instruments[0])).isWithdrawAble( address(this), required))  
          pullFromLM( required); 
        else revert("!vaultbal"); 
      }

      totalInstrumentHoldings += underlyingAmount; 
      instrument_data[instrument].balance += underlyingAmount;

      if(!isPool)
        require(UNDERLYING.transfer(address(instrument), underlyingAmount), "DEPOSIT_FAILED");
      else{
        // TODO keep track of all this 
        UNDERLYING.approve(address(instrument), underlyingAmount); 
        require(ERC4626(address(instrument)).deposit(underlyingAmount, address(this))>0, "DEPOSIT_FAILED");

      }

      emit InstrumentDeposit(marketId, address(instrument), underlyingAmount, isPool);
    }

    event InstrumentWithdrawal(uint256 indexed marketId, address indexed instrument, uint256 amount);
    /// @notice Withdraw a specific amount of underlying tokens from a Instrument.
    function withdrawFromInstrument(
      Instrument instrument, 
      uint256 underlyingAmount, 
      bool redeem) internal virtual {
      require(instrument_data[instrument].trusted, "UNTRUSTED Instrument");
      
      // if (decimal_mismatch) underlyingAmount = decSharesToAssets(underlyingAmount); 

      instrument_data[instrument].balance -= underlyingAmount;
      
      totalInstrumentHoldings -= underlyingAmount;
      
      if (redeem) require(instrument.redeemUnderlying(underlyingAmount), "REDEEM_FAILED");

      emit InstrumentWithdrawal(instrument_data[instrument].marketId, address(instrument), underlyingAmount);
    }

    function withdrawFromPoolInstrument(
      uint256 marketId, 
      uint256 instrumentPullAmount, 
      address pushTo, 
      uint256 underlyingAmount
      ) public virtual 
    //onlyManager
    { 
      // Send to withdrawer 
      Instrument instrument = fetchInstrument( marketId); 
      require(instrument.isLiquid(underlyingAmount + instrumentPullAmount), "!liq");

      ERC4626(address(instrument)).withdraw(underlyingAmount + instrumentPullAmount, address(this), address(this)); 
      UNDERLYING.transfer(pushTo, instrumentPullAmount); 

      //TODO instrument balance should decrease to 0 and stay solvent  
      withdrawFromInstrument(fetchInstrument(marketId), underlyingAmount, false);
    }

    event InstrumentTrusted(uint256 indexed marketId, address indexed instrument, uint256 principal, uint256 expectedYield);
    /// @notice Stores a Instrument as trusted when its approved
    function trustInstrument(
      uint256 marketId,
      Controller.ApprovalData memory data, 
      bool isPool
      ) external virtual onlyController{
      instrument_data[fetchInstrument(marketId)].trusted = true;

      //Write to storage 
      if(!isPool){
        InstrumentData storage instrumentData = instrument_data[Instruments[marketId]]; 
        instrumentData.principal = data.approved_principal; 
        instrumentData.expectedYield = data.approved_yield;
        instrumentData.faceValue = data.approved_principal + data.approved_yield; 

        depositIntoInstrument(marketId, data.approved_principal - data.managers_stake, false);
        
        setMaturityDate(marketId);

        fetchInstrument(marketId).onMarketApproval(data.approved_principal, data.approved_yield); 

      } else{
        depositIntoInstrument(marketId, data.approved_principal - data.managers_stake, true);
      }
      emit InstrumentTrusted(marketId, address(Instruments[marketId]), data.approved_principal, data.approved_yield);
    }

    /// @notice fetches how much asset the instrument has in underlying. 
    function instrumentAssetOracle(uint256 marketId, uint256 juniorSupply, uint256 seniorSupply) public view returns(uint256){
      // Default balance oracle 
      ERC4626 instrument = ERC4626(address(Instruments[marketId])); 
      console.log('preview', instrument.previewDeposit(BASE_UNIT)); 
      return (juniorSupply + seniorSupply).mulWadDown(instrument.previewDeposit(BASE_UNIT))*8/10; 
      // return (juniorSupply + seniorSupply).mulWadDown(BASE_UNIT*8/10); 
      //return instrument_data[Instruments[marketId]].balance; 
      //TODO custom oracle 
    }

    /// @notice Stores a Instrument as untrusted
    // not needed?
    function distrustInstrument(Instrument instrument) external onlyController {
      instrument_data[instrument].trusted = false; 
    }

    function addLendingModule(address lv) external
    //onlyOwner
    { 
      // The 0th instrument is always the lending module 
      Instruments[0] = Instrument(lv);
      instrument_data[Instruments[0]].trusted = true; 
      UNDERLYING.approve(lv, type(uint256).max); 
    }

    /// @notice push unutilized capital to leverage vault 
    function pushToLM(uint256 amount) external 
    //onlyOwner 
    { 
      // if amount=0, push everything this vault have 
      uint256 depositAmount = amount==0
        ? UNDERLYING.balanceOf(address(this))
        : amount; 

      depositIntoInstrument(0, depositAmount, true); 
    }

    function pullFromLM(uint256 amount) public
    //onlyowner or internal 
    {


      // check if amount is available liquidity, and is appropriate for the given
      // shares this vault has of it. 
      Instrument instrument = fetchInstrument(0); 
      uint256 shares = ERC4626(address(instrument)).balanceOf(address(this)); 
      require(amount <= ERC4626(address(instrument)).previewMint(shares), "!!liq" ); 
      require(instrument.isLiquid(amount), "!liq");

      ERC4626(address(instrument)).withdraw(amount, address(this), address(this)); 

      withdrawFromInstrument(instrument, amount, false);
    }

    /// @notice returns true if Instrument is approved
    function isTrusted(Instrument instrument) public view returns(bool){
      return instrument_data[instrument].trusted; 
    }

    /// @notice Calculates the total amount of underlying tokens the Vault holds, excluding profit 
    function totalAssets() public view override returns(uint256){
      return totalInstrumentHoldings + totalFloat();
    }

    function utilizationRate() public view returns(uint256){

        if (totalInstrumentHoldings==0) return 0;  
        return totalInstrumentHoldings.divWadDown(totalAssets()); 

    }
    function totalFloat() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this));
    }

    function fetchInstrument(uint256 marketId) public view returns(Instrument){
      return Instruments[marketId]; 
    }

    function fetchInstrumentData(uint256 marketId) public view returns(InstrumentData memory){
      return instrument_data[Instruments[marketId]];
    }

    function fetchPoolTrancheData(uint256 marketId) public view returns(uint256, uint256, uint256, uint256, uint256){
      InstrumentData memory data = instrument_data[Instruments[marketId]]; 
      return (data.poolData.promisedReturn, data.poolData.inceptionTime, 
            data.poolData.inceptionPrice, data.poolData.leverageFactor, data.poolData.managementFee); 
    }
  
    event InstrumentRemoved(uint256 indexed marketId, address indexed instrumentAddress);
    /**
     called on market denial + removal, maybe no chekcs?
     */
    function removeInstrument(uint256 marketId) internal {
        InstrumentData storage data = instrument_data[Instruments[marketId]];
        require(data.marketId > 0, "instrument doesn't exist");
        delete instrument_data[Instruments[marketId]];
        delete Instruments[marketId];
        // emit event here;
        emit InstrumentRemoved(marketId, address(Instruments[marketId]));
    }

    // event PoolAdded(
    //   uint256 indexed marketId,
    //   address indexed instrumentAddress,
    //   bytes32 indexed name,
    //   uint256 saleAmount, 
    //   uint256 initPrice, // init price of longZCB in the amm 
    //   uint256 promisedReturn, //per unit time 
    //   uint256 inceptionTime,
    //   uint256 inceptionPrice, // init price of longZCB after assessment 
    //   uint256 leverageFactor, //leverageFactor * manager collateral = capital from vault to instrument
    //   uint256 managementFee
    // );

    // event InstrumentAdded(
    //   uint256 indexed marketId,
    //   address indexed instrumentAddress,
    //   bytes32 indexed name,
    //   uint256 faceValue,
    //   uint256 principal,
    //   uint256 expectedYield,
    //   uint256 duration,
    //   uint256 maturityDate,
    //   InstrumentType instrumentType,
    //   bool isPool
    // );

    event ProposalAdded(InstrumentData data);
    /// @notice add instrument proposal created by the Utilizer 
    /// @dev Instrument instance should be created before this is called
    /// need to add authorization
    function addProposal(
        InstrumentData memory data
    ) external onlyController {
      if(!data.isPool){
        require(data.principal > 0, "principal must be greater than 0");
        require(data.duration > 0, "duration must be greater than 0");
        require(data.faceValue > 0, "faceValue must be greater than 0");
        require(data.principal >= BASE_UNIT, "Needs to be in decimal format"); 
        require(data.marketId > 0, "must be valid instrument");
      }
        num_proposals[msg.sender] ++; 
        // TODO indexed by id
        instrument_data[Instrument(data.instrument_address)] = data;  

        Instruments[data.marketId] = Instrument(data.instrument_address);
        emit ProposalAdded(data);
    }

    event MaturityDateSet(uint256 indexed marketId, address indexed instrument, uint256 maturityDate);
  
    function setMaturityDate(uint256 marketId) internal {

        instrument_data[fetchInstrument(marketId)].maturityDate = instrument_data[fetchInstrument(marketId)].duration + block.timestamp;
        emit MaturityDateSet(marketId, address(fetchInstrument(marketId)), instrument_data[fetchInstrument(marketId)].maturityDate);
    }

    /// @notice function called when instrument resolves from within
    function pingMaturity(address instrument, bool premature) external {
        require(msg.sender == instrument || isTrusted(Instrument(instrument))); 
        uint256 marketId = instrument_data[Instrument(instrument)].marketId; 
        beforeResolve(marketId); 
        resolveBeforeMaturity[marketId] = premature; 
    }

    /// @notice RESOLVE FUNCTION #1
    /// Checks if instrument is ready to be resolved and locks capital.
    /// records blocknumber such that resolveInstrument is called after this function 
    /// records balances+PnL of instrument
    /// @dev need to store internal balance that is used to calculate the redemption price 
    function beforeResolve(uint256 marketId) public {
        Instrument _instrument = Instruments[marketId]; 

        require(msg.sender == address(_instrument) || msg.sender == address(controller), "Not allowed"); 
        require(isTrusted( _instrument), "Not trusted"); 

        // Should revert if can't be resolved 
        _instrument.prepareWithdraw();

        // Record profit/loss used for calculation of redemption price 
        harvest(address(_instrument));

        _instrument.store_internal_balance(); 
        prepareResolveBlock[marketId] = ResolveVar(block.number,true) ;  
      }


    event InstrumentResolve(uint256 indexed marketId, uint256 instrumentBalance, bool atLoss, uint256 extraGain, uint256 totalLoss, bool prematureResolve);
    /// @notice RESOLVE FUNCTION #2
    /// @dev In cases of default, needs to be called AFTER the principal recouperation attempts 
    /// like liquidations, auctions, etc such that the redemption price takes into account the maturity balance
    function resolveInstrument(
        uint256 marketId
    ) external onlyController
    returns(bool, uint256, uint256, bool) {
        Instrument _instrument = Instruments[marketId];
        ResolveVar memory rvar = prepareResolveBlock[marketId]; 
        require(_instrument.isLocked(), "Not Locked");
        require(rvar.isPrepared && rvar.endBlock < block.number, "can't resolve"); 

        uint256 bal = UNDERLYING.balanceOf(address(this)); 
        uint256 instrument_balance = _instrument.getMaturityBalance(); 

        InstrumentData memory data = instrument_data[_instrument];

        bool prematureResolve = resolveBeforeMaturity[marketId]; 
        bool atLoss; 
        uint256 total_loss; 
        uint256 extra_gain; 

        // If resolved at predetermined maturity date, loss is defined by
        // the event the instrument has paid out all its yield + principal 
        if (!prematureResolve){
            atLoss = instrument_balance < data.faceValue;
            total_loss = atLoss ? data.faceValue - instrument_balance : 0;
            extra_gain = !atLoss ? instrument_balance - data.faceValue : 0;
        }

        // If resolved before predetermined maturity date, loss is defined by 
        // the event the instrument has balance less then principal 
        else {
            atLoss = instrument_balance < data.principal; 
            total_loss = atLoss? data.principal - instrument_balance :0; 
        }

        withdrawFromInstrument(_instrument, instrument_balance, true);
        removeInstrument(data.marketId);

        emit InstrumentResolve(marketId, instrument_balance, atLoss, extra_gain, total_loss, prematureResolve);

        return(atLoss, extra_gain, total_loss, prematureResolve); 
    }

    /// @notice when market resolves, send back pulled collateral from managers 
    function repayDebt(address to, uint256 amount) external onlyController{
        UNDERLYING.transfer(to, amount); 
    }

    event InstrumentDeny(uint256 indexed marketId);
    /**
     called on market denial by controller => denied before approval
     */
    function denyInstrument(uint256 marketId) external onlyController {
        InstrumentData storage data = instrument_data[Instruments[marketId]];

        require(marketId > 0 && data.instrument_address != address(0), "invalid instrument");

        require(!data.trusted, "can't deny approved instrument");
        emit InstrumentDeny(marketId);
        removeInstrument(marketId);
    }


    function instrumentApprovalCondition(uint256 marketId) external view returns(bool){
      return Instruments[marketId].instrumentApprovalCondition(); 
    }

    /// TODO 
    function deduct_withdrawal_fees(uint256 amount) internal returns(uint256){
      return amount; 
    }


    /// @notice types of restrictions are: 
    /// a) verified address b) reputation scores 
    function receiver_conditions(address receiver) public view returns(bool){
        return true; 
    }

    /// @notice called when constructed, params set by the creater of the vault 
    function set_minting_conditions(
      bool _onlyVerified, 
      uint256 _r, 
      uint256 _asset_limit,
      uint256 _total_asset_limit) internal{
        onlyVerified = _onlyVerified; 
        r = _r; 
        asset_limit = _asset_limit; 
        total_asset_limit = _total_asset_limit; 
    } 


    function get_vault_params() public view returns(MarketManager.MarketParameters memory){
      return default_params; 
    }


    function beforeWithdraw(uint256 assets, uint256 shares) internal virtual override {
      require(enoughLiqudity(assets), "Not enough liqudity in vault"); 

    }

    /// @notice returns true if the vault has enough balance to withdraw or supply to new instrument
    /// (excluding those supplied to existing instruments)
    /// @dev for now this implies that the vault allows full utilization ratio, but the utilization ratio
    /// should be (soft)maxed and tunable by a parameter 
    function enoughLiqudity(uint256 amounts) public view returns(bool){
        return (UNDERLYING.balanceOf(address(this)) >= amounts); 
    }


    /// @notice function that closes instrument prematurely 
    function closeInstrument(uint256 marketId) external onlyController{
      Instrument instrument = fetchInstrument( marketId); 

      // If instrument has non-underlying tokens, liquidate them first. 
      instrument.liquidateAllPositions(); 

    }

    function viewPrincipalAndYield(uint256 marketId) public view returns(uint256,uint256){
        InstrumentData memory data = instrument_data[Instruments[marketId]];
        return (data.principal, data.expectedYield); 
    }

    /// @notice a minting restrictor is set for different vaults 
    function mint(uint256 shares, address receiver) public virtual override returns (uint256 assets) {
        if (!receiver_conditions(receiver)) revert("Minting Restricted"); 
        assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msg.sender, address(this), assets);
   
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }


    /// @notice apply fee before withdrawing to prevent just minting before maturities and withdrawing after 
     function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        assets = deduct_withdrawal_fees(assets); 

        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }
}