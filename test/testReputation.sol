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
import {LeverageModule} from "../contracts/protocol/LeverageModule.sol"; 

contract ReputationSystemTests is CustomTestBase {

    uint256 W = 1e18; 
    address zeke;
    address jeong; 

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

        vm.startPrank(deployer); 
        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setPoolFactory(address(poolFactory)); 
        controller.setReputationManager(address(reputationManager));
        validatorManager = new ValidatorManager(address(controller), address(marketmanager),address(reputationManager) );      
        controller.setValidatorManager(address(validatorManager)); 
        vm.stopPrank(); 

        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak)
        ); //vaultId = 1; 
        vault_ad = controller.getVaultfromId(1); 

        setUsers();

        nftPool = new SimpleNFTPool(  vault_ad, toku, address(collateral)); 
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        doInvest(vault_ad,  toku, 1e18*10000); 

        leverageModule = new LeverageModule(address(controller)); 
        zeke = address(0xbabe9);
        vm.label(zeke, "zeke");
        jeong = address(0xbabe10);
        vm.label(jeong, "jeong");
    }
    // function setUp() public {
    //     controller = new Controller(deployer, address(0));
    //     reputationManager = new ReputationManager(address(controller), msg.sender);
    //     jonna = address(0xbabe);
    //     vm.label(jonna, "jonna");
    //     jott = address(0xbabe2); 
    //     vm.label(jott, "jott");
    //     gatdang = address(0xbabe3); 
    //     vm.label(gatdang, "gatdang");
    //     sybal = address(0xbabe4);
    //     vm.label(sybal, "sybal");
    //     chris=address(0xbabe5);
    //     vm.label(chris, "chris");
    //     miku = address(0xbabe6);
    //     vm.label(miku, "miku");
    //     goku = address(0xbabe7); 
    //     vm.label(goku, "goku");
    //     toku = address(0xbabe8);
    //     vm.label(toku, "toku"); 
    //     zeke = address(0xbabe9);
    //     vm.label(zeke, "zeke");
    //     jeong = address(0xbabe10);
    //     vm.label(jeong, "jeong");

    // }

    function addUsers() public {
        reputationManager.incrementScore(jonna, 10);
        reputationManager.incrementScore(jott, 20);
        reputationManager.incrementScore(gatdang, 30);
        reputationManager.incrementScore(goku, 40);
        reputationManager.incrementScore(toku, 50);
        reputationManager.incrementScore(miku, 60);
        reputationManager.incrementScore(chris, 70);
        reputationManager.incrementScore(sybal, 80);
        reputationManager.incrementScore(zeke, 90);
        reputationManager.incrementScore(jeong, 100);
    }

    struct testVars1{
        uint256 marketId;
        address vault_ad; 
        uint amountToBuy; 
        uint curPrice; 

        uint amountIn;
        uint amountOut; 
        uint amountIn2; 
        uint amountOut2; 

        uint valamountIn; 
        uint cbalnow; 
        uint cbalnow2; 

        uint pju; 
        uint psu; 
        uint pju2; 
        uint psu2; 
    }


    function testRecordPull() public returns(testVars1 memory){
        // buy f
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 

        vars.vault_ad = controller.getVaultfromId(vars.marketId); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn2, vars.amountOut2) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        ReputationManager.RepLog memory log = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log.collateralAmount , vars.amountIn2); 
        assertEq(log.bondAmount, vars.amountOut2); 

        // buy again 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 
        ReputationManager.RepLog memory log2 = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log2.collateralAmount, log.collateralAmount + vars.amountIn ); 
        assertEq(log2.bondAmount, log.bondAmount + vars.amountOut);
        return vars; 
    }

    function testRecordPushPerp() public{
        uint donateamount =500e18; 
        uint donateamount2 = 389e18; 

        testVars1 memory vars = testRecordPull();
        doApprove(vars.marketId, vars.vault_ad);

        // redeem portion
        ReputationManager.RepLog memory log = reputationManager.getRepLog(jonna, vars.marketId);
        vm.prank(jonna); 
        uint startRep = reputationManager.trader_scores(jonna); 

        // time passes... test when pju increase, decrease, or stay same 
        (vars.psu2, vars.pju2, ) = Vault(vars.vault_ad).poolZCBValue( vars.marketId); 

        vm.warp(31536000); 
        (vars.pju, vars.psu,)=  Vault(vars.vault_ad).poolZCBValue( vars.marketId); 
        console.log('before donate', vars.pju,vars.psu);

        donateToInstrument(vars.vault_ad,  
            address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)), donateamount); 
        (vars.pju, vars.psu,)=  Vault(vars.vault_ad).poolZCBValue( vars.marketId); 
        console.log('after donate', vars.pju,vars.psu);

        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amountOut); 
        ReputationManager.RepLog memory log2 = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log.bondAmount - log2.bondAmount, vars.amountOut ); 
        uint midRep = reputationManager.trader_scores(jonna); 
        (uint psu, uint pju, ) = Vault(vars.vault_ad).poolZCBValue( vars.marketId); 
        if(donateamount==0) {
            assert(midRep <  startRep); 
            assert(psu> pju); 
        }

        else if (pju > psu) assert(midRep> startRep); 
        else if (pju == psu) assert(midRep== startRep); 
        else if (pju < psu) assert(midRep< startRep); 

        // // get rid of everything, 
        vm.warp(31536000); 
        donateToInstrument(vars.vault_ad,  
            address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)), donateamount2); 
        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amountOut2/2); //TODO get rid of everything
        log = reputationManager.getRepLog(jonna, vars.marketId);
        // assertApproxEqAbs(log.bondAmount, 10); 
        // assertApproxEqAbs(log.collateralAmount, 0, 10); 
        assert(log.bondAmount< log2.bondAmount); 
        assert(log.collateralAmount< log2.collateralAmount); 
        assertApproxEqAbs(vars.amountOut2/2, log2.bondAmount-log.bondAmount, 10); 
        console.log('bondamount, collateralAmount', vars.amountOut2/2,log2.collateralAmount, log.collateralAmount ); 
        console.log('..', log2.bondAmount, log.bondAmount); 
        (vars.psu, vars.pju, ) = Vault(vars.vault_ad).poolZCBValue( vars.marketId); 
        if(donateamount2==0) {
            assert(reputationManager.trader_scores(jonna) <  midRep); 
        }
        else if(vars.pju>vars.psu && vars.pju> pju)//0.8,0.8 0.85,0.82 0.8,0.83, 0
            assert(reputationManager.trader_scores(jonna) >  midRep); 
        else if(vars.pju>vars.psu && vars.pju< pju)
            assert(reputationManager.trader_scores(jonna) >  midRep); //
        else if(vars.pju<vars.psu && vars.pju< vars.psu2) 
            assert(reputationManager.trader_scores(jonna) < midRep); // needs to decrease 
        console.log('start', startRep, midRep, reputationManager.trader_scores(jonna)); 

        //collateralamount,bondamount goes to 0 when all is redeemed 

