pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
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
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
import "../contracts/global/types.sol"; 

contract LeverageModuleTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    PoolInstrument pool; 
    bytes initCallData;

    uint256 wad = 1e18;

    PoolInstrument.CollateralLabel[] clabels;
    PoolInstrument.Config[] collaterals;

    function setUp() public {

        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        collateral = new Cash("n","n",18);
        collateral2 = new Cash("nn", "nn", 18); 
        bytes32  data;

        clabels.push(
            PoolInstrument.CollateralLabel(
                address(collateral),
                0
            )
        );
        collaterals.push(
            PoolInstrument.Config(
            0,
            wad/2,
            wad/4,
            true,
            0,0,0,0
        )
        );
        marketmanager = new MarketManager(
            deployer,
            address(controller), 
            address(0),data, uint64(0)
        );
        ZCBFactory zcbfactory = new ZCBFactory(); 
        poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory)); 
        reputationManager = new ReputationManager(address(controller), address(marketmanager));

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
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        doInvest(vault_ad,  toku, 1e18*10000); 



        VariableInterestRate rateCalculator = new VariableInterestRate();

        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _collaterals = collaterals;

        pool = new PoolInstrument(
            vault_ad,
            address(reputationManager), 
            0,
            deployer,
            "pool 1",
            "P1",
            address(rateCalculator),
            initCallData,
            _clabels,
            _collaterals
        );
               
        vm.prank(address(controller));
        pool.addAcceptedCollateral(
            vault_ad,
            0,
            PoolInstrument.Config(
            0,
            precision, 
            precision*9/10, 
            true,
            0,
            0,
            0,
            0)
        );      

    }

    // function testSetup1() public {

    //     controller = new Controller(deployer, address(0)); // zero addr for interep
    //     vaultFactory = new VaultFactory(address(controller));
    //     collateral = new Cash("n","n",18);
    //     collateral2 = new Cash("nn", "nn", 18); 
    //     bytes32  data;

    //     clabels.push(
    //         PoolInstrument.CollateralLabel(
    //             address(collateral),
    //             0
    //         )
    //     );
    //     collaterals.push(
    //         PoolInstrument.Config(
    //         0,
    //         wad/2,
    //         wad/4,
    //         true
    //     )
    //     );
    //     marketmanager = new MarketManager(
    //         deployer,
    //         address(controller), 
    //         address(0),data, uint64(0)
    //     );
    //     ZCBFactory zcbfactory = new ZCBFactory(); 
    //     poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory)); 
    //     reputationManager = new ReputationManager(address(controller), address(marketmanager));
    //     leverageManager = new LeverageManager(address(controller), 
    //         address(marketmanager),address(reputationManager) );

    //     vm.startPrank(deployer); 
    //     controller.setMarketManager(address(marketmanager));
    //     controller.setVaultFactory(address(vaultFactory));
    //     controller.setPoolFactory(address(poolFactory)); 
    //     controller.setReputationManager(address(reputationManager));
    //     validatorManager = new ValidatorManager(address(controller), address(marketmanager),address(reputationManager) );        
    //     controller.setValidatorManager(address(validatorManager)); 
    //     controller.setLeverageManager(address(leverageManager)); 
    //     vm.stopPrank(); 

    //     controller.createVault(
    //         address(collateral),
    //         false,
    //         0,
    //         type(uint256).max,
    //         type(uint256).max,
    //         MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
    //         "description"
    //     ); //vaultId = 1; 
    //     vault_ad = controller.getVaultfromId(1); 

    //     setUsers();

    //     nftPool = new SimpleNFTPool(  vault_ad, toku, address(collateral)); 
    //     nftPool.setUtilizer(toku); 

    //     initiateSimpleNFTLendingPool(); 
    //     doInvest(vault_ad,  toku, 1e18*10000); 



    //     VariableInterestRate rateCalculator = new VariableInterestRate();

    //     PoolInstrument.CollateralLabel[] memory _clabels = clabels;
    //     PoolInstrument.Config[] memory _collaterals = collaterals;

    //     // console.log("pool setup");
    //     // console.log("rateContract", address(rateCalculator));

    //     // console.log("deployer:", deployer);
    //     pool = new PoolInstrument(
    //         vault_ad,
    //         address(reputationManager), 
    //         0,
    //         deployer,
    //         "pool 1",
    //         "P1",
    //         address(rateCalculator),
    //         initCallData,
    //         _clabels,
    //         _collaterals
    //     );
               
    //     // vm.prank(address(controller));
    //     // pool.addAcceptedCollateral(
    //     //     vault_ad,
    //     //     0,
    //     //     precision, 
    //     //     precision*9/10, 
    //     //     true
    //     // );      

    
    // }
   

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

        uint issueAmount; 
    }

    function testPoolLevMint() public returns(testVars1 memory){
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 

        vars.issueAmount = 100*precision; 
        uint leverageFactor = 3*precision; 
        uint amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        doApproveFromStart(vars.marketId,  amountToBuy); 

        doApproveCol(address(marketmanager), jonna); 
        doApproveCol(vars.vault_ad, jonna); 

        vm.prank(jonna); 
        Vault(vars.vault_ad).deposit(amountToBuy*10, jonna); 

        uint start = marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager));
        vm.prank(jonna); 

        leverageManager.issuePerpBondLevered(
            vars.marketId, 
            vars.issueAmount, 
            leverageFactor
        ); 
        uint mid = marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager));

        LeverageManager.LeveredBond memory bond = leverageManager.getPosition( vars.marketId,  jonna);

        // leveragemanager balance increases by issueAmount * pju; 
        // trader note increase 
        // trader balance decrease by amount/leverage 
        // trader balance 
        assertApproxEqAbs(bond.debt, (vars.issueAmount.divWadDown(leverageFactor)).mulWadDown(leverageFactor-precision),10 ); 
        // assertApproxEqAbs(bond.amount, (issueAmount.divWadDown(leverageFactor)).mulWadDown(), 10); 
        assertApproxEqAbs(mid-start, bond.amount,10); 
        // try again 
        // and assert same 
        vm.prank(jonna); 
        leverageManager.issuePerpBondLevered(
            vars.marketId, 
            vars.issueAmount, 
            leverageFactor
        ); 
        assertApproxEqAbs(leverageManager.getPosition( vars.marketId,  jonna).debt, 2*(vars.issueAmount.divWadDown(leverageFactor)).mulWadDown(leverageFactor-precision),10 ); 
        assertApproxEqAbs(marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager)) - start, 
            leverageManager.getPosition( vars.marketId,  jonna).amount, 10); 
        // assertApproxEqAbs(bond.amount, 2* issueAmount.divWadDown(leverageFactor), 10); 

        // leveragemanager balance increases by y 
        // 
        return vars; 

    }

    function testPoolLevWithdraw() public {
        testVars1 memory vars = testPoolLevMint(); 

        LeverageManager.LeveredBond memory bond = leverageManager.getPosition( vars.marketId,  jonna);

        // Try redeeming half amount, and then full 
        vm.prank(jonna);
        (uint256 collateral_redeem_amount, 
        uint256 postRepayLeftOver, 
        uint256 paidDebt) = leverageManager.redeemLeveredPerpLongZCB(vars.marketId, 
            vars.issueAmount/2); 

        LeverageManager.LeveredBond memory bond2 = leverageManager.getPosition( vars.marketId,  jonna);

        //difference in debt equals 
        // assertApproxEqAbs(bond.debt - bond2.debt, bond.debt - )
        assert(bond.debt>bond2.debt); 
        if(postRepayLeftOver==0) assertApproxEqAbs(bond.debt - bond2.debt, collateral_redeem_amount, 10); 
        assertApproxEqAbs(bond.amount-bond2.amount, vars.issueAmount/2, 10); 

        vm.prank(jonna);
        (collateral_redeem_amount, 
         postRepayLeftOver, 
         paidDebt) = leverageManager.redeemLeveredPerpLongZCB(vars.marketId, 
            bond2.amount); 
        LeverageManager.LeveredBond memory bond3 = leverageManager.getPosition( vars.marketId,  jonna);

        assertEq(bond3.amount,0);
        assertEq(bond3.debt, 0); 


        // assertApproxEqAbs()

    }

    function testFixedLevBuy() public returns(testVars1 memory){

        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 

        vars.issueAmount = 100*precision; 
        uint leverageFactor = 3*precision; 
        uint amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        uint start = marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager));
        doApproveCol(address(marketmanager), jonna); 

        vm.prank(jonna);
        leverageManager.buyBondLevered(
            vars.marketId, amountToBuy, 1e18, leverageFactor); 
        LeverageManager.LeveredBond memory bond = leverageManager.getPosition( vars.marketId,  jonna);
        uint mid = marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager));

        assertApproxEqAbs(bond.amount, mid-start, 10); 
        assertApproxEqAbs(bond.debt, (amountToBuy.divWadDown(leverageFactor)).mulWadDown(leverageFactor-precision),10 ); 
        console.log('position', bond.amount, bond.debt); 

        // DO once more
        vm.prank(jonna);
        (vars.amountIn,vars.amountOut) = leverageManager.buyBondLevered(
            vars.marketId, amountToBuy, 1e18, leverageFactor-precision); 
        LeverageManager.LeveredBond memory bond2 = leverageManager.getPosition( vars.marketId,  jonna);
        assertApproxEqAbs(bond2.amount-bond.amount, vars.amountOut,10); 
        assertApproxEqAbs(bond2.debt - bond.debt, vars.amountIn.divWadDown(leverageFactor-precision), 10); 
        assertApproxEqAbs(marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager)) - mid, 
            bond2.amount-bond.amount, 10); 
        console.log('position2', bond2.amount, bond2.debt); 
        return vars; 
    }

    function testFixedLevRedeem() public {
        testVars1 memory vars = testFixedLevBuy(); 

        doApprove(vars.marketId, vars.vault_ad);
        closeMarket(vars.marketId); 

        uint start = marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager));
        vm.prank(jonna); 

        leverageManager.redeemLeveredBond(vars.marketId);

        LeverageManager.LeveredBond memory bond = leverageManager.getPosition( vars.marketId,  jonna);
        assertEq(bond.amount,0); 
        assertEq(bond.debt, 0); 
        assertEq(marketmanager.getMarket(vars.marketId).longZCB.balanceOf(address(leverageManager)), 0); 
    }




