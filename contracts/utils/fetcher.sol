pragma solidity ^0.8.16;

import {MarketManager} from "../protocol/marketmanager.sol";
import {Vault} from "../vaults/vault.sol";
import {VaultFactory} from "../protocol/factories.sol";
import {Controller} from "../protocol/controller.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LinearCurve} from "../bonds/GBC.sol"; 
import {PoolInstrument} from "../instruments/poolInstrument.sol";

import "forge-std/console.sol";
import {CoveredCallOTC} from "../vaults/dov.sol";
import { CreditLine } from "../vaults/instrument.sol";

import "../global/types.sol"; 

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
        uint256 totalCollateral; //only for ERC20.
        string symbol;
        string name;
        bool isERC20;
        address owner; // only for ERC721.
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
        string symbol;
        string description;
        uint256 vaultId;
        uint256[] marketIds;
        MarketParameters default_params;
        bool onlyVerified; 
        uint256 r; //reputation ranking  
        uint256 asset_limit; 
        uint256 total_asset_limit;
        AssetBundle want;
        uint256 totalShares;
        uint256 totalAssets;
        address vault_address;
        uint256 exchangeRate;
        uint256 utilizationRate;
        uint256 totalEstimatedAPR; 
        uint256 goalAPR; 
        uint256 totalProtection;
        uint256 totalInstrumentHoldings;
    }

    struct MarketBundle {
        uint256 marketId;
        uint256 vaultId;
        uint256 creationTimestamp;
        uint256 resolutionTimestamp;

        bool marketConditionMet;
        uint256 approvedPrincipal;
        uint256 approvedYield;
        uint256 managerStake;
        uint256 totalCollateral; // loggedCollateral
        uint256 redemptionPrice;

        // bond pool data
        address bondPool;
        address longZCB;
        uint256 longZCBSupply;
        address shortZCB;
        uint256 shortZCBSupply;
        uint256 longZCBPrice;
        uint256 a_initial;
        uint256 b_initial;
        uint256 b;
        uint256 discountCap;
        uint256 discountedReserves;

        MarketParameters parameters;
        MarketPhaseData phase;
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
        uint256 totalAvailableAssets;
        
        // rates
        uint256 ratePerSec;
        uint256 lastUpdate;
        uint256 utilizationRate;
        address rateContract;
        string rateName;
        uint256 exchangeRate;
        // constants
        CollateralBundle[] collaterals;
    }

    struct OptionsBundle {
        uint256 strikePrice;
        uint256 pricePerContract;
        uint256 shortCollateral;
        uint256 longCollateral;
        uint256 maturityDate;
        uint256 tradeTime;
        address oracle;
        bool approvalStatus;
    }

    struct CreditlineBundle {
        address collateral;
        address oracle;
        // tenor === instrument duration.
        uint256 collateralBalance;
        uint256 principalRepayed;
        uint256 interestRepayed;
        uint256 totalOwed;
        bool approvalCondition;
        CreditLine.CollateralType collateralType;
        CreditLine.LoanStatus loanStatus;

    }

    struct InstrumentBundle {
        uint256 marketId;
        uint256 vaultId;
        address utilizer;
        bool trusted;
        bool isPool;
        uint256 balance;
        uint256 faceValue;

        // proposed
        uint256 principal;
        uint256 expectedYield;

        uint256 duration;
        string description;
        address instrument_address;
        InstrumentType instrument_type;
        uint256 maturityDate;
        bytes32 name;
        uint256 seniorAPR; 
        uint256 exposurePercentage;
        uint256 managers_stake; 
        uint256 approvalPrice;
        PoolBundle poolData;
        OptionsBundle optionsData;
        CreditlineBundle creditlineData;
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

        if (address(vault) == address(0)) {
            return (makeEmptyVaultBundle(), new MarketBundle[](0), new InstrumentBundle[](0), timestamp);
        }

        vaultBundle.name = vault.name();
        vaultBundle.symbol = vault.symbol();
        vaultBundle.vaultId = vaultId;
        vaultBundle.marketIds = _controller.getMarketIds(vaultId);
        vaultBundle.default_params = vault.get_vault_params();
        vaultBundle.onlyVerified = vault.onlyVerified();
        vaultBundle.want = buildAssetBundle(vault.asset());
        vaultBundle.r = vault.r();
        vaultBundle.asset_limit = vault.asset_limit();
        vaultBundle.total_asset_limit = vault.total_asset_limit();
        vaultBundle.totalShares = vault.totalSupply();
        vaultBundle.totalAssets = vault.totalAssets(); 
        vaultBundle.vault_address = address(vault);
        vaultBundle.utilizationRate = vault.utilizationRate();
        vaultBundle.totalInstrumentHoldings = vault.totalInstrumentHoldings();
        vaultBundle.description = vault.description();
     
        (uint256 totalProtection, uint256 totalEstimatedAPR, uint256 goalAPR, uint256 exchangeRate) = _controller.getVaultSnapShot(vaultId);
        vaultBundle.totalProtection = totalProtection;
        vaultBundle.totalEstimatedAPR = totalEstimatedAPR;
        vaultBundle.goalAPR = goalAPR;
        vaultBundle.exchangeRate = exchangeRate;

        if (vaultBundle.marketIds.length == 0) {
            return (vaultBundle, new MarketBundle[](0), new InstrumentBundle[](0), timestamp);
        }

        // associated markets
        // (_marketIds, _lowestMarketIndex) = listOfInterestingMarkets(_marketFactory, _offset, _total);
        marketBundle = new MarketBundle[](vaultBundle.marketIds.length);
        instrumentBundle = new InstrumentBundle[](vaultBundle.marketIds.length);

        for (uint256 i; i < vaultBundle.marketIds.length; i++) {
            marketBundle[i] = buildMarketBundle(vaultBundle.marketIds[i], vaultId, _controller, _marketManager);
            // (uint256 managers_stake, uint256 exposurePercentage, uint256 seniorAPR, uint256 approvalPrice) = 
            instrumentBundle[i] = buildInstrumentBundle(vaultBundle.marketIds[i], vaultId, _controller, _marketManager);
        }
    }


    function buildInstrumentBundle(uint256 mid, uint256 vid, Controller controller, MarketManager marketManager) internal view returns (InstrumentBundle memory bundle) {
        Vault vault = controller.vaults(vid);
        (,address utilizer) = controller.market_data(mid);
        InstrumentData memory data = vault.fetchInstrumentData(mid);


        (uint256 managerStake, uint256 exposurePercentage, uint256 seniorAPR, uint256 approvalPrice) = controller.getInstrumentSnapShot(mid);
        bundle.managers_stake = managerStake;
        bundle.exposurePercentage = exposurePercentage;
        bundle.seniorAPR = seniorAPR;
        bundle.approvalPrice = approvalPrice;

        bundle.marketId = mid;
        bundle.vaultId = vid;
        bundle.isPool = data.isPool;
        bundle.trusted = data.trusted;
        bundle.balance = vault.asset().balanceOf(address(data.instrument_address));
        bundle.principal = data.principal;
        bundle.expectedYield = data.expectedYield;
        bundle.duration = data.duration;
        bundle.description = data.description;
        bundle.instrument_type = data.instrument_type;
        bundle.maturityDate = data.maturityDate;
        bundle.instrument_address = address(data.instrument_address);
        bundle.utilizer = utilizer;
        bundle.name = data.name;
        if (data.instrument_type == InstrumentType.LendingPool) {
            bundle.poolData = buildPoolBundle(mid, vid, controller, marketManager);
        } else if (data.instrument_type == InstrumentType.CoveredCallShort) {
            bundle.optionsData = buildCoveredCallBundle(bundle.instrument_address);
        } else if (data.instrument_type == InstrumentType.CreditLine) {
            bundle.creditlineData = buildCreditlineBundle(bundle.instrument_address);
        }
    }

    function buildCreditlineBundle(address instrument) internal view returns (CreditlineBundle memory bundle) {
        CreditLine creditline = CreditLine(instrument);
        bundle.collateral = creditline.collateral();
        bundle.collateralBalance = creditline.collateral_balance();
        bundle.collateralType = creditline.collateral_type();
        bundle.oracle = creditline.oracle();
        bundle.loanStatus = creditline.loanStatus();
        bundle.principalRepayed = creditline.principalRepayed();
        bundle.totalOwed = creditline.totalOwed();
        bundle.interestRepayed = creditline.interestRepayed();
        // bundle.approvalCondition = creditline.instrumentApprovalCondition();
    }

    function buildCoveredCallBundle(address instrument) internal view returns (OptionsBundle memory bundle) {
        CoveredCallOTC instrumentContract = CoveredCallOTC(instrument);
        // (uint256 _strikePrice, uint256 _pricePerContract, uint256 _shortCollateral, uint256 _longCollateral, uint256 _maturityDate, uint256 _tradeTime, address _oracle) = instrumentContract.instrumentStaticSnapshot();
        uint256 _strikePrice = instrumentContract.strikePrice();
        uint256 _pricePerContract = instrumentContract.pricePerContract();
        uint256 _shortCollateral = instrumentContract.shortCollateral();
        uint256 _longCollateral = instrumentContract.longCollateral();
        uint256 _maturityDate = instrumentContract.maturityTime();
        uint256 _tradeTime = instrumentContract.tradeTime();
        address _oracle = instrumentContract.oracle();

        bundle.strikePrice = _strikePrice;
        bundle.pricePerContract = _pricePerContract;
        bundle.shortCollateral = _shortCollateral;
        bundle.longCollateral = _longCollateral;
        bundle.maturityDate = _maturityDate;
        bundle.tradeTime = _tradeTime;
        bundle.oracle = _oracle;
        bundle.approvalStatus = instrumentContract.instrumentApprovalCondition();
    }

    function buildPoolBundle(uint256 mid, uint256 vid, Controller controller, MarketManager marketManager) internal view returns (PoolBundle memory bundle) {
        Vault vault = controller.vaults(vid);
        address instrument = address(vault.Instruments(mid));
        InstrumentData memory instrumentData = vault.fetchInstrumentData(mid);

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
        uint256 l = labels.length;
        bundle.collaterals = new CollateralBundle[](l);
        for (uint256 i; i < l; i++) {
            (uint256 totalCollateral,
            uint256 maxAmount,
            uint256 maxBorrowAmount,
            bool isERC20, , , ,) = PoolInstrument(instrument).collateralConfigs(PoolInstrument(instrument).computeId(labels[i].tokenAddress, labels[i].tokenId));
            bundle.collaterals[i] = buildCollateralBundle(labels[i].tokenAddress, labels[i].tokenId, maxAmount, maxBorrowAmount, isERC20, totalCollateral);
            bundle.collaterals[i].owner = PoolInstrument(instrument).userERC721s(PoolInstrument(instrument).computeId(labels[i].tokenAddress, labels[i].tokenId));
        }
        
        
        (,uint64 lastTimestamp,uint64 ratePerSec) = PoolInstrument(instrument).currentRateInfo();
        bundle.ratePerSec = ratePerSec;
        bundle.lastUpdate = lastTimestamp;

        (uint128 borrowAmount,) = PoolInstrument(instrument).totalBorrow();
        (uint128 assetAmount,) = PoolInstrument(instrument).totalAsset();

        bundle.utilizationRate = assetAmount == 0 ? 0 : borrowAmount * 1e18 / assetAmount;
        bundle.rateContract = address(PoolInstrument(instrument).rateContract());
        bundle.rateName = PoolInstrument(instrument).rateContract().name();
        bundle.exchangeRate = PoolInstrument(instrument).previewMint(1e18);

        bundle.totalBorrowedAssets = borrowAmount;
        bundle.totalSuppliedAssets = assetAmount;
        bundle.totalAvailableAssets = PoolInstrument(instrument).totalAssetAvailable();
    }

    function buildCollateralBundle(address tokenAddress, uint256 tokenId, uint256 maxAmount, uint256 borrowAmount, bool isERC20, uint256 totalCollateral) internal view returns (CollateralBundle memory bundle) {
        bundle.tokenAddress = tokenAddress;
        bundle.tokenId = tokenId;
        bundle.maxAmount = maxAmount;
        bundle.borrowAmount = borrowAmount;
        bundle.isERC20 = isERC20;
        bundle.totalCollateral = totalCollateral;
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
        CoreMarketData memory data = marketManager.getMarket(mid);
        bundle.creationTimestamp = data.creationTimestamp;
        bundle.resolutionTimestamp = data.resolutionTimestamp;
        bundle.marketConditionMet = controller.marketCondition(mid);

        ApprovalData memory approvalData = controller.getApprovalData(mid);
        bundle.approvedPrincipal = approvalData.approved_principal;
        bundle.approvedYield = approvalData.approved_yield;
        bundle.managerStake = approvalData.managers_stake;

        bundle.totalCollateral = marketManager.loggedCollaterals(mid);
        bundle.redemptionPrice = marketManager.redemption_prices(mid);

        bundle.phase = marketManager.getPhaseData(mid);
        bundle.parameters = marketManager.getParameters(mid);

        bundle.bondPool = address(data.bondPool);
        bundle.longZCB = address(data.longZCB);
        bundle.shortZCB = address(data.shortZCB);
        bundle.shortZCBSupply = data.shortZCB.totalSupply();
        bundle.longZCBSupply = data.longZCB.totalSupply();
        bundle.longZCBPrice = data.bondPool.getCurPrice();
        bundle.a_initial = data.bondPool.a_initial();
        bundle.b_initial = data.bondPool.b_initial();
        bundle.b = data.bondPool.b();
        bundle.discountCap = data.bondPool.discount_cap();
        bundle.discountedReserves = data.bondPool.discountedReserves();
        
        // bundle.validatorData = buildValidatorBundle(mid, controller);

    }

    // function buildValidatorBundle(uint256 mid, Controller controller) view internal returns (ValidatorBundle memory bundle)  {
    //     bundle.avg_price = controller.getValidatorPrice(mid);
    //     bundle.validators = controller.viewValidators(mid);
    //     bundle.totalSales = controller.getTotalValidatorSales(mid);
    //     bundle.totalStaked = controller.getTotalStaked(mid);
    //     bundle.numApproved = controller.getNumApproved(mid);
    //     bundle.initialStake = controller.getInitialStake(mid);
    //     bundle.finalStake = controller.getFinalStake(mid);
    //     bundle.numResolved = controller.getNumResolved(mid);
    //     bundle.val_cap = controller.getValidatorCap(mid);
    // }