// what the fuck all the instrument balance should go to 0?? why is it not


    }

    function testRecordPullFixed() public returns(testVars1 memory){
        initiateOptionsOTCMarket(); 
        // buy f
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 

        vars.vault_ad = address(controller.getVault(vars.marketId)); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal/3; 
        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn2, vars.amountOut2) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy/2), precision , data); 

        ReputationManager.RepLog memory log = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log.collateralAmount , vars.amountIn2); 
        assertEq(log.bondAmount, vars.amountOut2); 

        // buy again 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 
        ReputationManager.RepLog memory log2 = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log2.collateralAmount, log.collateralAmount + vars.amountIn ); 
        assertEq(log2.bondAmount, log.bondAmount + vars.amountOut);
        return vars; 
    }

    function testRecordPushFixed() public{
        testVars1 memory vars = testRecordPullFixed();

        uint donateamount = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).expectedYield; 
        donateToInstrument(vars.vault_ad, address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)), longCollateral); 
        doApprove(vars.marketId, vars.vault_ad);

   // redeem portion
        ReputationManager.RepLog memory log = reputationManager.getRepLog(jonna, vars.marketId);
        vm.prank(jonna); 
        uint startRep = reputationManager.trader_scores(jonna); 

        // time passes... test when pju increase, decrease, or stay same 

        vm.warp(31536000); 
        vm.startPrank(toku); 
        CoveredCallOTC(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))).claim(); 
        vm.stopPrank(); 


        // vm.startPrank(toku); 
        // CoveredCallOTC( address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))).claim(); 
        // vm.stopPrank(); 

        vm.prank(jonna); 
        controller.testResolveMarket(vars.marketId); 

        vm.prank(jonna); 
        marketmanager.redeem(vars.marketId); 
        ReputationManager.RepLog memory log2 = reputationManager.getRepLog(jonna, vars.marketId);
        assertEq(log.bondAmount - log2.bondAmount, log.bondAmount ); 
        assertEq(log2.collateralAmount, 0); 

        uint midRep = reputationManager.trader_scores(jonna); 
        console.log('start', startRep, midRep); 
        // why is the redemption price weird? 

        // if(donateamount==0) {
        //     assert(midRep <  startRep); 
        // }
        // else if(donateamount >= Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).expectedYield)
        //     assert(midRep> startRep); 
        // else if(donateamount < Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).expectedYield)
        //     assert(midRep< startRep); 



    } 




    // function testSelectTraders() public {
    //     addUsers();
    //     address[] memory vals = controller.filterTraders(40*1e18, address(0));
    //     console.log("length: ", vals.length);

    //     vals = controller.filterTraders(90*1e18, address(0));
    //     console.log("length: ", vals.length);
    // }
    
}