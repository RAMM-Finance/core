pragma solidity ^0.8.4;

import {MarketManager} from "../protocol/marketmanager.sol";
import {Vault} from "../vaults/vault.sol";
import {VaultFactory} from "../protocol/factories.sol";
import {Controller} from "../protocol/controller.sol";
import {ERC20} from "../vaults/tokens/ERC20.sol";
import {SyntheticZCBPool} from "../bonds/synthetic.sol";

contract Fetcher {
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
        SyntheticZCBPool bondPool;
        MarketManager.MarketParameters parameters;
        MarketManager.MarketPhaseData phase;
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
        Vault.PoolData poolData;
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
        }
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
        bundle.poolData = data.poolData;
        bundle.instrument_address = address(data.Instrument_address);
        bundle.utilizer = utilizer;
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
            address(0)
        );
    }
}