//     function testMintWithLeverage() public{
//         testVars1 memory vars; 

//         vars.marketId = controller.getMarketId(toku); 
//         vars.vault_ad = controller.getVaultfromId(vars.marketId); 

//         uint poolCapital = 1000*precision; 
//         uint suppliedCapital = 100*precision; 
//         uint leverageFactor = 3*precision; 
    
//         address leverageModule_ad = address(leverageModule); 
//         vm.prank(jonna); 
//         collateral.approve(leverageModule_ad, type(uint256).max); 
//         doApproveCol(vars.vault_ad, jonna); 
//         vm.prank(jonna); 
//         Vault(vars.vault_ad).deposit(poolCapital, jonna); 

//         doApproveCol(address(pool), vars.vault_ad); 
//         //vm.prank(vars.vault_ad);
//         Vault(vars.vault_ad).addLendingModule(address(pool)); 
//         Vault(vars.vault_ad).pushToLM( poolCapital); 
//         //pool.deposit(1000*precision, vars.vault_ad); 

//         vars.cbalnow = cBal(address(pool)); 
//         vars.cbalnow2 = Vault(vars.vault_ad).balanceOf(address(pool)); 
//         vars.amountIn = Vault(vars.vault_ad).totalSupply(); 
//         leverageModule.addLeveragePool(1, address(pool));
//         vm.prank(jonna); 
//         (uint tokenId, LeverageModule.Position memory position) = leverageModule.mintWithLeverage(1, suppliedCapital, leverageFactor); 
//         console.log('final position shares', position.totalShares); 
//         console.log('final position suppliedCapital', position.suppliedCapital); 
//         console.log('final position borrowedCapital', position.borrowedCapital); 
//         console.log('final position endStateBalance', position.endStateBalance); 

