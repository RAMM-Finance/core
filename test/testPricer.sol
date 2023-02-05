pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import  "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {SyntheticZCBPoolFactory, ZCBFactory} from "../contracts/bonds/synthetic.sol"; 
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";

import {CustomTestBase} from "./testbase.sol";
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol"; 
import "../contracts/global/GlobalStorage.sol"; 
import "../contracts/global/types.sol"; 
import "../contracts/global/types.sol"; 

contract PricerTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 



    function setUp() public {

        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        collateral = new Cash("n","n",18);
        collateral2 = new Cash("nn", "nn", 18); 
        bytes32  data;
        marketmanager = new MarketManager(
            deployer,
            address(controller), 
            address(0),data, uint64(0)
        );
        ZCBFactory zcbfactory = new ZCBFactory(); 
        poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory)); 
        reputationManager = new ReputationManager(address(controller), address(marketmanager));
        
        leverageManager = new LeverageManager(address(controller), address(marketmanager), address(reputationManager));
        Data = new StorageHandler(); 
        controllerSetup(); 

        vm.startPrank(deployer); 
        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setPoolFactory(address(poolFactory)); 
        controller.setReputationManager(address(reputationManager));
        validatorManager = new ValidatorManager(address(controller), address(marketmanager),address(reputationManager) );     
        controller.setValidatorManager(address(validatorManager)); 
        controller.setLeverageManager(address(leverageManager));
        controller.setDataStore(address(Data)); 

        vm.stopPrank(); 

        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
            "description"
        ); //vaultId = 1; 
        vault_ad = controller.getVaultfromId(1); 

        setUsers();

        nftPool = new SimpleNFTPool(  vault_ad, toku, address(collateral)); 
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        // initiateLendingPool(vault_ad); 
        doInvest(vault_ad,  toku, 1e18*10000); 

    }
   

    struct testVars1{
        uint256 marketId;
        address vault_ad; 
        uint amountToBuy; 
        uint curPrice; 

        uint amountIn;
        uint amountOut; 

        uint valamountIn; 
        uint cbalnow; 
        uint cbalnow2; 

        uint pju; 
        uint psu;

    }

    function setUpPricer() public {

    }

    function testStoreNewPrices() public returns(testVars1 memory) {
        testVars1 memory vars; 
        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId);
        uint256 multiplier = 1; 
        uint256 initPrice = 1e18; 


        // At start needs to be at inception price, 
        PricingInfo memory info = Data.getPricingInfo( vars.marketId); 
        assertEq(info.psu, Data.getInstrumentData(vars.marketId).poolData.inceptionPrice); 

        // after constant RF, with time needs to be same 
        Data.setRF(vars.marketId, true); 

        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
        assertEq(vars.psu, info.psu); 
        assertEq(vars.psu, vars.pju); 

        return vars; 
    }

    // function testPricer() public{
    //     testVars1 memory vars; 
    //     vars.marketId = controller.getMarketId(toku); 
    //     vars.vault_ad = controller.getVaultfromId(vars.marketId); 

    //     vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 


    //     (uint psu,  uint pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);

    //     doApproveFromStart(vars.marketId,  vars.amountToBuy);

    //     uint donateAmount = Vault(vars.vault_ad).UNDERLYING().balanceOf(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))) * 1/10; 


    //     (vars.psu, vars.pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
    //     assertEq(vars.psu, psu); 
    //     assertEq(vars.pju, pju); 



    // }
 

    function testConstantRFPricing() public{
        testVars1 memory vars = testStoreNewPrices(); 
        // 1. When approve, pricing should stay same
        // 2. When issue, pricing should stay same
        // 3. When begins, need to both start at inception, and when donated, pju must go up
        // 4. When time passes and no donations made, psu goes up pju goes down, 
        // 5. Works for all initial price <= inception price and 

        // After approval 
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        // uint donateAmount = Vault(vars.vault_ad).UNDERLYING().balanceOf(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))) * 1/10; 
     
        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        (uint psu,  uint pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
        console.log('start pju', pju, psu); 

        // Approve and pricing same 
        doApprove(vars.marketId, vars.vault_ad);
        uint donateAmount = Vault(vars.vault_ad).UNDERLYING().balanceOf(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))) * 1/10; 
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        assertEq(vars.psu, psu); 
        assertEq(vars.pju, pju); 
        assertApproxEqAbs(vars.psu, vars.pju, 10); 
        assertEq(vars.psu, controller.getVault(vars.marketId).fetchInstrumentData(vars.marketId).poolData.inceptionPrice); 

        // Donate and pricing same 
        donateToInstrument( vars.vault_ad, address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)) ,  donateAmount);
        ( psu,   pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        assertEq(psu, vars.psu); 
        // if(donateAmount>0)assert(vars.pju<pju);
        console.log('after donate pju', pju, psu); 



        //After some time.. when no donations were made 
        vm.warp(block.timestamp+31536000); 
        donateToInstrument( vars.vault_ad, address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)) ,  donateAmount);

        ( vars.psu,   vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        console.log('after time pju', vars.pju, vars.psu, pju); 

        assert(vars.psu>controller.getVault(vars.marketId).fetchInstrumentData(vars.marketId).poolData.inceptionPrice ); 
        if(donateAmount==0) assert(pju> vars.pju); 

        // Issue doesn't change price 
        vm.prank(jonna); 
        marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
        (psu, pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
        assertEq(vars.psu, psu); 
        assertEq(vars.pju, pju); 
    }

    function testPricingIsSupplyAgnostic() public{}

   

}

// contract UtilizerCycle is FullCycleTest{


// }
