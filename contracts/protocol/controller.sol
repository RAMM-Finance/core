pragma solidity ^0.8.16;
import {MarketManager} from "./marketmanager.sol";
import {Vault} from "../vaults/vault.sol";
import {Instrument} from "../vaults/instrument.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {VaultFactory} from "./factories.sol";
import "forge-std/console.sol";
import {config} from "../utils/helpers.sol";
import "openzeppelin-contracts/utils/math/SafeMath.sol";
import {ERC4626} from "../vaults/mixins/ERC4626.sol";
import {Vault} from "../vaults/vault.sol";
import {SyntheticZCBPoolFactory, ZCBFactory} from "./factories.sol";
import {ReputationManager} from "./reputationmanager.sol";
import {PoolInstrument} from "../instruments/poolInstrument.sol";
import {LinearCurve} from "../bonds/GBC.sol"; 
import {LeverageManager} from "./leveragemanager.sol"; 
import {OrderManager} from "./ordermanager.sol"; 
import {ValidatorManager} from "./validatorManager.sol";

import "../global/GlobalStorage.sol"; 
import "../global/types.sol"; 
import {PerpTranchePricer} from "../libraries/pricerLib.sol"; 

contract Controller {
    using SafeMath for uint256;
    using FixedPointMathLib for uint256;
    using PerpTranchePricer for PricingInfo; 


    ValidatorManager validatorManager;

    mapping(uint256 => ApprovalData) approvalDatas;

    function getApprovalData(uint256 marketId)
        public
        view
        returns (ApprovalData memory data)
    {
        data = approvalDatas[marketId];
    }

    mapping(address => bool) public verified;
    mapping(uint256 => MarketData) public market_data; // id => recipient
    mapping(address => uint256) public ad_to_id; //utilizer address to marketId
    mapping(uint256 => Vault) public vaults; // vault id to Vault contract
    mapping(uint256 => uint256) public id_parent; //marketId-> vaultId
    mapping(uint256 => uint256[]) public vault_to_marketIds;

    address creator_address;

    // IInterep interep;
    MarketManager public marketManager;
    VaultFactory public vaultFactory;
    SyntheticZCBPoolFactory public poolFactory;
    ReputationManager public reputationManager;
    LeverageManager public leverageManager; 
    StorageHandler public Data; 
    OrderManager public orderManager; 

    /* ========== MODIFIERS ========== */
    modifier onlyValidator(uint256 marketId) {
        require(
            isValidator(marketId, msg.sender) || msg.sender == creator_address,
            "!Val"
        );
        _;
    }

    modifier onlyManager() {
        require(
            msg.sender == address(marketManager) 
            || msg.sender == address(leverageManager)
            || msg.sender == address(orderManager)
            || msg.sender == creator_address,
            "!manager"
        );
        _;
    }

    constructor(
        address _creator_address,
        address _interep_address //TODO
    ) {
        creator_address = _creator_address;
    }

    /*----Setup Functions----*/

    /**
    abi.encode(
        marketManager, 
        reputationManager, 
        validatorManager, 
        leverageManager, 
        orderManager,
        vaultFactory,
        poolFactory,
        dataStore
        )
     */
    function initialize(
        bytes calldata _setup
    ) external {
        require(address(msg.sender) == address(creator_address));
        (
            address _marketManager,
            address _reputationManager,
            address _validatorManager,
            address _leverageManager,
            address _orderManager,
            address _vaultFactory,
            address _poolFactory,
            address _dataStore
        ) = abi.decode(_setup, (
            address,
            address,
            address,
            address,
            address,
            address,
            address,
            address
        ));

        marketManager = MarketManager(_marketManager);
        reputationManager = ReputationManager(_reputationManager);
        marketManager.setReputationManager(_reputationManager);
        validatorManager = ValidatorManager(_validatorManager);
        leverageManager = LeverageManager(_leverageManager); 
        marketManager.setLeverageManager(_leverageManager); 
        orderManager = OrderManager(_orderManager);
        vaultFactory = VaultFactory(_vaultFactory);
        poolFactory = SyntheticZCBPoolFactory(_poolFactory);
        Data = StorageHandler(_dataStore); 
        marketManager.setDataStore( _dataStore); 
        reputationManager.setDataStore( _dataStore);
        leverageManager.setDataStore(_dataStore);
        orderManager.setDataStore(_dataStore); 
    }

    // function setMarketManager(address _marketManager) public onlyManager {
    //     require(_marketManager != address(0));
    //     marketManager = MarketManager(_marketManager);
        
    // }

    // function setReputationManager(address _reputationManager)
    //     public
    //     onlyManager
    // {   require(address(marketManager)!= address(0), "0mm"); 
    //     reputationManager = ReputationManager(_reputationManager);
    //     marketManager.setReputationManager(_reputationManager); 
    // }

    // function setValidatorManager(address _validatorManager) public onlyManager {
    //     validatorManager = ValidatorManager(_validatorManager);
    // }

    // function setLeverageManager(address _leverageManager) public onlyManager{
    //     leverageManager = LeverageManager(_leverageManager); 
    //     marketManager.setLeverageManager(_leverageManager); 
    // }

    // function setOrderManager(address _orderManager) public onlyManager{
    //     orderManager = OrderManager(_orderManager); 
    // }

    // function setVaultFactory(address _vaultFactory) public onlyManager {
    //     vaultFactory = VaultFactory(_vaultFactory);
    // }

    // function setPoolFactory(address _poolFactory) public onlyManager {
    //     poolFactory = SyntheticZCBPoolFactory(_poolFactory);
    // }
    // function setDataStore(address _dataStore) public onlyManager{
    //     Data = StorageHandler(_dataStore); 
    //     marketManager.setDataStore( _dataStore); 
    //     reputationManager.setDataStore( _dataStore);
    //     leverageManager.setDataStore(_dataStore);
    //     orderManager.setDataStore(_dataStore); 

    // }

    // function storeNewPrices(uint256 marketId, uint256 multiplier, uint256 initPrice) public {
    //     Data.setNewPricingInfo( marketId,  initPrice,  multiplier); 
    //     // data.PriceInfos(marketId).setNewPrices(initPrice, multiplier, marketId); 
    // }


    // function verifyAddress(
    //     uint256 nullifier_hash,
    //     uint256 external_nullifier,
    //     uint256[8] calldata proof
    // ) external  {
    //     require(!verified[msg.sender], "address already verified");
    //     interep.verifyProof(TWITTER_UNRATED_GROUP_ID, signal, nullifier_hash, external_nullifier, proof);
    //     verified[msg.sender] = true;
    // }
    // bool public selfVerify = true; 
    // function canSelfVerify() external {
    //     require(msg.sender == creator_address, "!auth"); 
    //     selfVerify = !selfVerify; 
    // }

    function verifyAddress(address who) external{
        require(msg.sender == creator_address, "!auth"); 
        verified[who] = true;
        reputationManager.setTraderScore(who, 1e18); 
    }


    // function testVerifyAddress() external {
    //     require(selfVerify, "!selfVerify"); 
    //     verified[msg.sender] = true;
    //     reputationManager.setTraderScore(msg.sender, 1e18); 
    // }

    event RedeemTransfer(uint256 indexed marketId, uint256 amount, address to);


    event VaultCreated(address indexed vault, uint256 vaultId, address underlying, bool onlyVerified, uint256 r, uint256 assetLimit, uint256 totalAssetLimit, MarketParameters defaultParams);
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
        MarketParameters memory default_params,
        string calldata _description
    ) public {
        (Vault newVault, uint256 vaultId) = vaultFactory.newVault(
            underlying,
            address(this),
            abi.encode(_onlyVerified, _r, _asset_limit, _total_asset_limit,_description),
            default_params  
        );

        vaults[vaultId] = newVault;

        emit VaultCreated(address(newVault), vaultId, underlying, _onlyVerified, _r, _asset_limit, _total_asset_limit, default_params);
    }

    function getInstrumentSnapShot(uint256 marketId) view public returns (uint256 managerStake, uint256 exposurePercentage, uint256 seniorAPR, uint256 approvalPrice) {
        CoreMarketData memory data = marketManager.getMarket(marketId); 
        ApprovalData memory approvalData = getApprovalData(marketId); 
        InstrumentData memory instrumentData = getVault(marketId).fetchInstrumentData(marketId);
        managerStake = approvalData.managers_stake;
        exposurePercentage = (approvalData.approved_principal- approvalData.managers_stake).divWadDown(getVault(marketId).totalAssets()+1);
        seniorAPR = instrumentData.poolData.promisedReturn; 
        approvalPrice = instrumentData.poolData.inceptionPrice; 

        if(!instrumentData.isPool){
            uint256 amountDelta;
            uint256 resultPrice;

            if(approvalData.managers_stake>0){
                ( amountDelta,  resultPrice) = LinearCurve.amountOutGivenIn(
                approvalData.managers_stake,
                0, 
                data.bondPool.a_initial(), 
                data.bondPool.b(), 
                true 
                );
            }
            
            uint256 seniorYield = instrumentData.faceValue -amountDelta
                - (instrumentData.principal - approvalData.managers_stake); 

            seniorAPR = approvalData.approved_principal>0
                ? seniorYield.divWadDown(1+instrumentData.principal - approvalData.managers_stake)
                : 0; 
            approvalPrice = resultPrice; 
        }
    }

    function getVaultSnapShot(uint256 vaultId) view external returns (uint256 totalProtection, uint256 totalEstimatedAPR, uint256 goalAPR, uint256 exchangeRate) {
        uint256[] memory marketIds = vault_to_marketIds[vaultId];
        for (uint256 i = 0; i < marketIds.length; i++) {
            (,uint256 exposurePercentage, uint256 seniorAPR,) = getInstrumentSnapShot(marketIds[i]);
            totalEstimatedAPR += exposurePercentage.mulWadDown(seniorAPR);
            totalProtection += marketManager.loggedCollaterals(marketIds[i]);
        }

        Vault vault = vaults[vaultId];

        uint256 goalUtilizationRate = 9e17; //90% utilization goal? 
        if(vault.utilizationRate() <= goalUtilizationRate)
         goalAPR = (goalUtilizationRate.divWadDown(1+vault.utilizationRate())).mulWadDown(totalEstimatedAPR); 
        else goalAPR = totalEstimatedAPR;

        exchangeRate = vault.previewDeposit(1e18);
    }

    event MarketInitiated(uint256 indexed marketId, address indexed vault, address indexed recipient, address pool, address longZCB, address shortZCB, InstrumentData instrumentData);

    /// @notice initiates market, called by frontend loan proposal or instrument form submit button.
    /// @dev Instrument should already be deployed
    /// @param recipient: utilizer for the associated instrument
    /// @param instrumentData: instrument arguments
    /// @param vaultId: vault identifier
    function initiateMarket(
        address recipient,
        InstrumentData memory instrumentData,
        uint256 vaultId
    ) external {
        require(recipient != address(0), "address0R");
        require(instrumentData.instrument_address != address(0), "address0I");
        require(address(vaults[vaultId]) != address(0), "address0V");

        Vault vault = vaults[vaultId];
        uint256 marketId = marketManager.marketCount();
        id_parent[marketId] = vaultId;
        vault_to_marketIds[vaultId].push(marketId);
        market_data[marketId] = MarketData(
            instrumentData.instrument_address,
            recipient
        );
        marketManager.setParameters(
            vault.get_vault_params(),
            vault.utilizationRate(),
            marketId
        ); //TODO non-default

        // Create new pool and bonds and store initial price and liquidity for the pool
        (address longZCB, address shortZCB, SyntheticZCBPool pool) = poolFactory
            .newPool(
                address(vaults[vaultId].UNDERLYING()),
                address(marketManager)
            );

        CoreMarketData memory marketData; 
        if (instrumentData.isPool) {
          require(instrumentData.poolData.initPrice<= 1e18 
            && instrumentData.poolData.initPrice< instrumentData.poolData.inceptionPrice, "PRICE ERR"); 
          require(instrumentData.poolData.promisedReturn>0, "RETURN ERR"); 
          instrumentData.poolData.inceptionTime = block.timestamp;

          instrumentData.poolData.managementFee = pool
            .calculateInitCurveParamsPool(
                instrumentData.poolData.saleAmount,
                instrumentData.poolData.initPrice,
                instrumentData.poolData.inceptionPrice,
                marketManager.getParameters(marketId).sigma
            );

            marketManager.newMarket(
            marketId,
            pool,
            longZCB,
            shortZCB,
            instrumentData.description,
            true
            );
            marketData = CoreMarketData(
                pool,
                ERC20(longZCB),
                ERC20(shortZCB),
                instrumentData.description,
                block.timestamp, 
                0, 
                true
            ); 

          // set validators
          validatorManager.validatorSetup(
            marketId,
            instrumentData.poolData.saleAmount,
            instrumentData.isPool
        );
        } else {
            MarketParameters memory params = marketManager.getParameters(marketId); 
            pool.calculateInitCurveParams(
                instrumentData.principal,
                instrumentData.expectedYield,
                params.sigma, 
                params.alpha, 
                params.delta
            );

            marketManager.newMarket(
                marketId,
                pool,
                longZCB,
                shortZCB,
                instrumentData.description,
                false
            );         
            marketData = CoreMarketData(
                pool,
                ERC20(longZCB),
                ERC20(shortZCB),
                instrumentData.description,
                block.timestamp, 
                0, 
                false
            ); 

            // set validators
            validatorManager.validatorSetup(
                marketId,
                instrumentData.principal,
                instrumentData.isPool
            );
        }
        // Data.storeNewMarket(marketData); 
        Data.setNewInstrument(
         Data.storeNewMarket(marketData), 
         instrumentData.poolData.inceptionPrice, 
         0, //TODO configurable 
         true, 
         instrumentData, 
         marketData); // TODO more params 

        // add vault proposal
        instrumentData.marketId = marketId;
        vault.addProposal(instrumentData);

        emit MarketInitiated(marketId, address(vaults[vaultId]), recipient, address(pool), longZCB, shortZCB, instrumentData);

        ad_to_id[recipient] = marketId; //only for testing purposes, one utilizer should be able to create multiple markets
    }

    /// @notice Resolve function 1
    /// @dev Prepare market/instrument for closing, called separately before resolveMarket
    /// this is either called automatically from the instrument when conditions are met i.e fully repaid principal + interest
    /// or, in the event of a default, by validators who deem the principal recouperation is finished
    /// and need to collect remaining funds by redeeming ZCB
    function beforeResolve(uint256 marketId) external //onlyValidator(marketId)
    {
        (bool duringMarketAssessment, , , bool alive, , ) = marketManager
            .restriction_data(marketId);
        require(!duringMarketAssessment && alive, "market conditions not met");
        require(
            resolveCondition(marketId),
            "not enough validators have voted to resolve"
        );
        vaults[id_parent[marketId]].beforeResolve(marketId);
    }

    event MarketResolved(uint256 indexed marketId, bool atLoss, uint256 extraGain, uint256 principalLoss, bool premature);

    /// Resolve function 2
    /// @notice main function called at maturity OR premature resolve of instrument(from early default)
    /// @dev validators call this function from market manager
    /// any funds left for the instrument, irrespective of whether it is in profit or inloss.
    function resolveMarket(uint256 marketId) external onlyValidator(marketId) {
        (
            bool atLoss,
            uint256 extra_gain,
            uint256 principal_loss,
            bool premature
        ) = getVault(marketId).resolveInstrument(marketId);
        // TODO updating if only market is pool. 
        updateRedemptionPrice(
            marketId,
            atLoss,
            extra_gain,
            principal_loss,
            premature
        );
        validatorManager.updateValidatorStake(
            marketId,
            approvalDatas[marketId].approved_principal,
            principal_loss
        );

        // Send all funds from the AMM to here, used for
        cleanUpDust(marketId);

        emit MarketResolved(marketId, atLoss, extra_gain, principal_loss, premature);
    }

    /// @dev Redemption price, as calculated (only once) at maturity for fixed term instruments,
    /// depends on total_repayed/(principal + predetermined yield)
    /// If total_repayed = 0, redemption price is 0
    /// @param atLoss: defines circumstances where expected returns are higher than actual
    /// @param loss: facevalue - returned amount => non-negative always?
    /// @param extra_gain: any extra yield not factored during assessment. Is 0 yield is as expected
    function updateRedemptionPrice(
        uint256 marketId,
        bool atLoss,
        uint256 extra_gain,
        uint256 loss,
        bool premature
    ) internal {
  
        if (atLoss) assert(extra_gain == 0);

        uint256 total_supply = marketManager.getZCB(marketId).totalSupply();
        uint256 total_shorts = marketManager.getShortZCB(marketId).totalSupply(); 

        uint256 redemption_price;
        if(premature && extra_gain>0){
            redemption_price = calcIncompleteReturns(marketId, extra_gain); 
        } else{
            if (!atLoss)
                redemption_price = config.WAD +extra_gain.divWadDown(total_supply + total_shorts);
            else {
                if (config.WAD <= loss.divWadDown(total_supply)) {
                    redemption_price = 0;
                } else {
                    redemption_price = config.WAD - loss.divWadDown(total_supply);
                }
            }
        }

        // Get funds used for redemption
        getVault(marketId).trusted_transfer((total_supply - total_shorts).mulWadDown(redemption_price), 
            address(this)); 

        marketManager.deactivateMarket(
            marketId,
            atLoss,
            !premature,
            redemption_price
        );
    }

    uint256 constant leverageFactor = 3e18; 
    /// @notice redeeming function for fixed instruements that did not pay off at maturity
    function calcIncompleteReturns(
        uint256 marketId, 
        uint256 incompleteReturns
        ) public view returns(uint256 seniorReturn){
        uint256 totalJuniorCollateral = marketManager.loggedCollaterals(marketId); 
        uint256 principal = getVault(marketId).fetchInstrumentData(marketId).principal; 

        seniorReturn = principal.mulWadDown(incompleteReturns).divWadDown(
          leverageFactor.mulWadDown(totalJuniorCollateral) + principal - totalJuniorCollateral); 
    }



    /// @notice function that closes the instrument/market before maturity, maybe to realize gains/cut losses fast
    /// or debt is prematurely fully repaid, or underlying strategy is deemed dangerous, etc.
    /// After, the resolveMarket function should be called in a new block
    /// @dev withdraws all balance from the instrument.
    /// If assets in instrument is not in underlying, need all balances to be divested to underlying
    /// Ideally this should be called by several validators, maybe implement a voting scheme and have a keeper call it.
    /// @param emergency ascribes cases where the instrument should be forcefully liquidated back to the vault
    function forceCloseInstrument(uint256 marketId, bool emergency)
        external
        returns (bool)
    {
        Vault vault = vaults[id_parent[marketId]];

        // Prepare for close
        vault.closeInstrument(marketId);

        // Harvests/records all profit & losses
        vault.beforeResolve(marketId);
        return true;
    }

    /// @notice returns true if amount bought is greater than the insurance threshold
    function marketCondition(uint256 marketId) public view returns (bool) {
        (, , , , , , bool isPool) = marketManager.markets(marketId);

        // TODO add vault balances as well 
        if (isPool) {
            return (marketManager.loggedCollaterals(marketId) >=
                getVault(marketId)
                    .fetchInstrumentData(marketId)
                    .poolData
                    .saleAmount);
            console.log('marketcondition', marketManager.loggedCollaterals(marketId), 
               getVault(marketId)
                    .fetchInstrumentData(marketId)
                    .poolData
                    .saleAmount); 
        } else {
            uint256 principal = getVault(marketId)
                .fetchInstrumentData(marketId)
                .principal;
                console.log('marketcondition', marketManager.loggedCollaterals(marketId), 
                principal.mulWadDown(
                    marketManager.getParameters(marketId).alpha
                )); 
            return (marketManager.loggedCollaterals(marketId) >=
                principal.mulWadDown(
                    marketManager.getParameters(marketId).alpha
                ));
        }
    }

    /// Approve without validators 
    // function testApproveMarket(uint256 marketId) external {
    //     require(msg.sender == creator_address, "!owner");
    //     require(marketCondition(marketId), "market condition not met");
    //     approveMarket(marketId); 
    // }

    event MarketApproved(uint256 indexed marketId, ApprovalData data);

    /// @notice called by the validator from validatorApprove when market conditions are met
    /// need to move the collateral in the wCollateral to
    function approveMarket(uint256 marketId) public {
        require(msg.sender == address(validatorManager) || msg.sender == creator_address, "!validator");
        Vault vault = vaults[id_parent[marketId]];
        SyntheticZCBPool pool = marketManager.getPool(marketId);

        require(marketManager.getCurrentMarketPhase(marketId) == 3, "!marketCondition");
        require(vault.instrumentApprovalCondition(marketId),"!instrumentCondition");
        marketManager.approveMarket(marketId);

        (, , , , , , bool isPool) = marketManager.markets(marketId);
        uint256 managerCollateral = marketManager.loggedCollaterals(marketId);
        console.log("managerCollateral: ", managerCollateral, pool.baseBal());
        console.log('?????', Data.getMarket(marketId).longZCB.totalSupply()-Data.getMarket(marketId).shortZCB.totalSupply()); 

        pool.flush(address(this), pool.baseBal()); 
        address instrument = address(vault.fetchInstrument(marketId)); 
        vault.UNDERLYING().approve(instrument, managerCollateral); 

        if (isPool) {
            poolApproval(
                marketId,
                marketManager.getZCB(marketId).totalSupply(),
                vault.fetchInstrumentData(marketId).poolData
            );
          require(ERC4626(instrument).deposit(managerCollateral, address(vault))>0, "DEPOSIT_FAILED");
        } else {
            if (vault.getInstrumentType(marketId) == 0) creditApproval(marketId, pool);
            else generalApproval(marketId);
            vault.UNDERLYING().transfer(instrument, managerCollateral); 
        }
        approvalDatas[marketId].managers_stake = managerCollateral;

        // TODO vault exchange rate should not change
        // pull from pool to vault, which will be used to fund the instrument

        // Trust and deposit to the instrument contract

        vault.trustInstrument(marketId, approvalDatas[marketId], isPool);
        
        emit MarketApproved(marketId, approvalDatas[marketId]);
    }

    function poolApproval(
        uint256 marketId,
        uint256 juniorSupply,
        PoolData memory data
    ) internal {
        require(data.leverageFactor > 0, "0 LEV_FACTOR");
        approvalDatas[marketId] = ApprovalData(
            0,
            juniorSupply
                .mulWadDown(config.WAD + data.leverageFactor)
                .mulWadDown(data.inceptionPrice),
            0
        );

    }

    /// @notice receives necessary market information. Only applicable for creditlines
    /// required for market approval such as max principal, quoted interest rate
    function creditApproval(uint256 marketId, SyntheticZCBPool pool) internal {
        (uint256 proposed_principal, uint256 proposed_yield) = vaults[id_parent[marketId]].viewPrincipalAndYield(marketId);

        // get max_principal which is (s+1) * total long bought for creditline, or just be
        // proposed principal for other instruments
        uint256 max_principal = min(
            (marketManager.getParameters(marketId).s + config.WAD).mulWadDown(
                marketManager.loggedCollaterals(marketId)
            ),
            proposed_principal
        );

        // Required notional yield amount denominated in underlying  given credit determined by managers
        uint256 quoted_interest = min(
            pool.areaBetweenCurveAndMax(max_principal),
            proposed_yield
        );

        approvalDatas[marketId] = ApprovalData(
            0,
            max_principal,
            quoted_interest
        );
    }

    function generalApproval(uint256 marketId) internal {
        (uint256 proposed_principal, uint256 proposed_yield) = vaults[
            id_parent[marketId]
        ].viewPrincipalAndYield(marketId);
        approvalDatas[marketId] = ApprovalData(
            0,
            proposed_principal,
            proposed_yield
        );
    }

    event MarketDenied(uint256 indexed marketId);

    function denyMarket(uint256 marketId) external onlyValidator(marketId) {
        vaults[id_parent[marketId]].denyInstrument(marketId);
        cleanUpDust(marketId);
        marketManager.denyMarket(marketId);
        emit MarketDenied(marketId);
    }

    /// @notice When market resolves, should collect remaining liquidity and/or dust from
    /// the pool and send them back to the vault
    /// @dev should be called before redeem_transfer is allowed
    function cleanUpDust(uint256 marketId) internal {
        marketManager.getPool(marketId).flush(address(this) , type(uint256).max);
    }

    function pullLeverage(uint256 marketId, uint256 amount) external onlyManager{
        Vault vault = getVault(marketId); 
        vault.trusted_transfer(amount, msg.sender);
        vault.modifyInstrumentHoldings(true, amount); 
    }
    function pushLeverage(uint256 marketId, uint256 amount) external onlyManager{
        Vault vault = getVault(marketId); 
        vault.UNDERLYING().transfer(address(vault), amount); 
        vault.modifyInstrumentHoldings(false, amount); 
    }

    function returnLeverageCapital(uint256 marketId, uint256 amount) external  onlyValidator(marketId){

    }// need to repay to vault everytime some is returned

    function dustToVault(uint256 marketId, uint256 amount) external onlyValidator(marketId){
        Vault vault = getVault(marketId);
        vault.UNDERLYING().transfer(address(vault), amount); 
    }

    /// @notice called only when redeeming, transfer funds from vault
    function redeem_transfer(
        uint256 amount,
        address to,
        uint256 marketId
    ) external onlyManager {
        getVault(marketId).UNDERLYING().transfer(to, amount); 
        emit RedeemTransfer(marketId, amount, to);
    }

    // function getValidatorPrice(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getValidatorPrice(marketId);
    //     //return validator_data[marketId].avg_price;
    // }

    // function getValidatorCap(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getValidatorCap(marketId);
    //     //return validator_data[marketId].val_cap;
    // }

    // function viewValidators(uint256 marketId)
    //     public
    //     view
    //     returns (address[] memory)
    // {
    //     return validatorManager.viewValidators(marketId);
    //     //return validator_data[marketId].validators;
    // }

    // function getNumApproved(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getNumApproved(marketId);
    //     //return validator_data[marketId].numApproved;
    // }

    // function getNumResolved(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getNumResolved(marketId);
    //     //return validator_data[marketId].numResolved;
    // }

    // function getTotalStaked(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getTotalStaked(marketId);
    //     //return validator_data[marketId].totalStaked;
    // }

    // function getTotalValidatorSales(uint256 marketId)
    //     public
    //     view
    //     returns (uint256)
    // {
    //     return validatorManager.getTotalValidatorSales(marketId);
    //     //return validator_data[marketId].totalSales;
    // }

    // function getInitialStake(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getInitialStake(marketId);
    //     //return validator_data[marketId].initialStake;
    // }

    // function getFinalStake(uint256 marketId) public view returns (uint256) {
    //     return validatorManager.getFinalStake(marketId);
    //     //return validator_data[marketId].finalStake;
    // }


    /**
   @notice chainlink callback function, sets validators.
   @dev TODO => can be called by anyone?
   */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords //internal
    ) public //override
    {
        validatorManager.fulfillRandomWords(requestId, randomWords);
        // uint256 marketId = requestToMarketId[requestId];
        // (uint256 N, , , , , uint256 r, , ) = marketManager.parameters(marketId);

        // assert(randomWords.length == N);

        // // address instrument = market_data[marketId].instrument_address;
        // address utilizer = market_data[marketId].utilizer;

        // address[] memory temp = reputationManager.filterTraders(r, utilizer);
        // uint256 length = temp.length;

        // // get validators
        // for (uint8 i = 0; i < N; i++) {
        //     uint256 j = _weightedRetrieve(temp, length, randomWords[i]);
        //     validator_data[marketId].validators.push(temp[j]);
        //     temp[j] = temp[length - 1];
        //     length--;
        // }
    }


    /// @notice allows validators to buy at a discount + automatically stake a percentage of the principal
    /// They can only buy a fixed amount of ZCB, usually a at lot larger amount
    /// @dev get val_cap, the total amount of zcb for sale and each validators should buy
    /// val_cap/num validators zcb
    /// They also need to hold the corresponding vault, so they are incentivized to assess at a systemic level and avoid highly
    /// correlated instruments triggers controller.approveMarket
    function validatorApprove(uint256 marketId) external returns (uint256) {
        
        (uint256 collateral_required, uint256 zcb_for_sale) = validatorManager.validatorApprove(marketId, msg.sender);
        // marketManager actions on validatorApprove, transfers collateral to marketManager.
        marketManager.validatorApprove(
            marketId,
            collateral_required,
            zcb_for_sale,
            msg.sender
        );

        // Last validator pays more gas, is fair because earlier validators are more uncertain
        if (approvalCondition(marketId)) {
            approveMarket(marketId);
            marketManager.approveMarket(marketId); // For market to go to a post assessment stage there always needs to be a lower bound set
        }

        return collateral_required;
    }

    /**
   @notice conditions for approval => validator zcb stake fulfilled + validators have all approved
   */
    function approvalCondition(uint256 marketId) public view returns (bool) {
        return validatorManager.approvalCondition(marketId);
        // return (validator_data[marketId].totalSales >=
        //     validator_data[marketId].val_cap &&
        //     validator_data[marketId].validators.length ==
        //     validator_data[marketId].numApproved);
    }

    /**
   @notice returns true if user is validator for corresponding market
   */
    function isValidator(uint256 marketId, address user)
        public
        view
        returns (bool)
    {
        return validatorManager.isValidator(marketId, user);
    }

    /**
   @notice condition for resolving market, met when all the validators chosen for the market
   have voted to resolve.
   */
    function resolveCondition(uint256 marketId) public view returns (bool) {
        return validatorManager.resolveCondition(marketId);
        // return (validator_data[marketId].numResolved ==
        //     validator_data[marketId].validators.length);
    }

 
    function validatorResolve(uint256 marketId) external {
        validatorManager.validatorResolve(marketId, msg.sender);
        // require(isValidator(marketId, msg.sender), "!val");
        // require(!validator_data[marketId].resolved[msg.sender], "voted");

        // validator_data[marketId].resolved[msg.sender] = true;
        // validator_data[marketId].numResolved++;
    }

 
    function unlockValidatorStake(uint256 marketId) external {
        validatorManager.unlockValidatorStake(marketId, msg.sender);
        // require(isValidator(marketId, msg.sender), "!validator");
        // require(validator_data[marketId].staked[msg.sender], "!stake");
        // (bool duringMarketAssessment, , , , , ) = marketManager
        //     .restriction_data(marketId);

        // // market early denial, no loss.
        // ERC4626 vault = ERC4626(vaults[id_parent[marketId]]);
        // if (duringMarketAssessment) {
        //     ERC20(getVaultAd(marketId)).safeTransfer(
        //         msg.sender,
        //         validator_data[marketId].initialStake
        //     );
        //     validator_data[marketId].totalStaked -= validator_data[marketId]
        //         .initialStake;
        // } else {
        //     // market resolved.
        //     ERC20(getVaultAd(marketId)).safeTransfer(
        //         msg.sender,
        //         validator_data[marketId].finalStake
        //     );
        //     validator_data[marketId].totalStaked -= validator_data[marketId]
        //         .finalStake;
        // }

        // validator_data[marketId].staked[msg.sender] = false;
    }



    function hasApproved(uint256 marketId, address validator)
        public
        view
        returns (bool)
    {
        return validatorManager.hasApproved(marketId, validator);
        // return validator_data[marketId].staked[validator];
    }

    /**
   @notice called by marketManager.redeemDeniedMarket, redeems the discounted ZCB
   */
    function deniedValidator(uint256 marketId, address validator)
        external
        onlyManager
        returns (uint256 collateral_amount)
    {
        collateral_amount = validatorManager.deniedValidator(
            marketId,
            validator
        );
        //??? is this correct
        // collateral_amount = validator_data[marketId]
        //     .sales[validator]
        //     .mulWadDown(validator_data[marketId].avg_price);
        // delete validator_data[marketId].sales[validator];
    }

    function redeemValidator(uint256 marketId, address validator)
        external
        onlyManager
    {
        validatorManager.redeemValidator(
            marketId,
            validator
        );
        //delete validator_data[marketId].sales[validator];
    }

    function getValidatorRequiredCollateral(uint256 marketId)
        public
        view
        returns (uint256)
    {
        return validatorManager.getValidatorRequiredCollateral(marketId);
        // uint256 val_cap = validator_data[marketId].val_cap;
        // (uint256 N, , , , , , , ) = marketManager.parameters(marketId);
        // uint256 zcb_for_sale = val_cap / N;
        // return zcb_for_sale.mulWadDown(validator_data[marketId].avg_price);
    }

    function getTraderScore(address trader) public view returns (uint256) {
        return reputationManager.trader_scores(trader);
    }

    function isReputable(address trader, uint256 r) public view returns (bool) {
      return reputationManager.isReputable(trader, r);
    }


    function getTotalSupply(uint256 marketId) external view returns (uint256) {
        return marketManager.getZCB(marketId).totalSupply();
    }

    function getMarketId(address recipient) public view returns (uint256) {
        return ad_to_id[recipient];
    }

    function getVault(uint256 marketId) public view returns (Vault) {
        return vaults[id_parent[marketId]];
    }

    function getVaultAd(uint256 marketId) public view returns (address) {
        return address(vaults[id_parent[marketId]]);
    }

    function isVerified(address addr) public view returns (bool) {
        return verified[addr];
    }

    function getVaultfromId(uint256 vaultId) public view returns (address) {
        return address(vaults[vaultId]);
    }

    function marketId_to_vaultId(uint256 marketId)
        public
        view
        returns (uint256)
    {
        return id_parent[marketId];
    }

    function marketIdToVaultId(uint256 marketId) public view returns (uint256) {
        return id_parent[marketId];
    }

    function getMarketIds(uint256 vaultId)
        public
        view
        returns (uint256[] memory)
    {
        return vault_to_marketIds[vaultId];
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
}
