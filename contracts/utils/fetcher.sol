pragma solidity ^0.8.16;

import {MarketManager} from "../protocol/marketmanager.sol";
import {Vault} from "../vaults/vault.sol";
import {VaultFactory} from "../protocol/factories.sol";
import {Controller} from "../protocol/controller.sol";
import {ERC20} from "../vaults/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SyntheticZCBPool} from "../bonds/synthetic.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LinearCurve} from "../bonds/GBC.sol"; 
import {PoolInstrument} from "../instruments/poolInstrument.sol";
import "forge-std/console.sol";

contract Fetcher {
    using FixedPointMathLib for uint256;

    /**
        static => only called on creation of vault or market.
        dynamic => called continuously.
     */
    struct AssetBundle {
        address addr;
        string symbol;
        uint256 decimals;
        string name;
    }

    struct CollateralBundle {
        address tokenAddress;
        uint256 tokenId;
        uint256 decimals;
        uint256 maxAmount;
        uint256 borrowAmount;
        string symbol;
        string name;
        bool isERC20;
    }

    struct ValidatorBundle {
        address[] validators;
        uint256 val_cap;
        uint256 avg_price;
        uint256 totalSales;
        uint256 totalStaked;
        uint256 numApproved;
        uint256 initialStake;
        uint256 finalStake;
        uint256 numResolved;
    }

    // change types
    struct VaultBundle {
        string name;
        uint256 vaultId;
        uint256[] marketIds;
        MarketManager.MarketParameters default_params;
        bool onlyVerified; 
        uint256 r; //reputation ranking  
        uint256 asset_limit; 
        uint256 total_asset_limit;
        AssetBundle want;
        uint256 totalShares;
        address vault_address;
        uint256 exchangeRate;
        uint256 totalAssets;
        uint256 utilizationRate;
        uint256 totalEstimatedAPR; 
        uint256 goalAPR; 
        uint256 totalProtection;
    }

    struct MarketBundle {
        uint256 marketId;
        uint256 vaultId;
        uint256 creationTimestamp;
        address longZCB;
        address shortZCB;
        uint256 approved_principal;
        uint256 approved_yield;
        uint256 totalCollateral; // loggedCollateral
        uint256 longZCBprice;
        uint256 longZCBsupply;
        uint256 redemptionPrice;
        uint256 initialLongZCBPrice;
        bool marketConditionMet;
        SyntheticZCBPool bondPool;
        MarketManager.MarketParameters parameters;
        MarketManager.MarketPhaseData phase;
        ValidatorBundle validatorData;
    }

    struct PoolBundle {
        uint256 saleAmount; 
        uint256 initPrice; // init price of longZCB in the amm 
        uint256 promisedReturn; //per unit time 
        uint256 inceptionTime;
        uint256 inceptionPrice; // init price of longZCB after assessment 
        uint256 leverageFactor; //leverageFactor * manager collateral = capital from vault to instrument
        uint256 managementFee; // sum of discounts for high reputation managers/validators
        uint256 pju;
        uint256 psu;

        // lending pool data
        uint128 totalBorrowedAssets;
        uint128 totalSuppliedAssets;
        uint64 APR;
        CollateralBundle[] collaterals;
        uint256 availablePoolLiquidity; // amount of borrowable in lendingpool
    }

    struct InstrumentBundle {
        uint256 marketId;
        uint256 vaultId;
        address utilizer;
        bool trusted;
        bool isPool;
        uint256 balance;
        uint256 faceValue;
        uint256 principal;
        uint256 expectedYield;
        uint256 duration;
        string description;
        address instrument_address;
        Vault.InstrumentType instrument_type;
        uint256 maturityDate;
        bytes32 name;
        uint256 seniorAPR; 
        uint256 exposurePercentage;
        uint256 managers_stake; 
        uint256 approvalPrice;
        PoolBundle poolData;
    }

    function buildAssetBundle(ERC20 _asset) internal view returns (AssetBundle memory _bundle) {
        _bundle.addr = address(_asset);
        _bundle.symbol = _asset.symbol();
        _bundle.decimals = _asset.decimals();
        _bundle.name = _asset.name();
    }

    /**
     @dev vaultId retrieved from vaultIds public array in controller.
     @notice retrieves all the static data associated with a vaultId.
     */
    function fetchInitial(
        Controller _controller,
        MarketManager _marketManager,
        uint256 vaultId
    ) 
    public 
    view 
    returns (
        VaultBundle memory vaultBundle,
        MarketBundle[] memory marketBundle,
        InstrumentBundle[] memory instrumentBundle,
        uint256 timestamp
    )
    {
        timestamp = block.timestamp;
        // vault bundle
        Vault vault = _controller.vaults(vaultId);

        uint256 one_asset = 10**vault.asset().decimals();

        if (address(vault) == address(0)) {
            return (makeEmptyVaultBundle(), new MarketBundle[](0), new InstrumentBundle[](0), timestamp);
        }
        vaultBundle.vaultId = vaultId;
        vaultBundle.marketIds = _controller.getMarketIds(vaultId);
        vaultBundle.default_params = vault.get_vault_params();
        vaultBundle.onlyVerified = vault.onlyVerified();
        vaultBundle.want = buildAssetBundle(vault.asset());
        vaultBundle.r = vault.r();
        vaultBundle.asset_limit = vault.asset_limit();
        vaultBundle.total_asset_limit = vault.total_asset_limit();
        vaultBundle.totalShares = vault.totalSupply();
        vaultBundle.vault_address = address(vault);
        vaultBundle.name = vault.name();
        vaultBundle.exchangeRate = vault.previewDeposit(one_asset);
        vaultBundle.utilizationRate = vault.utilizationRate();
        vaultBundle.totalAssets = vault.totalAssets(); 

        if (vaultBundle.marketIds.length == 0) {
            return (vaultBundle, new MarketBundle[](0), new InstrumentBundle[](0), timestamp);
        }

        // associated markets
        // (_marketIds, _lowestMarketIndex) = listOfInterestingMarkets(_marketFactory, _offset, _total);
        marketBundle = new MarketBundle[](vaultBundle.marketIds.length);
        instrumentBundle = new InstrumentBundle[](vaultBundle.marketIds.length);

        for (uint256 i; i < vaultBundle.marketIds.length; i++) {
            marketBundle[i] = buildMarketBundle(vaultBundle.marketIds[i], vaultId, _controller, _marketManager);
            
            instrumentBundle[i] = buildInstrumentBundle(vaultBundle.marketIds[i], vaultId, _controller);
            computeInstrumentProfile(vaultBundle.marketIds[i], instrumentBundle[i], _controller, _marketManager);
            
            console.log("instrumentBundle: ", instrumentBundle[i].managers_stake);
            console.log("poolBundle: ", instrumentBundle[i].poolData.saleAmount);
            vaultBundle.totalEstimatedAPR += instrumentBundle[i].seniorAPR.mulWadDown(instrumentBundle[i].exposurePercentage);
            vaultBundle.totalProtection += marketBundle[i].totalCollateral; 
        }
        uint256 goalUtilizationRate = 9e17; //90% utilization goal? 
        if(vaultBundle.totalEstimatedAPR <= goalUtilizationRate)
        vaultBundle.goalAPR = (goalUtilizationRate.divWadDown(1+vaultBundle.utilizationRate)).mulWadDown(vaultBundle.totalEstimatedAPR); 
        else vaultBundle.goalAPR = vaultBundle.totalEstimatedAPR ; 
    }

    function buildInstrumentBundle(uint256 mid, uint256 vid, Controller controller) internal view returns (InstrumentBundle memory bundle) {
        Vault vault = controller.vaults(vid);
        (,address utilizer) = controller.market_data(mid);
        Vault.InstrumentData memory data = vault.fetchInstrumentData(mid);

        bundle.marketId = mid;
        bundle.vaultId = vid;
        bundle.isPool = data.isPool;
        bundle.trusted = data.trusted;
        bundle.balance = data.balance;
        bundle.faceValue = data.faceValue;
        bundle.principal = data.principal;
        bundle.expectedYield = data.expectedYield;
        bundle.duration = data.duration;
        bundle.description = data.description;
        bundle.instrument_type = data.instrument_type;
        bundle.maturityDate = data.maturityDate;
        // bundle.poolData = data.poolData;
        bundle.instrument_address = address(data.instrument_address);
        bundle.utilizer = utilizer;
        bundle.name = data.name;
        if (data.isPool) {
            //bundle.poolData = buildPoolBundle(mid, vid, controller);
        }
    }

    function buildPoolBundle(uint256 mid, uint256 vid, Controller controller) internal view returns (PoolBundle memory bundle) {
        Vault vault = controller.vaults(vid);
        address instrument = address(vault.Instruments(mid));
        Vault.InstrumentData memory instrumentData = vault.fetchInstrumentData(mid);

        bundle.saleAmount = instrumentData.poolData.saleAmount;
        bundle.initPrice = instrumentData.poolData.initPrice;
        bundle.promisedReturn = instrumentData.poolData.promisedReturn;
        bundle.inceptionTime = instrumentData.poolData.inceptionTime;
        bundle.inceptionPrice = instrumentData.poolData.inceptionPrice;
        bundle.leverageFactor = instrumentData.poolData.leverageFactor;
        bundle.managementFee = instrumentData.poolData.managementFee;
        (uint256 psu, uint256 pju, ) = vault.poolZCBValue(mid);
        bundle.psu = psu;
        bundle.pju = pju;

        PoolInstrument.CollateralLabel[] memory labels = PoolInstrument(instrument).getAcceptedCollaterals();
        bundle.availablePoolLiquidity = PoolInstrument(instrument).totalAssetAvailable(); 
        uint256 l = labels.length;
        bundle.collaterals = new CollateralBundle[](l);
        for (uint256 i; i < l; i++) {
            (,
            uint256 maxAmount,
            uint256 maxBorrowAmount,
            bool isERC20) = PoolInstrument(instrument).collateralData(labels[i].tokenAddress, labels[i].tokenId);
            bundle.collaterals[i] = buildCollateralBundle(labels[i].tokenAddress, labels[i].tokenId, maxAmount, maxBorrowAmount, isERC20);
        }
        
        
        (,,uint64 ratePerSec) = PoolInstrument(instrument).currentRateInfo();
        bundle.APR = ratePerSec * 365.24 days;
        (uint128 borrowAmount,) = PoolInstrument(instrument).totalBorrow();
        (uint128 assetAmount,) = PoolInstrument(instrument).totalAsset();
        bundle.totalBorrowedAssets = borrowAmount;
        bundle.totalSuppliedAssets = assetAmount;
    }

    function buildCollateralBundle(address tokenAddress, uint256 tokenId, uint256 maxAmount, uint256 borrowAmount, bool isERC20) internal view returns (CollateralBundle memory bundle) {
        bundle.tokenAddress = tokenAddress;
        bundle.tokenId = tokenId;
        bundle.maxAmount = maxAmount;
        bundle.borrowAmount = borrowAmount;
        bundle.isERC20 = isERC20;
        if (isERC20) {
            bundle.name = ERC20(tokenAddress).name();
            bundle.symbol = ERC20(tokenAddress).symbol();
            bundle.decimals = ERC20(tokenAddress).decimals();
        } else {
            bundle.name = ERC721(tokenAddress).name();
            bundle.symbol = ERC721(tokenAddress).symbol();
        }
    }

    function buildMarketBundle(uint256 mid, uint256 vid, Controller controller, MarketManager marketManager) internal view returns (MarketBundle memory bundle) {
        bundle.marketId = mid;
        bundle.vaultId = vid;
        MarketManager.CoreMarketData memory data = marketManager.getMarket(mid);
        bundle.creationTimestamp = data.creationTimestamp;
        bundle.longZCB = address(data.longZCB);
        bundle.shortZCB = address(data.shortZCB);
        bundle.bondPool = data.bondPool;
        Controller.ApprovalData memory approvalData = controller.getApprovalData(mid);
        bundle.approved_principal = approvalData.approved_principal;
        bundle.approved_yield = approvalData.approved_yield;
        bundle.phase = marketManager.getPhaseData(mid);
        bundle.redemptionPrice = marketManager.redemption_prices(mid);
        bundle.parameters = marketManager.getParameters(mid);
        bundle.totalCollateral = marketManager.loggedCollaterals(mid);
        bundle.longZCBsupply = data.longZCB.totalSupply();
        bundle.longZCBprice = data.bondPool.getCurPrice();
        bundle.validatorData = buildValidatorBundle(mid, controller);
        bundle.initialLongZCBPrice = data.bondPool.b();
        bundle.marketConditionMet = controller.marketCondition(mid);
    }

    function buildValidatorBundle(uint256 mid, Controller controller) view internal returns (ValidatorBundle memory bundle)  {
        bundle.avg_price = controller.getValidatorPrice(mid);
        bundle.validators = controller.viewValidators(mid);
        bundle.totalSales = controller.getTotalValidatorSales(mid);
        bundle.totalStaked = controller.getTotalStaked(mid);
        bundle.numApproved = controller.getNumApproved(mid);
        bundle.initialStake = controller.getInitialStake(mid);
        bundle.finalStake = controller.getFinalStake(mid);
        bundle.numResolved = controller.getNumResolved(mid);
        bundle.val_cap = controller.getValidatorCap(mid);
    }

// (uint256 managers_stake, uint256 exposurePercentage, uint256 seniorAPR, uint256 approvalPrice)
    function computeInstrumentProfile(
        uint256 mid, 
        InstrumentBundle memory bundle, 
        Controller controller, 
        MarketManager marketmanager
        ) internal view {
        // get senior instrument apr, approval price, manager's stake, 
        MarketManager.CoreMarketData memory data = marketmanager.getMarket(mid); 
        Controller.ApprovalData memory approvalData = controller.getApprovalData(mid); 
        bundle.managers_stake = approvalData.managers_stake;
        bundle.exposurePercentage = (approvalData.approved_principal- approvalData.managers_stake).divWadDown(
            controller.getVault(mid).totalAssets()+1);

        if(!bundle.isPool){
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
            
            uint256 seniorYield = bundle.faceValue -amountDelta
                - (bundle.principal - approvalData.managers_stake); 

            bundle.seniorAPR = approvalData.approved_principal>0
                ? seniorYield.divWadDown(1+bundle.principal - approvalData.managers_stake)
                : 0; 
            bundle.approvalPrice = resultPrice; 
        }
        else{
            bundle.seniorAPR = bundle.poolData.promisedReturn; 
            bundle.approvalPrice = bundle.poolData.inceptionPrice; 
        }

    }

    function makeEmptyVaultBundle() pure internal returns (VaultBundle memory) {
        return VaultBundle(
            "",
            0,
            new uint256[](0),
            MarketManager.MarketParameters(0,0,0,0,0,0,0,0),
            false,
            0,
            0,
            0,
            AssetBundle(address(0), "", 0, ""),
            0,
            address(0),
            0,
            0,
            0, 
            0,0,0
        );
    }
}