//         // balance difference is supplied capital
//         // pool balance difference is borrowedcapital 
//         // total vault supply minted is totalshares
//         assertEq(position.suppliedCapital, suppliedCapital );
//         assertApproxEqAbs(position.borrowedCapital, vars.cbalnow - cBal(address(pool)), 10);  

//         assertEq(position.borrowedCapital, leverageFactor.mulWadDown(suppliedCapital));

//         assertApproxEqAbs(Vault(vars.vault_ad).totalSupply() - vars.amountIn, position.totalShares, 10); 

//         assertApproxEqAbs(position.totalShares,
//             Vault(vars.vault_ad).previewDeposit(suppliedCapital + suppliedCapital.mulWadDown(leverageFactor)) ,10); 

//         assertEq(position.endStateBalance, Vault(vars.vault_ad).balanceOf(address(leverageModule))); 
        
//         // Correct amount of collateral 
//         assertApproxEqAbs(Vault(vars.vault_ad).totalSupply() - vars.amountIn - position.endStateBalance, 
//             Vault(vars.vault_ad).balanceOf(address(pool)) - vars.cbalnow2, 10); 


//         /// TEST WITHDRAW 
//         uint withdrawAmount = suppliedCapital * 2; 
//         vars.cbalnow = cBal(address(pool)); 