// (uint256 managers_stake, uint256 exposurePercentage, uint256 seniorAPR, uint256 approvalPrice)
    // function computeInstrumentProfile(
    //     uint256 mid, 
    //     InstrumentBundle memory bundle, 
    //     Controller controller, 
    //     MarketManager marketmanager
    //     ) internal view {
    //     // get senior instrument apr, approval price, manager's stake, 
    //     MarketManager.CoreMarketData memory data = marketmanager.getMarket(mid); 
    //     Controller.ApprovalData memory approvalData = controller.getApprovalData(mid); 
    //     bundle.managers_stake = approvalData.managers_stake;

    //     bundle.exposurePercentage = (bundle.balance).divWadDown(
    //         controller.getVault(mid).totalAssets()+1);
    //     bundle.seniorAPR = bundle.poolData.promisedReturn; 
    //     bundle.approvalPrice = bundle.poolData.inceptionPrice; 

    //     if(!bundle.isPool){
    //         uint256 amountDelta;
    //         uint256 resultPrice;

    //         if(approvalData.managers_stake>0){
    //             ( amountDelta,  resultPrice) = LinearCurve.amountOutGivenIn(
    //             approvalData.managers_stake,
    //             0, 
    //             data.bondPool.a_initial(), 
    //             data.bondPool.b(), 
    //             true 
    //             );
    //         }
            
    //         uint256 seniorYield = bundle.faceValue -amountDelta
    //             - (bundle.principal - approvalData.managers_stake); 

    //         bundle.seniorAPR = approvalData.approved_principal>0
    //             ? seniorYield.divWadDown(1+bundle.principal - approvalData.managers_stake)
    //             : 0; 
    //         bundle.approvalPrice = resultPrice; 
    //     }

    // }

    function makeEmptyVaultBundle() pure internal returns (VaultBundle memory) {
        return VaultBundle(
            "",
            "",
            "",
            0,
            new uint256[](0),
           MarketParameters(0,0,0,0,0,0,0,0),
            false,
            0,
            0,
            0,
            AssetBundle(address(0), "", 0, ""),
            0,
            0,
            address(0),
            0,
            0,
            0, 
            0,0,
            0
        );
    }
}