pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import  "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
// import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
//import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {VaultAccount} from "../contracts/instruments/VaultAccount.sol";
import {PoolInstrument} from "../contracts/instruments/poolInstrument.sol";

import {CustomTestBase} from "./testbase.sol";
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol"; 
import "../contracts/global/GlobalStorage.sol"; 
import "../contracts/global/types.sol"; 

contract PricerTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 



    function setUp() public {

        // controller = new Controller(deployer); // zero addr for interep
        // vaultFactory = new VaultFactory(address(controller));
        collateral = new Cash("n","n",18);
        collateral2 = new Cash("nn", "nn", 18); 
        bytes32  data;
        // marketmanager = new MarketManager(
        //     deployer,
        //     address(controller), 
        //     address(0),data, uint64(0)
        // );
        // ZCBFactory zcbfactory = new ZCBFactory(); 
        // poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory)); 
        // reputationManager = new ReputationManager(address(controller), address(marketmanager));
        
        // leverageManager = new LeverageManager(address(controller), address(marketmanager), address(reputationManager));
        // Data = new StorageHandler(); 
        deploySetUps();
        controllerSetup();

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
        // nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        // initiateLendingPool(vault_ad); 
        doInvest(vault_ad,  toku, 1e18*10000); 

    }

    function addAssetToPool(address pool, uint256 addamount) public{
        (uint128 amount, uint128 shares) = PoolInstrument(pool).totalAsset(); 
        stdstore
            .target(pool)
            .sig(poolInstrument.totalAsset.selector)
            .depth(0)
            .checked_write(
                amount +uint128(addamount)
        );
    }

    function addSharesToPool(address pool, uint256 addamount) public{
        (uint128 amount, uint128 shares) = PoolInstrument(pool).totalAsset(); 
        stdstore
            .target(pool)
            .sig(poolInstrument.totalAsset.selector)
            .depth(1)
            .checked_write(
                shares +uint128(addamount)
        );
    }



    // struct testVars1{
    //     uint256 marketId;
    //     address vault_ad; 
    //     uint amountToBuy; 
    //     uint curPrice; 

    //     uint amountIn;
    //     uint amountOut; 

    //     uint valamountIn; 
    //     uint cbalnow; 
    //     uint cbalnow2; 

    //     uint pju; 
    //     uint psu;


    //     uint saleAmount;
    //     uint initPrice;
    //     uint promisedReturn;
    //     uint inceptionPrice;
    //     uint leverageFactor;

    // }
        // poolData.saleAmount = principal/4; 
        // poolData.initPrice = 7e17; 
        // poolData.promisedReturn = 3000000000; 
        // poolData.inceptionTime = block.timestamp; 
        // poolData.inceptionPrice = 8e17; 
        // poolData.leverageFactor = 5e18; 
 

    function testStoreNewPrices(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor
        ) public {

        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        //At start needs to be at inception price, 
        PricingInfo memory info = Data.getPricingInfo( vars.marketId); 
        assertEq(info.psu, vars.inceptionPrice); 

        // after constant RF, with time needs to be same 
        // Data.setRF(vars.marketId, true); 

        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
        assertEq(vars.psu, info.psu); 
        assertEq(vars.psu, vars.pju); 

    }

    /// @notice test constant promised returns pricing
    /// when approve, pricing should remain same 
    /// when issue, pricing should stay same 
    /// when begins, need to both start at inception, and when donated, pju must go up
    /// when time passes and no donations made, psu goes up and pju goes down
    /// when time passes and donations are made, psu goes up regardless pju goes up 
    /// when if donation == promised return pju and psu same 
    function testConstantRFPricing(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 donateAmount1,
        uint32 time1, 
        uint32 donateAmount2
        ) public{
        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        Data.setRF(vars.marketId, true);

        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e16),
            Data.getInstrumentData(vars.marketId).poolData.saleAmount*3/2, 
            Data.getInstrumentData(vars.marketId).poolData.saleAmount*3 );
        vm.assume(marketmanager.getTraderBudget(vars.marketId, jonna)>= amountToBuy); 
        uint donateAmount1 = constrictToRange(fuzzput(donateAmount1, 1e16), 
            0, amountToBuy
            ); 
        uint donateAmount2 = constrictToRange(fuzzput(donateAmount2, 1e16), 
            0, amountToBuy
            ); 
        uint time1 = constrictToRange(fuzzput(time1, 1), 0, 31536000*10); 
        console.log('params', amountToBuy, donateAmount1, donateAmount2); 

        // deposit to pool 
        // doInvest(address(poolInstrument), jonna, 
        //     Data.getMarket(vars.marketId).longZCB.totalSupply().mulWadDown(1e18+vars.leverageFactor)); 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(amountToBuy), precision , data); 
        (uint psu,  uint pju, ) = Data.viewCurrentPricing(vars.marketId) ; 

        console.log('start pju', pju, psu); 
        assertApproxEqAbs(psu, pju,5); 
        assertEq(psu, vars.inceptionPrice); 

        // Approve and pricing same 
        doApprove(vars.marketId, vars.vault_ad);

        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        assertEq(vars.psu, psu); 
        assertEq(vars.pju, pju); 
        assertApproxEqAbs(vars.psu, vars.pju, 10); 
        assertEq(vars.psu, Data.getInstrumentData(vars.marketId).poolData.inceptionPrice); 

        // Donate and pricing same, pju higher 
        // donateToInstrument(vars.vault_ad, Data.getInstrumentAddress(vars.marketId) ,  donateAmount1);
        poolInstrument.modifyTotalAsset(true, donateAmount1);
        ( psu,   pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        console.log('psupju',psu, pju); 
        assertEq(psu, vars.psu); 
        if(donateAmount1>0){
            assert(vars.pju < pju);

            // When time doesn't pass, donate amount goes straight to increasing exchange rate 
            assertApproxEqBasis(
                (pju-vars.pju).mulWadDown(Data.getMarket(vars.marketId).longZCB.totalSupply()),
                donateAmount1, 1
                ); 
        }
        else if(donateAmount1 == 0) assert(vars.pju ==pju); 

        //After some time.. when no donations were made check if donation == promised return pju and psu same 
        vm.warp(block.timestamp+time1); 
        ( ,pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        bool isSolvent = Data.checkIsSolventConstantRF(vars.marketId); 

        poolInstrument.modifyTotalAsset(true, donateAmount2);

        ( vars.psu,   vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        console.log('after time pju', vars.pju, vars.psu, pju);
        console.log('isSolvent', isSolvent);  

        // assert psu increased by promised return

        // if wasn't solvent, donated amount will fill out psu first 
        if(donateAmount2>0 && isSolvent){
            // assert(vars.pju > pju);
            assertApproxEqBasis(vars.psu.divWadDown(psu), (1e18+vars.promisedReturn).rpow(time1, 1e18), 1); 

            // When time doesn't pass, donate amount goes straight to increasing exchange rate 
            assertApproxEqBasis(
                (vars.pju-pju).mulWadDown(Data.getMarket(vars.marketId).longZCB.totalSupply()),
                donateAmount2, 1
            ); 
        } 

        // Issue doesn't change price 
        if(vars.pju >= Constants.THRESHOLD_PJU){
            console.log('vaultad', vars.vault_ad); 
            doInvest(vars.vault_ad,  toku, (amountToBuy.divWadDown(vars.pju)).mulWadDown(vars.leverageFactor)); 

            console.log('failed?', vars.pju, vars.pju.mulWadDown(amountToBuy),  
            Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna)); 
            vm.prank(jonna); 
            marketmanager.issuePoolBond(vars.marketId, amountToBuy); 
            (psu, pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
            assertEq(vars.psu, psu); 
            assertApproxEqAbs(vars.pju, pju,10); 


            // Redeem doesn't change price 
            vm.prank(jonna); 
            marketmanager.redeemPoolLongZCB(vars.marketId, amountToBuy); 
            (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
            console.log('where', vars.psu, psu); 
            assertEq(vars.psu, psu); 
            console.log('here', vars.pju, pju); 

            assertApproxEqAbs(vars.pju, pju, 10); 
        }


      }

    /// @notice check if donation equals promied return, then pju/psu rise equal 
    // function testPromisedReturnDonation(
    //     uint256 multiplier, 

    //     uint32 saleAmount, 
    //     uint32 initPrice,
    //     uint32 promisedReturn, 
    //     uint32 inceptionPrice, 
    //     uint32 leverageFactor, 

    //     uint32 time1


    //     ) public {
    //     testVars1 memory vars = createLendingPoolAndPricer(
    //      multiplier, 

    //      saleAmount, 
    //      initPrice,
    //      promisedReturn, 
    //      inceptionPrice, 
    //      leverageFactor
    //     ); 

    //     ( uint psu,   uint pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
    //     assertEq(psu, pju); 

    //     uint promisedIncrease = Data.getMarket(vars.marketId)
    //         .longZCB.totalSupply().mulWadDown(1e18 + vars.leverageFactor)
    //         .mulWadDown( (1e18+vars.promisedReturn).rpow(time1, 1e18) - 1e18
    //         ); 
    //     poolInstrument.modifyTotalAsset(true, promisedIncrease);
    //     vm.warp(block.timestamp + time1); 
    //     (  psu,  pju, ) = Data.viewCurrentPricing(vars.marketId) ; 
    //     assertApproxEqAbs(psu, pju, 100); 

    // }

    function testDynamicRFPSU(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy ,
        uint32 amountToIssue, 
        uint32 timepass

        ) public{
        vm.assume(timepass>10); 
        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        Data.setRF(vars.marketId, false);

        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e16),
            Data.getInstrumentData(vars.marketId).poolData.saleAmount*3/2, 
            Data.getInstrumentData(vars.marketId).poolData.saleAmount*3 );
        vm.assume(marketmanager.getTraderBudget(vars.marketId, jonna)>= amountToBuy); 
        vars.budget = marketmanager.getTraderBudget(vars.marketId, jonna); 
        vars.amount1 = constrictToRange(fuzzput(amountToIssue, 1e14), 1e12, vars.budget ); 
        vars.amountOut = doApproveFromStart(vars.marketId, amountToBuy); 


        // change RF and psu adjusts accordingly 
        // refresh pricing when no util rate changes = no psu changes
        ( vars.psu,   vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        vm.warp(block.timestamp+ timepass); 
        Data.refreshPricing(vars.marketId); 
        (vars.psu2, vars.pju2,) = Data.viewCurrentPricing(vars.marketId); 
        assertEq(vars.psu, vars.psu2); 
        assertEq(vars.pju2, vars.pju); 


        // util rate changes, so psu does change 
        borrowFromPool(poolInstrument.totalAssetAvailable(), 
         poolInstrument.totalAssetAvailable()/10, jonna); 
        Data.refreshPricing(vars.marketId); // this will store new Rf
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId); 
        assertEq(vars.psu, vars.psu2); 
        assertEq(vars.pju2, vars.pju); 

        vm.warp(block.timestamp+ timepass); 
        vars.urate1 = Data.getPoolUtilRate(vars.marketId); 

        ( vars.psu2,   vars.pju2, ) = Data.refreshViewCurrentPricing(vars.marketId) ;

        assert(vars.psu<vars.psu2); 
        assert(vars.pju>vars.pju2);  
        if(Data.checkIsSolventDynamicRF(vars.marketId))
            assertApproxEqAbs(vars.psu2.divWadDown(vars.psu), 
            (unit + vars.urate1.mulWadDown(Constants.BASE_MULTIPLIER)
            ).rpow(timepass, unit), 1001
        ); 

        // issue longzcb, util rate goes down and psu doesn't increase as much as it would have
        vm.prank(jonna);
        if(vars.pju2.divWadDown(vars.psu2) < Constants.THRESHOLD_PJU) return; 
        uint issueamount = marketmanager.issuePoolBond(vars.marketId, vars.amount1); //store new psu 
        assert(vars.urate1 > Data.getPoolUtilRate(vars.marketId) ); 
        vm.warp(block.timestamp+ timepass); 
        ( vars.psu,   vars.pju, ) = Data.refreshViewCurrentPricing(vars.marketId) ;
        console.log('?',vars.psu.divWadDown(vars.psu2), (unit + Constants.BASE_MULTIPLIER.mulWadDown(Data.getPoolUtilRate(vars.marketId))
            ).rpow(timepass, unit)); 
        assertApproxEqAbs(vars.psu.divWadDown(vars.psu2), 
            (unit + Constants.BASE_MULTIPLIER.mulWadDown(Data.getPoolUtilRate(vars.marketId))
            ).rpow(timepass, unit), 1002
        ); 

        // redeem longzcb, util rate goes up and psu increase more
        vm.warp(block.timestamp+ timepass); 
        vm.prank(jonna);
        marketmanager.redeemPoolLongZCB(vars.marketId, issueamount); 
        assertApproxEqAbs(vars.urate1, Data.getPoolUtilRate(vars.marketId),5 ); 
        ( vars.psu2,   vars.pju2, ) = Data.refreshViewCurrentPricing(vars.marketId) ;
        console.log('?',vars.psu2.divWadDown(vars.psu), (unit + Constants.BASE_MULTIPLIER.mulWadDown(Data.getPoolUtilRate(vars.marketId))
            ).rpow(timepass, unit));
        // assertApproxEqAbs(vars.psu2.divWadDown(vars.psu), 
        //     (unit + Constants.BASE_MULTIPLIER.mulWadDown(Data.getPoolUtilRate(vars.marketId))
        //     ).rpow(timepass, unit), 1003
        // ); 


        // WHat happens to pju? 

    }

    // function testDynamicRFPricing(
    //     uint256 multiplier, 

    //     uint32 saleAmount, 
    //     uint32 initPrice,
    //     uint32 promisedReturn, 
    //     uint32 inceptionPrice, 
    //     uint32 leverageFactor, 

    //     uint32 amountToBuy ,
    //     uint32 amountToIssue

    //     ) public {
    //     testVars1 memory vars = createLendingPoolAndPricer(
    //      multiplier, 

    //      saleAmount, 
    //      initPrice,
    //      promisedReturn, 
    //      inceptionPrice, 
    //      leverageFactor
    //     ); 

    //     Data.setRF(vars.marketId, false);

    //     uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e16),
    //         Data.getInstrumentData(vars.marketId).poolData.saleAmount*3/2, 
    //         Data.getInstrumentData(vars.marketId).poolData.saleAmount*3 );
    //     vm.assume(marketmanager.getTraderBudget(vars.marketId, jonna)>= amountToBuy); 
    //     vars.budget = marketmanager.getTraderBudget(vars.marketId, jonna); 
    //     vars.amount1 = constrictToRange(fuzzput(amountToIssue, 1e14), 1e12, vars.budget ); 

    //     vars.amountOut = doApproveFromStart(vars.marketId, amountToBuy); 



    //     // TODO study how pju changes with utilization rate and write it down 

    //     // issue longzcb and util rate goes down
    //     // issue longzcb and RF goes down the next time its called 
    //     // psu don't go down right away, RF does and psu goes down after some time 
    //     // pju reflects this change. Psu goes down then what should happen to pju 
    //         // pju goes up if psu goes down, if utilization rate doesn't increase again 
    //         // if urate increases again, then pju should goes back up 

    //     // redeem longzcb and util rate goes up 
    //     // redeem longzcb and psu goes up the next time its called 
    //     // pju reflects this change. Psu goes up then what should happen to pju 
    //         // pju goes down if psu goes up, if utilization rate

    //     // 0 urate and psu does not increase, even after longzcb buy
    //     ( vars.psu,   vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
    //     vm.warp(block.timestamp+ 100000); 
    //     vm.prank(jonna);
    //     marketmanager.issuePoolBond(vars.marketId, vars.amount1);
    //     (vars.psu2, vars.pju2) = Data.viewCurrentPricing(vars.marketId); 
    //     assertEq(vars.psu, vars.psu2); 
    //     assertEq(vars.pju2, vars.pju); 

    //     borrowFromPool(poolInstrument.totalAssetAvailable(), 
    //      poolInstrument.totalAssetAvailable()/10, jonna); 
    //     vars.balbefore = poolInstrument.totalAssetAvailable(); 

    //     vars.urate1 = Data.getPoolUtilRate(vars.marketId); 

    //     vm.prank(jonna);
    //     marketmanager.issuePoolBond(vars.marketId, vars.amount1);
    //     ( vars.psu,   vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;

    //     vars.amount1 = 
    //         vars.amount1 + 
    //         vars.amount1.divWadDown(vars.pju).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu); 

    //     console.log('urates', vars.urate1, Data.getPoolUtilRate(vars.marketId)); 
    //     uint uratedif = (vars.urate1  - Data.getPoolUtilRate(vars.marketId));
    //     uint borrowamount = poolInstrument.getTotalBorrowAmount(); 
    //     assertApproxEqAbs(poolInstrument.totalAssetAvailable() - vars.balbefore, vars.amount1, 1000); 
    //     // assertApproxEqAbs(uratedif, 
    //     //     (vars.amount1.mulWadDown(borrowamount)).divWadDown(
    //     //     vars.balbefore.mulWadDown(poolInstrument.totalAssetAvailable())
    //     //     ), 1001 ); 
    //     console.log('uratedif', vars.urate1, uratedif); 

    //     vm.warp(block.timestamp+ 100000); 
    //     ( vars.psu2,   vars.pju2, ) = Data.viewCurrentPricing(vars.marketId) ;
    //     (vars.psu2, vars.pju2); 
    //     assert(vars.psu2)
    //     (vars.psu2 - vars.psu).divWadDown()


    // }


   

}

// contract UtilizerCycle is FullCycleTest{


// }