//         leverageModule.rewindPartialLeverage(1, tokenId, withdrawAmount); 

//         LeverageModule.Position memory newposition = leverageModule.getPosition(tokenId); 
//         console.log('post withdraw position shares', newposition.totalShares); 
//         console.log('post withdraw position suppliedCapital', newposition.suppliedCapital); 
//         console.log('post withdraw position borrowedCapital', newposition.borrowedCapital); 
//         console.log('post withdraw position endStateBalance', newposition.endStateBalance);  


//         assertEq(newposition.totalShares, position.totalShares-withdrawAmount); 
//         assertEq(newposition.suppliedCapital, position.suppliedCapital);
//         assertApproxEqAbs(newposition.borrowedCapital, position.borrowedCapital- 
//             Vault(vars.vault_ad).previewMint(withdrawAmount), 10); 
//         assert(newposition.endStateBalance > position.endStateBalance);
//                 console.log('2');

//         // assertApproxEqAbs(Vault(vars.vault_ad).balanceOf(address(leverageModule)), 
//         //     newposition.endStateBalance, 10); 
//         //         console.log('3');

//         assertApproxEqAbs(cBal(address(pool)) - vars.cbalnow, 
//             Vault(vars.vault_ad).previewMint(withdrawAmount), 10); 
//                 console.log('4');

//         uint[] memory ids = leverageModule.getTokenIds( jonna); 
//         console.log('tokenIds', ids[0], tokenId, ids.length); 

//         // test borrow/supply of pool 
//         // test endstatebalance
//         // test entire solvency 

//         //assertApproxEqAbs(); 
//     }

//     function testPushToLeverage() public returns(testVars1 memory){
//         // trigger vault unutilized balance to leverage vault, and borrow from that vault 
//         uint investAmount = 100e18; 
//         uint pushAmount = 30e18; 
//         testVars1 memory vars;  
//         vars.amountIn = pushAmount; 
//         vars.marketId = controller.getMarketId(toku); 
//         vars.vault_ad = controller.getVaultfromId(vars.marketId); 
//         uint startPreview = pool.previewMint(1e18); 
//         uint startAssets = pool.totalAssets(); 
//         Vault(vars.vault_ad).addLendingModule(address(pool)); 

//         doInvest(vars.vault_ad, jonna,  investAmount); 
//         uint vaultBal = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 

//         Vault(vars.vault_ad).pushToLM( pushAmount); 
//         if(pushAmount==0) {
//             assertEq(Vault(vars.vault_ad).utilizationRate(), precision); 
//             assertEq(pool.totalAssets() - startAssets, vaultBal); 
//         }
//         else if(pushAmount>0) {
//             assertApproxEqAbs(Vault(vars.vault_ad).utilizationRate(), pushAmount.divWadDown(vaultBal), 10);
//             assertApproxEqAbs(pool.totalAssets() - startAssets, pushAmount, 10); 
//         }

//         assertEq(pool.previewMint(1e18), startPreview); 
//         return vars; 

// //1e18*10000

//     }

//     function testPullFromLeverage() public {
//         testVars1 memory vars = testPushToLeverage(); 

//         // able to pull from vault if need be 
//         vars.amountOut = vars.amountIn; 
//         vars.valamountIn = pool.balanceOf(vars.vault_ad); 
//         uint startbal = pool.totalAssets(); 
//         Vault(vars.vault_ad).pullFromLM(vars.amountOut); 
//         assertApproxEqAbs(vars.valamountIn - pool.balanceOf(vars.vault_ad), pool.previewDeposit(vars.amountOut), 10);
//         assertEq(startbal - pool.totalAssets(), vars.amountOut); 

//     }

    function testDeletePosition() public{

    }

    function _testWithdrawLeverage() public {

    }


    //function testMintWithLeverageNotLiq()
    //function testProfit

    

}


