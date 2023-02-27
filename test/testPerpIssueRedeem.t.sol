pragma solidity ^0.8.4;


import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
// import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {CustomTestBase} from "./testbase.sol"; 
import "../contracts/global/types.sol"; 

contract IssueRedeemTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

  
    function setUp() public {

        deploySetUps(); 

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

        // initiateLendingPool(vault_ad); 
        doInvest(vault_ad,  toku, 1e18*100000); 
    }

    /// @notice checks if issueing supplies to instruments, or withdraws from instruments
    /// by correct amount 
    function testUnitIssueFuzz(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 amountToIssue
        ) public returns(testVars1 memory){


        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e14), vars.saleAmount, vars.saleAmount*5 ); 
        uint amountToIssue = constrictToRange(fuzzput(amountToIssue, 1e14), 1e12, vars.saleAmount*5 ); 

        vm.assume(amountToBuy <= marketmanager.getTraderBudget(vars.marketId, jonna)); 
        vm.assume(amountToIssue <= marketmanager.getTraderBudget(vars.marketId, jonna)); 

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        doApproveFromStart(vars.marketId, amountToBuy); 

        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);  
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        uint zcbbalbefore = Data.getMarket(vars.marketId).longZCB.balanceOf(jonna);
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;

        vm.prank(jonna);
        marketmanager.issuePoolBond(vars.marketId, amountToIssue);

        // check vault exchange rate same
        assertEq( vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 

        // check instrument exchange rate same 
        assertEq(vars.rateBefore, ERC4626(instrument).previewMint(1e18)); 

        // check vault bal decrease is function of issueAmount and lev factor 
        console.log('senioramounthere', vars.pju, vars.psu, 
            (amountToIssue.divWadUp(vars.pju)).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu)); 
        assertApproxEqAbs(vars.cbalnow - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad), 
            (amountToIssue.divWadUp(vars.pju)).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu), 
            100); 

        // check vault correctly supplied to instrument; 
        // vault bal decrease + issueAmount = instrument increase
        assertApproxEqAbs(
            vars.cbalnow - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) 
                + amountToIssue,  
            Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument)
              - vars.cbalnow2, 
            100
        ) ; 

        // Check correct amount minted 
        assertEq(Data.getMarket(vars.marketId).longZCB.balanceOf(jonna) - zcbbalbefore, 
            amountToIssue.divWadUp(vars.pju)); 

        // check psu pju same
        (uint psu, uint pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        assertApproxEqAbs(pju, vars.pju, 10); 
        assertEq(psu, vars.psu); 

        vars.amountToIssue = amountToIssue; 
        return vars; 
    }

    /// @notice trader issues and redeems certain amount 
    /// checks if correct amount is withdrawn 
    function testUnitRedeemFuzz(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 amountToIssue, 
        uint32 amountToRedeem
        ) public {

        testVars1 memory vars = testUnitIssueFuzz(
             multiplier, 

             saleAmount, 
             initPrice,
             promisedReturn, 
             inceptionPrice, 
             leverageFactor, 

             amountToBuy, 
             amountToIssue
            ); 

        uint amountToRedeem = constrictToRange(fuzzput(amountToBuy, 1e14), 0, vars.amountToIssue.divWadUp(vars.pju)); 

        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);  
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        uint zcbbalbefore = Data.getMarket(vars.marketId).longZCB.balanceOf(jonna);
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;

        vm.prank(jonna); 
        (vars.collateral_redeem_amount, vars.seniorAmount) =
            marketmanager.redeemPoolLongZCB(vars.marketId, amountToRedeem);

        // check vault exchange rate same
        // assertEq( vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 

        // check instrument exchange rate same 
        assertEq(vars.rateBefore, ERC4626(instrument).previewMint(1e18)); 

        // check vault bal increase is function of issueAmount and lev factor 
        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalnow, 
            (amountToRedeem).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu), 
            100); 

        // check vault correctly withdrawn from instrument; 
        // vault bal increase + redeemAmount = instrument decrease 
        assertApproxEqAbs(
            Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) -vars.cbalnow 
                + vars.collateral_redeem_amount,  
            vars.cbalnow2 - Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), 
            101
        ) ; 

    }


    /// @notice x people issues, and they all redeem at a later date with different 
    /// times and pjus, 
    function testEveryoneCanRedeem(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 amountToIssue, 
        uint32 amountToIssue2, 
        uint32 amountToIssue3, 
        uint32 amountToIssue4

        // uint32 time1, 
        // uint32 donateAmount1 
        ) public{
        // x people issues, and everyone will be able to redeem, draining all funds 

        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        vars.budget = marketmanager.getTraderBudget(vars.marketId, jonna); 
        vm.assume(vars.saleAmount <= vars.budget); 

        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e14), vars.saleAmount, vars.budget ); 
        vars.amount1 = constrictToRange(fuzzput(amountToIssue, 1e14), 1e12, vars.budget ); 
        vars.amount2 = constrictToRange(fuzzput(amountToIssue2, 1e14), 1e12, vars.budget); 
        vars.amount3 = constrictToRange(fuzzput(amountToIssue3, 1e14), 1e12, vars.budget); 
        vars.amount4 = constrictToRange(fuzzput(amountToIssue4, 1e14), 1e12, vars.budget ); 

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.amountOut = doApproveFromStart(vars.marketId, amountToBuy); 

        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        vars.totalSupply = ((vars.amount1+vars.amount2+vars.amount3+vars.amount4)
            .divWadUp(vars.pju)).mulWadDown(1e18 + vars.leverageFactor); 

        // uint donateAmount1 = constrictToRange(fuzzput(donateAmount1, 1e14), 0, 
        //     vars.totalSupply.mulWadDown(vars.pju)
        //     ); 


        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);  
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        vars.amountIn = ERC4626(instrument).totalSupply(); 
        doApproveCol(address(marketmanager), jonna); 
        doApproveCol(address(marketmanager), toku); 
        doApproveCol(address(marketmanager), jott); 
        doApproveCol(address(marketmanager), gatdang);

        vm.prank(jonna);
        vars.amount1 = marketmanager.issuePoolBond(vars.marketId, vars.amount1);
        vm.prank(toku); 
        vars.amount2 = marketmanager.issuePoolBond(vars.marketId, vars.amount2);
        vm.prank(jott); 
        vars.amount3 = marketmanager.issuePoolBond(vars.marketId, vars.amount3);
        vm.prank(gatdang); 
        vars.amount4 = marketmanager.issuePoolBond(vars.marketId, vars.amount4);

        // Total Supply and should roughly equal instrument shares minted
        // console.log('supply', vars.totalSupply.mulWadDown(vars.inceptionPrice), ERC4626(instrument).totalSupply()-vars.amountIn); 
        assertEq(vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 
        assertApproxEqBasis(vars.totalSupply.mulWadDown(vars.inceptionPrice), 
            ERC4626(instrument).totalSupply() - vars.amountIn, 1); 

        // Different time and pju/psu 
        // vm.warp(block.timestamp +3153600 ); 
        // poolInstrument.modifyTotalAsset(isGain, donateAmount1);


        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amount1);
        vm.prank(toku); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amount2);
        vm.prank(jott); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amount3);
        vm.prank(gatdang); 
        marketmanager.redeemPoolLongZCB(vars.marketId, vars.amount4);

        // Instrument shares should come back 
        assertApproxEqAbs(ERC4626(instrument).totalSupply(), vars.amountIn , 10001); 

        // Should increase by some number if time pass
        assertApproxEqAbs(vars.cbalnow, Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad), 99); 
        assertApproxEqAbs(vars.cbalnow2, Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), 10000); 

        //redeeming when no instrument rate change don't change vault rate
        //redeeming when no psu change don't change vault rate
        assertApproxEqAbs(vars.rateBefore, ERC4626(instrument).previewMint(1e18), 101); 
        // assertApproxEqAbs(vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18), 102); 

        // redeem the amount bought 
        vm.prank(jonna); 
        (vars.collateral_redeem_amount , vars.seniorAmount) = marketmanager.redeemPoolLongZCB(vars.marketId,vars.amountOut ); 

        // assert longzcb supply goes to 0 
        console.log('totalsupply', Data.getMarket(vars.marketId).longZCB.totalSupply(), amountToBuy); 
        assertEq(Data.getMarket(vars.marketId).longZCB.totalSupply(), 0); 

        // assert instrument balance goes to 0 
        console.log('instrumentbalacne',vars.cbalnow2, 
         Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), amountToBuy); 
        console.log('management fee', Data.getMarket(vars.marketId).bondPool.managementFee()); 

        if(Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument)>=1e12)
        assertApproxEqBasis(Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), Data.getMarket(vars.marketId).bondPool.managementFee(), 1 ); 

        // assert collateral redeem amount is less than pju * amounttobuy
        console.log('??', vars.collateral_redeem_amount,vars.pju.mulWadDown(vars.amountOut) ); 
        assert(vars.collateral_redeem_amount <= vars.pju.mulWadDown(vars.amountOut)); 


        Vault(vars.vault_ad).withdrawAllFromInstrument(vars.marketId); 

        // assert vault rate same(since no time passed) 
        assertApproxEqAbs(vars.rateBefore, ERC4626(instrument).previewMint(1e18), 108); 
        // assertApproxEqAbs(vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18), 109); 

 

        // total longzcb supply 
        // (vars.amount1+vars.amount2+vars.amount3+vars.amount4 + vars.amountOut ).mulWadDown(vars.pju)
        // (vars.amount1+ v)
    }

    /// @notice check if after redeeming exchange rate changes 
    //every longzcb can be redeemed
    //redeeming when  instrument rate change  change vault rate
    //redeeming when psu change change vault rate
    //depositing don't change vault rate
    //correct amount of rate changes when harvesting
    //when should vault exchange rate be same? 
    function testRedeemVaultExchangeRateProfits(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 time, 
        uint32 donateAmount ,
        uint32 amountToBuy
        ) public{

        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        );         

        // vm.assume(saleAmount>=1e13); 
        uint donateAmount = constrictToRange(fuzzput(donateAmount, 1e16), 
            0, vars.saleAmount*100
            );         
        vars.budget = marketmanager.getTraderBudget(vars.marketId, jonna); 
        vm.assume(vars.saleAmount <= vars.budget); 
        vm.assume(Data.getMarket(vars.marketId).bondPool.managementFee()> vars.saleAmount/100); 
        vars.cbalnow3 = Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) ; 

        vm.assume(amountToBuy<= vars.cbalnow3); 
        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e14), vars.saleAmount, vars.budget ); 
        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        console.log('saleamount', vars.saleAmount, amountToBuy);

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        console.log('psu', vars.psu, vars.inceptionPrice); 

        assertEq(vars.psu, vars.inceptionPrice); 
        console.log('jonna balance', Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna));

        vars.amountOut = doApproveFromStart(vars.marketId, amountToBuy); 
        vars.amount1 = Data.getMarket(vars.marketId).longZCB.totalSupply()
            .mulWadDown(vars.leverageFactor+ 1e18)
            .mulWadDown(vars.inceptionPrice)
            .mulWadDown(vars.rateBefore); 

        // supplied amount = Q_l * (L+1) prod(R_ri) * inceptionprice 
        assertApproxEqBasis(
            vars.amount1, 
            Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), 1
        ); 
        console.log('supplied/balance', vars.amount1,Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument) ); 

        // pju * amount - management fee is amount u paid 
        assertApproxEqBasis(vars.pju.mulWadDown(vars.amountOut)
         - Data.getMarket(vars.marketId).bondPool.managementFee(), amountToBuy, 1); 
        console.log('jonna balance', Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna), amountToBuy);



        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna), vars.cbalnow3-amountToBuy, 98 ); 

        vm.warp(block.timestamp + time); 
        poolInstrument.modifyTotalAsset(true, donateAmount);
        vm.startPrank(toku); 
        Vault(vars.vault_ad).UNDERLYING().transfer(address(poolInstrument), donateAmount); 
        vm.stopPrank(); 
        (vars.psu2, vars.pju2, ) = Data.viewCurrentPricing(vars.marketId);

        vars.pjuDiscounted = vars.pju2 >= Data.getMarket(vars.marketId).bondPool.managementFee().divWadDown(Data.getMarket(vars.marketId).bondPool.saleAmountQty())
                                     ? vars.pju - Data.getMarket(vars.marketId).bondPool.managementFee().divWadDown(Data.getMarket(vars.marketId).bondPool.saleAmountQty())
                                     : 0;  

        console.log('pju, pju2, pjuDiscounted', vars.pju, vars.pju2, vars.pjuDiscounted); 
        // harvesting should not change pju o.                                                                                                          
        vars.amount2 = vars.psu.mulWadDown(
            Data.getMarket(vars.marketId).longZCB.totalSupply().mulWadDown(vars.leverageFactor)
            ); 
        if(vars.amount2 >= vars.amount1 - Data.getMarket(vars.marketId).bondPool.managementFee() + donateAmount){
        vars.amount3 = vars.amount2 - vars.amount1 - Data.getMarket(vars.marketId).bondPool.managementFee() + donateAmount; 
        console.log('pju 0 and senior chiming into management fee', vars.amount3, Data.getMarket(vars.marketId).bondPool.managementFee()); 
        }
        // redeem all the stuff bought, automatically harvests loss 
        vm.prank(jonna);  
        (vars.collateral_redeem_amount, vars.seniorAmount) 
            = marketmanager.redeemPoolLongZCB(vars.marketId, vars.amountOut); 
        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna), vars.cbalnow3-amountToBuy+vars.collateral_redeem_amount, 99 ); 
        console.log('jonna balance', Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna), vars.collateral_redeem_amount);

        console.log('donate,time', donateAmount, time); 
        if (vars.pjuDiscounted >0)assertApproxEqBasis(
            vars.amount1 - Data.getMarket(vars.marketId).bondPool.managementFee()+ donateAmount, 
            vars.collateral_redeem_amount+ vars.seniorAmount, 1
        );
        // withdrawn capital to vault only is larger than supplied - management fee + donateamount 
        console.log('pju, pju2', vars.pju, vars.pju2); 

        // first make sure instrument is withdrawn, supplied capital + donate amount == withdrawn capital + management fee(which is sent later)
        if (vars.pjuDiscounted >0)assertApproxEqAbs(
            Data.getMarket(vars.marketId).bondPool.managementFee(), 
            Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), 
            10000); 
        // less than management fee in the instrument 
        console.log('supplied,donated,withdrawn', vars.amountOut.mulWadDown(1e18 + vars.leverageFactor).mulWadDown(vars.inceptionPrice), 
            donateAmount, vars.collateral_redeem_amount + vars.seniorAmount) ; 

        // withdrawn capital + management fee= supplied capital + donateamount 

        if (vars.pjuDiscounted >0)assertApproxEqBasis(vars.collateral_redeem_amount + vars.seniorAmount + Data.getMarket(vars.marketId).bondPool.managementFee(), 
            vars.amountOut.mulWadDown(1e18 + vars.leverageFactor).mulWadDown(vars.inceptionPrice) +donateAmount, 1 ); 

        // make sure jonna has correct profits from difference in pju 
        // do for negative profit too 
        console.log('jonna balance', Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna), vars.cbalnow3);


        if(vars.pju2>vars.pju) console.log('pjus', donateAmount,  (vars.pju2-vars.pju ).mulWadDown(vars.amountOut));
        console.log('in and out', amountToBuy, vars.collateral_redeem_amount ); 

        // difference in in and out shoould equal change in price time longzcb amount 
        if(vars.pju2>vars.pju) {
            if (vars.pjuDiscounted >0)assertApproxEqBasis(vars.collateral_redeem_amount - amountToBuy, 
            (vars.pju2-vars.pju ).mulWadDown(vars.amountOut), 1); 
            console.log('pju dif times amount', (vars.pju2-vars.pju ).mulWadDown(vars.amountOut)); 
        }else if(vars.pju2==vars.pju){
            assertApproxEqAbs(amountToBuy,vars.collateral_redeem_amount, 1000 ); 
        }
        else if(vars.pju2+10000<vars.pju){
            if (vars.pjuDiscounted >0)assertApproxEqBasis(amountToBuy - vars.collateral_redeem_amount ,
             (vars.pju-vars.pju2 ).mulWadDown(vars.amountOut), 1);
            console.log('pju dif2 times amount', (vars.pju-vars.pju2 ).mulWadDown(vars.amountOut)); 
        }

        // difference in trader balance should roughly equal diff in pju price times longzcb amount 
        if(donateAmount>=1e12 && vars.pju2>vars.pju) 
            assertApproxEqBasis(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) -  
            vars.cbalnow3, (vars.pju2-vars.pju ).mulWadDown(vars.amountOut) , 1); 

        if(vars.pju2>vars.pju) console.log('bal dif', Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) -  
            vars.cbalnow3); 
        // make sure psu * senior + pju * junior is withdrawn total capital, which is
        // supplied capital + donate apunt 
        console.log('senior + junior', vars.psu2.mulWadDown(vars.amountOut.mulWadDown(vars.leverageFactor)) 
            + vars.pju2.mulWadDown(vars.amountOut));
        console.log('pricing here and there', vars.psu2.mulWadDown(vars.amountOut.mulWadDown(vars.leverageFactor))
            , vars.seniorAmount, vars.collateral_redeem_amount );  
        if (vars.pjuDiscounted >0)assertApproxEqBasis(vars.collateral_redeem_amount + vars.seniorAmount 
            + Data.getMarket(vars.marketId).bondPool.managementFee(),
         vars.psu2.mulWadDown(vars.amountOut.mulWadDown(vars.leverageFactor)) 
            + vars.pju2.mulWadDown(vars.amountOut), 1); 

        // when is vault rate greater than the previous? 
        // if time passed and accumulated psu is greater than 

        // vault balance difference is psu difference * senior shares  
        // and rate reflects this 
        Vault(vars.vault_ad).withdrawAllFromInstrument(vars.marketId); 

        console.log('vault bals', Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad), vars.cbalnow);
        console.log('rate changes',Vault(vars.vault_ad).previewMint(1e18), vars.ratebefore );  
        console.log('psus', vars.psu2, vars.psu); 

        // difference in vault balance should equal difference in 
         if(donateAmount>=1e14 && Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) > vars.cbalnow + 1e12 ) {
         if (vars.pjuDiscounted >0)assertApproxEqBasis(Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalnow, 

         (vars.psu2 - vars.psu).mulWadDown(vars.amountOut.mulWadDown(vars.leverageFactor)), 1);
         console.log('psu difference', (vars.psu2 - vars.psu).mulWadDown(vars.amountOut.mulWadDown(vars.leverageFactor))); 

         assertApproxEqBasis( (Vault(vars.vault_ad).previewMint(1e18) - vars.ratebefore).mulWadDown(
            vars.cbalnow
            ),Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalnow ,105); 

        }

    }

    // function testRedeemVaultExchangeRateLoss() public {}

    // function test1ShareEqualsIPTimesTrancheSupply() public {}

    // function testRedeemVaultExchangeRate() public{}


    // ///  @notice check if can be continuously supplied and withdrawn by x people 
    // function testIssueRedeemOver() public{

    // }

        // redeem cases: x people issue and redeem, 

  

  

}


