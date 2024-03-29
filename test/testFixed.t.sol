pragma solidity ^0.8.4;


import "forge-std/Test.sol";
import "forge-std/console.sol";
import  "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {Cash} from "../contracts/utils/Cash.sol";
// import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {ERC20CreditLine} from "../contracts/instruments/creditline.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {LinearPiecewiseCurve, SwapParams} from "../contracts/bonds/linearCurve.sol"; 

import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {CustomTestBase} from "./testbase.sol"; 
import "../contracts/global/types.sol"; 

contract FixedTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    ERC20CreditLine instrument;

    function setUp() public {

        // controller = new Controller(deployer); // zero addr for interep
        // vaultFactory = new VaultFactory(address(controller));
        // collateral = new Cash("n","n",18);
        // collateral2 = new Cash("nn", "nn", 18); 
        // bytes32  data;
        // marketmanager = new MarketManager(
        //     deployer,
        //     address(controller), 
        //     address(0),data, uint64(0)
        // );
        // ZCBFactory zcbfactory = new ZCBFactory(); 
        // poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory));
        // reputationManager = new ReputationManager(address(controller), address(marketmanager)); 
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
        console.log("vault created", controller.vaults(1).description());
        vault_ad = controller.getVaultfromId(1); 
        setUsers();


        doInvest(vault_ad,  toku, 1e18*10000); 

        // address vault,
        // address _borrower,
        // uint256 _proposedPrincipal,
        // uint256 _proposedNotionalInterest, 
        // uint256 _duration,
        // uint256 _requiredBalance,
        // address _collateral
        instrument = new ERC20CreditLine(
            vault_ad, 
            jott, 
            principal, 
            interest, 
            duration, 
            address(collateral),
            principal
        ); 

        otc = new CoveredCallOTC(
            vault_ad, toku, 
            strikeprice, //strikeprice 
            pricePerContract, //price per contract
            shortCollateral, 
            longCollateral, 
            address(collateral),
            10, 
            block.timestamp
            ); 
        //otc.setUtilizer(toku); 

        initiateCreditMarket(); 
        initiateOptionsOTCMarket(); 
    }

  

    // function testFailApproval() public{
    //     address proxy =  instrument.getProxy(); 
    //     borrowerContract.changeOwner(proxy); 
    //     assertEq(borrowerContract.owner(), proxy); 
    //     uint256 marketId = controller.getMarketId(jott); 

    //     controller.approveMarket(marketId);

    // }

    // struct testVars1{
    //     uint256 marketId;
    //     address vault_ad; 
    //     uint amountToBuy; 
    //     uint curPrice; 

    //     uint amountIn;
    //     uint amountOut; 

    //     uint valamountIn; 
    //     uint cbalnow; 
    // }

    function testOneLongNoShortApproval() public{
        console.log('?'); 
        testVars1 memory vars; 

        // address proxy =  instrument.getProxy(); 
        // borrowerContract.changeOwner(proxy); 
        // borrowerContract.autoDelegate(proxy);
        // assertEq(borrowerContract.owner(), proxy); 

        vars.marketId = controller.getMarketId(jott); 

        vars.vault_ad = controller.getVaultfromId(1); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal/2; 
        vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
        assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice + precision , data); 
        assertApproxEqAbs(vars.amountIn, vars.amountToBuy, 10); 
        assertEq(marketmanager.loggedCollaterals(vars.marketId),vars.amountIn); 
        assert(controller.marketCondition(vars.marketId)); 
        assert(marketmanager.getPool(vars.marketId).getCurPrice() > vars.curPrice ); 

        // let validator invest to vault and approve 
        vars.cbalnow = cBal(address(marketmanager.getPool(vars.marketId))); 
        doApprove(vars.marketId, vars.vault_ad);
        // doApproveCol(vars.vault_ad, gatdang); 
        // doInvest(vars.vault_ad, gatdang, precision * 1000);
        // doApproveCol(address(marketmanager), gatdang); 
        // instrument.setValidator(gatdang);  
        // vm.prank(gatdang);
        // vars.valamountIn = controller.validatorApprove(vars.marketId); 
        assertApproxEqAbs(vars.cbalnow + vars.valamountIn - cBal(address(marketmanager.getPool(vars.marketId))), 
            vars.valamountIn + vars.amountIn,10); 

       //how much bond are issued? , TODO, chooses validators randomly
        // assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna) +
        // marketmanager.getZCB(vars.marketId).balanceOf(gatdang), marketmanager.getZCB(vars.marketId).totalSupply()); 

    }

    struct testVars2{
        address utilizer; 

        uint256 marketId;
        address vault_ad; 
        uint curPrice; 
        uint principal; 
        uint amount1; 
        uint amount2; 
        uint amount3; 
        uint amount4; 
        uint amount5; 
        uint amount6; 
        uint amount7; 

        uint amountIn;
        uint amountOut; 
        uint s_amountIn; 
        uint s_amountOut; 

        uint vaultBal; 
        uint cbalbefore; 
        uint ratebefore; 
        uint vaultBalBeforeRedeem; 
        uint sumofcollateral; 

        uint maxSupply; 
        bool dontAssert; 

        uint longsupply; 
        uint shortsupply; 


    }

    function somelongsomeshort(testVars2 memory vars, bool finish) public {

        // address proxy =  instrument.getProxy(); 
        // borrowerContract.changeOwner(proxy); 
        // borrowerContract.autoDelegate(proxy);
        // assertEq(borrowerContract.owner(), proxy); 

        if(vars.utilizer==address(0)) vars.utilizer = jott;  
        vars.marketId = controller.getMarketId(vars.utilizer); 

        vars.maxSupply = (precision - marketmanager.getPool(vars.marketId).b_initial()).divWadDown( marketmanager.getPool(vars.marketId).a_initial() ) ; 

        vars.vault_ad = controller.getVaultfromId(1); //
        vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
        if(!vars.dontAssert)assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 
        vars.principal = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal; 

        // try a bunch of numbers 
        // vars.amount1 = vars.principal*11/100; 
        // vars.amount2 = vars.principal*7/100; 
        // vars.amount3 = vars.principal*11/100; //shorting 
        // vars.amount4 = vars.principal*12/100; 
        bytes memory data; 

        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, -int256(vars.amount1), vars.curPrice + precision/10 , data); 

        doApproveCol(address(marketmanager), sybal); 
        vm.prank(sybal); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, -int256(vars.amount2), vars.curPrice + precision/10 , data); 

        doApproveCol(address(marketmanager), chris); 
        vm.prank(chris); 
        (vars.s_amountIn, vars.s_amountOut) =
            marketmanager.shortBond(vars.marketId, vars.amount3, 0, data); 

        doApproveCol(address(marketmanager), miku); 
        vm.prank(miku); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, -int256(vars.amount4), vars.curPrice + precision/10 , data); 
            
        if(!vars.dontAssert){
        // bought amount1+amount2 - amount3+amount4 
        assertApproxEqAbs(marketmanager.getZCB(vars.marketId).totalSupply(), 
            vars.amount1 + vars.amount2 + vars.amount4, 10); 
        assertApproxEqAbs(marketmanager.getShortZCB(vars.marketId).totalSupply(), vars.amount3, 10); 

        // logged collateral is at area under the curve of amount1+amount2 - amount3+amount4 
        assertApproxEqAbs(LinearCurve.areaUnderCurve(vars.amount1 + vars.amount2 + vars.amount4 - vars.amount3, 
            0, marketmanager.getPool(vars.marketId).a_initial(), marketmanager.getPool(vars.marketId).b()),
            marketmanager.loggedCollaterals(vars.marketId) , 100000); 

        // price is ax+b for x = amount1+amount2 - amount3+amount4 
        assertApproxEqAbs( marketmanager.getPool(vars.marketId).a_initial()
            .mulWadDown(vars.amount1 + vars.amount2 + vars.amount4 - vars.amount3) 
            + marketmanager.getPool(vars.marketId).b() , marketmanager.getPool(vars.marketId).getCurPrice(), 100000); 
        // assert(!marketmanager.marketCondition(vars.marketId)); 
        }
        // now buy 
        if (finish){
            doApproveCol(address(marketmanager), jonna); 
            vm.prank(jonna); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount5), vars.curPrice + precision/10 , data); 

            doApproveCol(address(marketmanager), sybal); 
            vm.prank(sybal); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount6), vars.curPrice + precision/10 , data); 
            vm.prank(sybal); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount7), vars.curPrice + precision/10 , data); 

        }

        vars.longsupply = Data.getMarket(vars.marketId).longZCB.totalSupply(); 
        vars.shortsupply = Data.getMarket(vars.marketId).shortZCB.totalSupply(); 
        assertApproxEqAbs(vars.longsupply, vars.amount1+ vars.amount2+vars.amount4+
            vars.amount5+vars.amount6+vars.amount7,5); 
        assertApproxEqAbs(vars.shortsupply, vars.amount3, 5); 
    }

    // function doApprove(uint256 marketId, address vault) public{ //TODO: update
    //     // validators invest and approve 
    //     address[] memory vals = controller.viewValidators(marketId);
    //     console.log("val.length", vals.length);
    //     uint256 initialStake = controller.getInitialStake(marketId);
    //     for (uint i=0; i < vals.length; i++) {
    //         doApproveCol(vault, vals[i]);
    //         doApproveVault(vault, vals[i], address(controller));
    //         doApproveCol(address(marketmanager), vals[i]);
    //         doMint(vault, vals[i], initialStake);
    //         vm.prank(vals[i]);
    //         controller.validatorApprove(marketId);
    //     }
    // }

    // // function doApproveOTC(testVars2 memory vars) public{
    // //     // validators invest and approve  
    // //     doApproveCol(vars.vault_ad, gatdang); 
    // //     doInvest(vars.vault_ad, gatdang, precision * 1000);
    // //     doApproveCol(address(marketmanager), gatdang); 
    // //     otc.setValidator( gatdang);  
    // //     vm.prank(gatdang); 
    // //     controller.validatorApprove(vars.marketId); 
    // // }

    // function doDeny(testVars2 memory vars) public {

    //     vars.vaultBal = collateral.balanceOf(controller.getVaultAd(vars.marketId));  
    //     vars.cbalbefore = marketmanager.getPool(vars.marketId).cBal(); 
    //     address[] memory vals = controller.viewValidators(vars.marketId);
    //     vm.prank(vals[0]);
    //     controller.denyMarket(vars.marketId);
    //     // vm.prank(gatdang);
    //     // controller.denyMarket(vars.marketId); 
    //     assertEq(marketmanager.getPool(vars.marketId).cBal(), 0); 
    //     assertApproxEqAbs(collateral.balanceOf(controller.getVaultAd(vars.marketId)) - vars.vaultBal, vars.cbalbefore, 10); 
    // }

    // function closeMarket(testVars2 memory vars) public {
    //     address[] memory vals = controller.viewValidators(vars.marketId);
    //     for (uint i=0; i < vals.length; i++) {
    //         vm.prank(vals[i]);
    //         controller.validatorResolve(vars.marketId);
    //     }
    //     vm.startPrank(vals[0]); 
    //     controller.beforeResolve(vars.marketId); 
    //     vm.roll(block.number+1);
    //     controller.resolveMarket(vars.marketId); 
    //     assertEq(collateral.balanceOf(address(instrument)),0); 
    //     vm.stopPrank(); 
    // }

    // function setMaturityInstrumentResolveCondition(bool noDefault, uint256 loss) public{
    //     // different conditions lead to different redemption prices 
    //     if(noDefault){
    //         vm.prank(jonna); 
    //         collateral.approve(address(this), type(uint256).max); 
    //         collateral.transferFrom(jonna, address(instrument), interest);  
    //     }

    //     else{
    //         vm.prank(jonna); 
    //         collateral.approve(address(this), type(uint256).max); 
    //         collateral.transferFrom(jonna, address(instrument), interest);

    //         vm.prank(address(instrument)); 
    //         collateral.approve(address(this), type(uint256).max); 
    //         collateral.transferFrom(address(instrument), jonna, loss); 
    //     }
    // }



    // @notice X people are long or short and approval after, 
    // check: can't approve if total collateral doesn't meet 
    // check: correct amount went to instrument  
    // check: vault exchange rate same  
    // check: logged manager collateral correct
    // check: controller has short collateral+ longcollateral 
    function testSomeLongSomeShortApprove(
        uint256 amount1, 
        uint256 amount2, 
        uint256 amount3, 
        uint256 amount4,
        uint256 amount5, 
        uint256 amount6,
        uint256 amount7
        ) public returns(testVars2 memory){
        testVars2 memory vars; 

        vars.vault_ad = controller.getVaultfromId(1); //
        vars.marketId = controller.getMarketId(jott); 

        vars.principal = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal; 
        console.log('principal', vars.principal); 
        vars.amount1 = constrictToRange(amount1, 1e14, vars.principal/5);// vars.principal*11/100; 
        vars.amount2 = constrictToRange(amount2, 1e14, vars.principal/5);// vars.principal*7/100; 
        vars.amount3 = constrictToRange(amount3, 1e14, vars.amount1+vars.amount2);//vars.principal*11/100; //shorting 
        vars.amount4 = constrictToRange(amount4, 1e14, vars.principal/5);//vars.principal*12/100; 
        vars.amount5 = constrictToRange(amount5, 1e14, vars.principal/5);
        vars.amount6 = constrictToRange(amount6, 1e14, vars.principal/5);
        vars.amount7 = constrictToRange(amount7, 1e14, vars.principal/5);
        console.log('amounts', vars.amount1, vars.amount2, vars.amount3); 
        console.log( vars.amount4,vars.amount5,vars.amount6,vars.amount7); 

        vars.maxSupply = (precision - marketmanager.getPool(vars.marketId).b_initial()).divWadDown( marketmanager.getPool(vars.marketId).a_initial() ) ; 

        uint netCollateral = vars.amount1+vars.amount2-vars.amount3
            +vars.amount4+vars.amount5+vars.amount6+vars.amount7; 
        vm.assume(netCollateral<= vars.maxSupply/2); 

        (uint a, uint b) = (Data.getMarket(vars.marketId).bondPool.a_initial(),  Data.getMarket(vars.marketId).bondPool.b_initial());
        uint amountOut = LinearPiecewiseCurve.areaUnderCurve(netCollateral, 0, a, b); 
        vm.assume(amountOut>vars.principal.mulWadDown(alpha)); 
        console.log('amountout and principal alpha', amountOut, vars.principal.mulWadDown(alpha)); 
        somelongsomeshort(vars, true);

        vars.cbalbefore = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 

        vars.cbalbefore = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 



        // logged collateral equals area under curve 
        assertApproxEqBasis(marketmanager.loggedCollaterals(vars.marketId), amountOut, 1); 
          
        if(!controller.marketCondition(vars.marketId)) revert("marketCondition") ; 
        doApprove(vars.marketId, vars.vault_ad); 

        ApprovalData memory test = controller.getApprovalData(vars.marketId);

        assertApproxEqAbs(vars.cbalbefore - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad), 
        test.approved_principal - test.managers_stake,100 ); 
        assertEq(vars.ratebefore,Vault(vars.vault_ad).previewMint(1e18) ); 



        return vars; 
    }

    // @notice fixed instrument resolve market pay all, rate increment by how much 
    // resolve market fixed vault exchange rate increment by how much when redemption price1
    // novalidator
    // check: vault profit share is correct
    // check: everyone can redeem 
    function testResolveMarketVaultExchangeRateFull(
        uint256 amount1, 
        uint256 amount2, 
        uint256 amount3, 
        uint256 amount4, 
        uint256 amount5,
        uint256 amount6,
        uint256 amount7
        ) public {
        uint controllerBalBefore = collateral.balanceOf(address(controller)); 

        testVars2 memory vars  = testSomeLongSomeShortApprove(
            amount1, amount2, amount3, amount4, amount5, amount6, amount7
            ); 
        InstrumentData memory data = Data.getInstrumentData(vars.marketId); 

        donateToInstrument(vars.vault_ad, address(instrument), data.expectedYield, vars.marketId); //TODO expected yield

        resolveMarket(vars.marketId);
        // vm.startPrank(deployer); 
        // controller.validatorResolve(vars.marketId); 
        // controller.beforeResolve(vars.marketId);
        // controller.resolveMarket(vars.marketId); 
        // vm.stopPrank(); 

        ApprovalData memory test = controller.getApprovalData(vars.marketId);

        // look at area 
        console.log('??', data.principal+ data.expectedYield , test.approved_principal-test.managers_stake, 
            Data.getMarket(vars.marketId).bondPool.discount_cap()+ 
            (vars.amount1 + vars.amount2 + vars.amount4 +vars.amount5+vars.amount6+vars.amount7- vars.amount3)); 
        uint vaultshare = data.principal+ data.expectedYield 
        - (test.approved_principal-test.managers_stake
            +Data.getMarket(vars.marketId).bondPool.discount_cap()+ 
            (vars.amount1 + vars.amount2 + vars.amount4 +vars.amount5+vars.amount6+vars.amount7- vars.amount3)
            ); 

        // Vault profit 
        console.log('vaultshare',Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) , vars.cbalbefore ); 
        assertApproxEqAbs(vaultshare, Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalbefore, 1000, "vaultshare"); 

        // Everyone redeem
        // uint longsupply = Data.getMarket(vars.marketId).longZCB.totalSupply(); 
        // uint shortsupply = Data.getMarket(vars.marketId).shortZCB.totalSupply(); 
        // uint redemptionPrice = marketmanager.redemption_prices(vars.marketId); 
        // assert(redemptionPrice==1e18); 
        // assertApproxEqAbs(collateral.balanceOf(address(controller)) - controllerBalBefore, 
        //     vars.longsupply.mulWadDown(redemptionPrice) + vars.shortsupply.mulWadDown(1e18-redemptionPrice)
        //     , 100); 
    }






    // function testSomeLongSomeShortDeny() public{
    //     testVars2 memory vars; 

    //     somelongsomeshort(vars, true);

    //     // validators deny 
    //     doDeny(vars); 

    //     vars.sumofcollateral = marketmanager.longTrades(vars.marketId, jonna)
    //     +marketmanager.longTrades(vars.marketId, sybal)
    //     +marketmanager.shortTrades(vars.marketId, chris)
    //     +marketmanager.longTrades(vars.marketId, chris)
    //     +marketmanager.longTrades(vars.marketId, miku); 
    //     assertApproxEqAbs(vars.sumofcollateral, vars.cbalbefore, 10); 

    //     vars.vaultBalBeforeRedeem = collateral.balanceOf(controller.getVaultAd(vars.marketId)); 

    //     // LEt everyone redeem, total redemption should equal their contribution 
    //     vm.prank(jonna); 
    //     marketmanager.redeemDeniedMarket(vars.marketId, true); 
    //     vm.prank(sybal); 
    //     marketmanager.redeemDeniedMarket(vars.marketId, true); 
    //     vm.prank(chris); 
    //     marketmanager.redeemDeniedMarket(vars.marketId, false); 
    //     vm.prank(miku); 
    //     marketmanager.redeemDeniedMarket(vars.marketId, true); 
    //     assertApproxEqAbs(
    //         vars.vaultBalBeforeRedeem - collateral.balanceOf(controller.getVaultAd(vars.marketId)) , 
    //         vars.sumofcollateral, 10
    //         );
    // }

    // function testLPsCanShortBeforeApproval() public{
    //     testVars2 memory vars; 

    //     somelongsomeshort(vars, false);

    //     bytes memory data; 
    //     doApproveCol(address(marketmanager), goku); 
    //     vm.prank(goku); 
    //     (vars.s_amountIn, vars.s_amountOut) =
    //         marketmanager.shortBond(vars.marketId, vars.amount1, vars.curPrice + precision/10 , data); 
    //     assertApproxEqAbs(marketmanager.getShortZCB(vars.marketId).balanceOf(goku),  vars.s_amountIn+ vars.s_amountOut, 10); 

    //     //redeem denied 
    //     uint balbefore = collateral.balanceOf(goku); 
    //     doDeny(vars); 
    //     vm.prank(goku); 
    //     marketmanager.redeemDeniedMarket(vars.marketId, false); 
    //     assertEq(marketmanager.getShortZCB(vars.marketId).balanceOf(goku), 0);
    //     assertApproxEqAbs(collateral.balanceOf(goku)-balbefore, vars.s_amountIn, 10);  
    // }

    // function testLPsCanLongAndShortAfterApproval() public{

    //     testVars2 memory vars; 

    //     somelongsomeshort(vars, true); 

    //     doApprove(vars.marketId, vars.vault_ad); 

    //     //set bids at current price 
    //      bytes memory data = abi.encode(uint16(uint16(marketmanager.getPool(vars.marketId).getCurPrice()/1e16) -1),
    //        false ); 
    //     doApproveCol(address(marketmanager.getPool(vars.marketId)), jonna); 
    //     vm.prank(jonna); 
    //     marketmanager.buyBond(vars.marketId, int256(vars.amount1) , 0, data); 

    //     // let someone short
    //     bytes memory data2 = abi.encode(0,
    //        true ); 
    //     doApproveCol(address(marketmanager), goku); 
    //     vm.prank(goku); 
    //     (vars.s_amountIn, vars.s_amountOut) =
    //         marketmanager.shortBond(vars.marketId, vars.amount3, vars.curPrice - precision/10 , data2); 
    //     assertApproxEqAbs(vars.s_amountIn+ vars.s_amountOut, vars.amount3 , 10);

    //     // let someone close long limit 
    //     uint256 bal2 = marketmanager.getZCB(vars.marketId).balanceOf(jonna); 
    //     bytes memory data4 = abi.encode(uint16(uint16(marketmanager.getPool(vars.marketId).getCurPrice()/1e16) +1),
    //        false ); 
    //     vm.prank(jonna); 
    //     marketmanager.sellBond( vars.marketId, bal2, 0, data4); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna), 0); 

    //      // close all short via limit or via taker. half via limit half via taker 
    //     bytes memory data3 = abi.encode(uint16(uint16(marketmanager.getPool(vars.marketId).getCurPrice()/1e16) -1),
    //        false ); 
    //     uint256 bal = marketmanager.getShortZCB(vars.marketId).balanceOf(goku); 
    //     vm.prank(goku); 
    //     marketmanager.coverBondShort(vars.marketId, bal/2, 0, data3);   // limit
    //     vm.prank(goku); 
    //     marketmanager.coverBondShort(vars.marketId, (bal/2)-1, 0, data2); // taker, buy up 
    //     assertApproxEqAbs(marketmanager.getShortZCB(vars.marketId).balanceOf(goku),0,1); 
        
    // }


    // function testManagersCompensationVanilaRedeem() public{
    //     testVars2 memory vars; 

    //     somelongsomeshort(vars, true); 

    //     doApprove(vars.marketId, vars.vault_ad); 

    //     setMaturityInstrumentResolveCondition(true, 0); 
    //     //setMaturityInstrumentResolveCondition(false, precision*2); 

    //     closeMarket(vars); 

    //     uint vaultbalbefore = collateral.balanceOf(controller.getVaultAd(vars.marketId)); 
    //     //longers
    //     uint balbefore = collateral.balanceOf(jonna); 
    //     uint zcbbal = marketmanager.getZCB(vars.marketId).balanceOf(jonna); 
    //     uint longsupply = marketmanager.getZCB(vars.marketId).totalSupply();
    //     uint shortsupply = marketmanager.getShortZCB(vars.marketId).totalSupply(); 

    //     vm.prank(jonna); 
    //     marketmanager.redeem(vars.marketId); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna) , 0); 
    //     assertApproxEqAbs(collateral.balanceOf(jonna) - balbefore , marketmanager.redemption_prices(vars.marketId).mulWadDown(
    //         zcbbal), 10); 

    //     balbefore = collateral.balanceOf(sybal); 
    //     zcbbal = marketmanager.getZCB(vars.marketId).balanceOf(sybal); 
    //     vm.prank(sybal); 
    //     marketmanager.redeem(vars.marketId); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(sybal) , 0); 
    //     assertApproxEqAbs(collateral.balanceOf(sybal) - balbefore , marketmanager.redemption_prices(vars.marketId).mulWadDown(
    //         zcbbal), 10);  

    //     balbefore = collateral.balanceOf(miku); 
    //     zcbbal = marketmanager.getZCB(vars.marketId).balanceOf(miku); 
    //     vm.prank(miku); 
    //     marketmanager.redeem(vars.marketId); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(miku) , 0); 
    //     assertApproxEqAbs(collateral.balanceOf(miku) - balbefore , marketmanager.redemption_prices(vars.marketId).mulWadDown(
    //         zcbbal), 10);     

    //     //shorter 
    //     // balbefore = collateral.balanceOf(chris); 
    //     // zcbbal = marketmanager.getShortZCB(vars.marketId).balanceOf(chris); //shorter  
    //     // vm.prank(chris); 
    //     // marketmanager.redeemShortZCB(vars.marketId); 
    //     // assertEq(marketmanager.getShortZCB(vars.marketId).balanceOf(chris) , 0); 
    //     // assertApproxEqAbs(collateral.balanceOf(chris) - balbefore , (precision-marketmanager.get_redemption_price(vars.marketId)).mulWadDown(
    //     //     zcbbal), 10);  
         
    //     //validator 
    //     // balbefore = collateral.balanceOf(gatdang); 
    //     // zcbbal = marketmanager.getZCB(vars.marketId).balanceOf(gatdang); //shorter
    //     address[] memory vals = controller.viewValidators(vars.marketId);
    //     console.log(vals[0]);
        
    //     for (uint256 i=0; i< vals.length;i++) {
    //         vm.prank(vals[i]);
    //         marketmanager.redeem(vars.marketId); 
    //     }
 
    //     // assertEq(marketmanager.getZCB(vars.marketId).balanceOf(gatdang) , 0); 
    //     // assertApproxEqAbs(collateral.balanceOf(gatdang) - balbefore , marketmanager.get_redemption_price(vars.marketId).mulWadDown(
    //     //     zcbbal), 10);  

    //     //invariant 1: longsupply * redemption + shortsupply * 1-redemption = difference in vault balance 
    //     assertApproxEqAbs( longsupply.mulWadDown(marketmanager.redemption_prices(vars.marketId)) +
    //         shortsupply.mulWadDown(precision - marketmanager.redemption_prices(vars.marketId)), 
    //     vaultbalbefore - collateral.balanceOf(controller.getVaultAd(vars.marketId)), 100);

    //     // invariant 2: return for manager> return for LP 
    //     assert(
    //     (longsupply-shortsupply).divWadDown(marketmanager.loggedCollaterals(vars.marketId) ) 
    //         > 
    //     (vars.maxSupply - (longsupply-shortsupply)).divWadDown(principal - marketmanager.loggedCollaterals(vars.marketId) )
    //     ); 
    //     console.log('returns', (longsupply-shortsupply).divWadDown(marketmanager.loggedCollaterals(vars.marketId) )  , 
    //         (vars.maxSupply - (longsupply-shortsupply)).divWadDown(principal - marketmanager.loggedCollaterals(vars.marketId) )
    //             ); 

    //     //invariant 3: profit for longs + profit for lps = interest 
    //     uint profitForlongs = (longsupply-shortsupply) - marketmanager.loggedCollaterals(vars.marketId); 
    //     uint profitForLps = vars.maxSupply - (longsupply-shortsupply) - (principal - marketmanager.loggedCollaterals(vars.marketId)); 
    //     console.log(profitForlongs  , profitForLps, interest); 
    //     assertApproxEqAbs(profitForlongs  + profitForLps, interest, 1000000); //TODO round fixes 

    //     // invariant 4: different in vault balance 
    //     // invariant 5: pool balance 

    // }

    // function testReputationIncreaseAndLeverageUp() public {
    //     testVars2 memory vars; 
    //     somelongsomeshort(vars, true); 
    //     doApprove(vars.marketId, vars.vault_ad); 
    //     bool increase = false; 
    //     uint loss = 100*precision; 

    //     if(increase)
    //     setMaturityInstrumentResolveCondition(true, 0); 
    //     else
    //     setMaturityInstrumentResolveCondition(false, loss); 

    //     closeMarket(vars); 

    //     uint scoreBefore1 = controller.getTraderScore( jonna); 
    //     uint scoreBefore2 = controller.getTraderScore( sybal); 
    //     uint scoreBefore3 = controller.getTraderScore( miku); 
    //     uint scoreBefore4 = controller.getTraderScore( chris); 
    //     uint scoreBefore5 = controller.getTraderScore( gatdang); 
    //     // uint scoreBefore4 = controller.getTraderScore( jonna); 

    //     // Now let managers redeem, reputation score dif
    //     vm.prank(jonna); 
    //     marketmanager.redeem(vars.marketId); 
    //     vm.prank(sybal); 
    //     marketmanager.redeem(vars.marketId); 
    //     vm.prank(miku); 
    //     marketmanager.redeem(vars.marketId); 
    //     vm.prank(chris); 
    //     marketmanager.redeemShortZCB(vars.marketId);
    //     vm.prank(gatdang); 
    //     marketmanager.redeem(vars.marketId);

    //     if (increase){
    //     assert(controller.getTraderScore(jonna)> scoreBefore1);  
    //     assert(controller.getTraderScore(sybal)> scoreBefore2);  
    //     assert(controller.getTraderScore(miku)> scoreBefore3);  
    //     assert(controller.getTraderScore(chris)== scoreBefore4);  

    //     }
    //     else{
    //     assert(controller.getTraderScore(jonna)< scoreBefore1);  
    //     assert(controller.getTraderScore(sybal)< scoreBefore2);  
    //     assert(controller.getTraderScore(miku)< scoreBefore3);  
    //     assert(controller.getTraderScore(chris)== scoreBefore4);  
    //     }
  

    //     console.log('before after', scoreBefore1,controller.getTraderScore(jonna) ); 
    //     console.log('before after', scoreBefore2,controller.getTraderScore(sybal) ); 
    //     console.log('before after', scoreBefore3,controller.getTraderScore(miku) ); 
    //     console.log(marketmanager.getMaxLeverage(jonna)); 
    // }

    // function testLeverageBuyAndRedemption() public{
    //     testVars2 memory vars; 
    //     uint leverage = 2; 
    //     bool increase = true; 
    //     uint loss = 120*precision; 

    //     vars.marketId = controller.getMarketId(jott); 

    //     vars.maxSupply = (precision - marketmanager.getPool(vars.marketId).b_initial()).divWadDown( marketmanager.getPool(vars.marketId).a_initial() ) ; 

    //     vars.vault_ad = controller.getVaultfromId(1); //
    //     vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
    //     assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 
    //     vars.principal = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal; 
    //     vars.amount1 = vars.principal*11/100; 

    //     doApproveCol(vars.vault_ad, gatdang); 
    //     doInvest(vars.vault_ad, gatdang, precision * 1000);

    //     bytes memory data; 

    //     reputationManager.setTraderScore(miku, precision*5); 
    //     uint bal = collateral.balanceOf(miku); 
    //     doApproveCol(address(marketmanager), miku); 
    //     vm.prank(miku);
    //     marketmanager.buyBondLevered(vars.marketId, vars.amount1, vars.curPrice + precision/10, precision *leverage); 
    //     (uint debt, uint amount) = marketmanager.leveragePosition(vars.marketId, miku); 

    //     assertApproxEqAbs(debt , vars.amount1 - (bal - collateral.balanceOf(miku) ),10 ); 
    //     assertApproxEqAbs(marketmanager.loggedCollaterals(vars.marketId), vars.amount1, 10); 

    //     //redeem 
    //     vars.dontAssert = true; 
    //     somelongsomeshort(vars, true); 
    //     doApprove(vars.marketId, vars.vault_ad); 
    //     if(increase) setMaturityInstrumentResolveCondition(true, 0); 
    //     else setMaturityInstrumentResolveCondition(false,loss); 
    //     closeMarket(vars); 
    //     vars.cbalbefore = collateral.balanceOf(miku); 
        
    //     vm.prank(miku); 

    //     marketmanager.redeemLeveredBond(vars.marketId); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(address(marketmanager)) , 0); 
    //     console.log('?',  collateral.balanceOf(miku) - vars.cbalbefore, 
    //         marketmanager.redemption_prices(vars.marketId).mulWadDown(
    //         amount) - debt); 
    //     assertApproxEqAbs(collateral.balanceOf(miku) - vars.cbalbefore , 
    //         marketmanager.redemption_prices(vars.marketId).mulWadDown(
    //         amount) - debt, 10);          
        

    //     //reputation 

    // }

    // function testLeverageBuyDenied() public{
    //     testVars2 memory vars; 
    //     uint leverage = 2; 
    //     bool increase = true; 
    //     uint loss = 120*precision; 

    //     vars.marketId = controller.getMarketId(jott); 

    //     vars.maxSupply = (precision - marketmanager.getPool(vars.marketId).b_initial()).divWadDown( marketmanager.getPool(vars.marketId).a_initial() ) ; 

    //     vars.vault_ad = controller.getVaultfromId(1); //
    //     vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
    //     assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 
    //     vars.principal = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal; 
    //     vars.amount1 = vars.principal*11/100; 

    //     doApproveCol(vars.vault_ad, gatdang); 
    //     doInvest(vars.vault_ad, gatdang, precision * 1000);

    //     bytes memory data;

    //     reputationManager.setTraderScore(miku, precision*5); 
    //     uint bal = collateral.balanceOf(miku); 
    //     doApproveCol(address(marketmanager), miku); 
    //     vm.prank(miku);
    //     marketmanager.buyBondLevered(vars.marketId, vars.amount1, vars.curPrice + precision/10, precision *leverage); 
    //     (uint debt, uint amount) = marketmanager.leveragePosition(vars.marketId, miku); 

    //     assertApproxEqAbs(debt , vars.amount1 - (bal - collateral.balanceOf(miku)),10 ); 
    //     assertApproxEqAbs(marketmanager.loggedCollaterals(vars.marketId), vars.amount1, 10); 

    //     //redeem 
    //     vars.dontAssert = true; 
    //     somelongsomeshort(vars, true); 

    //     // validators deny 
    //     doDeny(vars); 

    //     vm.prank(miku);
    //     marketmanager.redeemDeniedLeveredBond( vars.marketId); 
    //     assertApproxEqAbs(collateral.balanceOf(miku), bal, 10); 
    //     assertEq(marketmanager.getZCB(vars.marketId).balanceOf(address(marketmanager)) , 0); 

    // }

    // function testOptionsInstrument() public{
    //     testVars2 memory vars; 
    //     vars.utilizer = toku; 
    //     bool noprofit = false; 
    //     uint256 queriedPrice = 1e18 + 2e18; 


    //     somelongsomeshort(vars, true); 
    //     vm.prank(toku);
    //     collateral.transfer(address(otc),longCollateral ); 
    //     doApprove(vars.marketId, vars.vault_ad); 
    //     assertApproxEqAbs(collateral.balanceOf(address(otc)), shortCollateral + longCollateral,10); 

    //     // Warp to maturity 
    //     vm.warp(otc.maturityTime()+1); 

    //     if(noprofit){
    //         vm.prank(toku); 
    //         otc.profitForUtilizer(); 
    //         assertEq(otc.profit(), 0); 

    //         closeMarket(vars); 
    //         assertEq(marketmanager.redemption_prices(vars.marketId), precision); 

    //     }
    //     else{
    //         stdstore
    //         .target(address(otc))
    //         .sig(otc.testqueriedPrice.selector)
    //         .checked_write(queriedPrice); 
    //         vm.prank(toku); 
    //         otc.profitForUtilizer();
    //         vm.prank(toku); 
    //         otc.claim(); 

    //         vm.roll(block.number+1);

    //         address[] memory vals = controller.viewValidators(vars.marketId);
    //         for (uint256 i=0; i < vals.length; i++) {
    //             vm.prank(vals[i]);
    //             controller.validatorResolve(vars.marketId);
    //         }
    //         vm.startPrank(vals[0]); 
    //         controller.resolveMarket(vars.marketId); 
    //         vm.stopPrank(); 

    //         assert(marketmanager.redemption_prices(vars.marketId)< precision);
    //         assertEq(collateral.balanceOf(address(otc)), 0); 

    //         console.log('redemption', marketmanager.redemption_prices(vars.marketId)); 
    //     }

    // }
    // function testTopReputation() public{
        
    // }


    // function testLeveredBondMultiple() public{}
    // function testReputationQueueBlock() public{}


    // function testReputationBlockAddress() public {}

    // function testSellingFee() public {}

    // function testManagersCompensationManyCase() public{}

    // function testLpCompensationManyCase() public{}

    // function testAccountingInvariantsAndBalances() public{}

    // function testRedeemLeverageBuy() public {}

    // function testValidatorCompensation() public{}
    // function testClaimFunnelAndAllTradeFunctions() public {}

    // function testPrematureResolveRedeem() public{}

    // function testDeniedResolveRedeem() public {}// funds go back to vault

    // function testLiquidityProvision() public{}

    // function testManyInstrumentsAccountingCorrect() public{}

    // function testDenyRedeemValidator() public{}

    // function testManagersClosePositionWhileAssessment() public{}

    // function testRedeemDeniedMarketDifferentPriceZCB() public{}

    // function testCrazyAmountOfAssessmentTrading() public{}

    // function testCrazyAmountOfPostAssessmentTrading() public{}

    // function testPeopleCanTradeVibrantCDSMarket() public{}

    // function testLongShortPayoff() public{}

    // function testBudget() public{}

    // function testWithdrawRepayCredit() public {}

    // function testRestrictByProxyHandleDefault() public{}

    // function testRepayAndCloseMarket() public{} 
    

}

// contract UtilizerCycle is FullCycleTest{


// }
