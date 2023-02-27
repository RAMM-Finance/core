pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import  "../contracts/protocol/controller.sol";
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
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol"; 
import "../contracts/global/types.sol"; 

contract PoolInstrumentTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    function setUp() public {

        controller = new Controller(deployer); // zero addr for interep
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
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        doInvest(vault_ad,  toku, 1e18*10000); 


        leverageManager = new LeverageManager(address(controller), 
            address(marketmanager),address(reputationManager) );
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
    //     uint256 balbefore;
    //     uint256 ratebefore; 

    // }

    function testOneLongNoShortApproval() public{
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 

        vars.vault_ad = controller.getVaultfromId(vars.marketId); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
        assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna);

        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        assertApproxEqAbs(vars.amountIn, vars.amountToBuy, 10); 
        assertEq(marketmanager.loggedCollaterals(vars.marketId),vars.amountIn); 
        assert(controller.marketCondition(vars.marketId)); 
        assert(marketmanager.getPool(vars.marketId).getCurPrice() > vars.curPrice ); 

        // price needs to be at inceptionPrice
        vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
        assertApproxEqAbs(vars.curPrice, Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice, 100); 

        // let validator invest to vault and approve 
        vars.cbalnow = cBal(address(marketmanager.getPool(vars.marketId))); 
        vars.cbalnow2 = cBal(address(nftPool)); 
        doApprove(vars.marketId, vars.vault_ad);
        assertApproxEqAbs(vars.cbalnow + vars.valamountIn - cBal(address(marketmanager.getPool(vars.marketId))), 
            vars.valamountIn + vars.amountIn,10); 

        // see how much is supplied to instrument 
        console.log('?',
        marketmanager.getZCB(vars.marketId).totalSupply().mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.leverageFactor)
        .mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice), 
         marketmanager.loggedCollaterals(vars.marketId), cBal(address(nftPool)) - vars.cbalnow2);
        assertApproxEqAbs(cBal(address(nftPool)) - vars.cbalnow2, 
         marketmanager.getZCB(vars.marketId).totalSupply().mulWadDown(1e18+ Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.leverageFactor)
        .mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice), 100);

        
        // assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna) +
        // marketmanager.getZCB(vars.marketId).balanceOf(gatdang), marketmanager.getZCB(vars.marketId).totalSupply()); 

        // 
    }

    // function testPricing() public{
    //     testVars1 memory vars; 
    //     // 1. When approve, pricing should stay same
    //     // 2. When issue, pricing should stay same
    //     // 3. When begins, need to both start at inception, and when donated, pju must go up
    //     // 4. When time passes and no donations made, psu goes up pju goes down, 
    //     // 5. Works for all initial price <= inception price and 
    //     vars.marketId = controller.getMarketId(toku); 
    //     vars.vault_ad = controller.getVaultfromId(vars.marketId); //

    //     // After approval 
    //     vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
    //     // uint donateAmount = Vault(vars.vault_ad).UNDERLYING().balanceOf(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))) * 1/10; 
     

    //     // Let manager buy
    //     bytes memory data; 
    //     doApproveCol(address(marketmanager), jonna); 
    //     vm.prank(jonna); 
    //     (vars.amountIn, vars.amountOut) =
    //         marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

    //     controller.getVault(vars.marketId).poolZCBValue(vars.marketId); 
    //     (uint psu,  uint pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
    //     console.log('start pju', pju, psu); 
    //     doApprove(vars.marketId, vars.vault_ad);
    //     uint donateAmount = Vault(vars.vault_ad).UNDERLYING().balanceOf(address(Vault(vars.vault_ad).fetchInstrument(vars.marketId))) * 1/10; 


    //     (vars.psu, vars.pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
    //     assertEq(vars.psu, psu); 
    //     assertEq(vars.pju, pju); 
    //     assertApproxEqAbs(vars.psu, vars.pju, 10); 
    //     assertEq(vars.psu, controller.getVault(vars.marketId).fetchInstrumentData(vars.marketId).poolData.inceptionPrice); 
    //     donateToInstrument( vars.vault_ad, address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)) ,  donateAmount, );
    //     ( psu,   pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
    //     assertEq(psu, vars.psu); 
    //     // if(donateAmount>0)assert(vars.pju<pju);
    //     console.log('after donate pju', pju, psu); 



    //     //After some time.. when no donations were made 
    //     vm.warp(block.timestamp+31536000); 
    //     donateToInstrument( vars.vault_ad, address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)) ,  donateAmount);

    //     ( vars.psu,   vars.pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
    //     assert(vars.psu>controller.getVault(vars.marketId).fetchInstrumentData(vars.marketId).poolData.inceptionPrice ); 
    //     if(donateAmount==0) assert(pju> vars.pju); 
    //     console.log('after time pju', vars.pju, vars.psu); 


    //     // (vars.amountIn, vars.amountOut) =
    //     //     marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice + precision/2 , data); 
    //     // marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
    // }


    function testTwoEqualAmountTimeRedemption() public{

        // let jonna and sybal both buy and both redeem, equal amount 
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 

        doInvest(vars.vault_ad, gatdang, precision * 100000);
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 
        // let validator invest to vault and approve 
        doApprove(vars.marketId, vars.vault_ad);

        uint start = Vault(vars.vault_ad).UNDERLYING()
        .balanceOf(address(Vault(vars.vault_ad).Instruments(vars.marketId))); 
        // Let two managers buy at same time, should equal issued qty
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        uint256 issueQTY = marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
        doApproveCol(address(marketmanager), sybal); 
        vm.prank(sybal);
        uint256 issueQTY2 = marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
        assertEq(issueQTY2, issueQTY); 
        console.log('differences', issueQTY, issueQTY2); 

        vm.warp(block.timestamp+31536000); 
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(sybal); 
        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, issueQTY );
        vm.prank(sybal); 
        marketmanager.redeemPoolLongZCB(vars.marketId, issueQTY2 );

        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) - vars.cbalnow, 
            Vault(vars.vault_ad).UNDERLYING().balanceOf(sybal)- vars.cbalnow2, 100); 
        // instrument balance goes back to same ?? TODO 
        // assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING()
        // .balanceOf(address(Vault(vars.vault_ad).Instruments(vars.marketId))) , start, 1000); //TODO too big


    }


    function testAfterApprovalSupply() public{
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 
        doApprove(vars.marketId, vars.vault_ad);

        vm.prank(jonna); 
        marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 

        // how much is it supplied? 
    }

 

    function testPerpetualPayoff()public{
        // test whether manager will get correct redemption amount at any time 
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*4/2; 
        uint256 amount = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*4/2; 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 
        // let validator invest to vault and approve 
        doApprove(vars.marketId, vars.vault_ad);
        doInvest(vars.vault_ad, gatdang, precision * 100000);

        // Let manager buy
        doApproveCol(address(marketmanager), jonna); 

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vm.prank(jonna); 

        uint256 issueQTY = marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
        uint balStart = Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 

        // some time passes... supply to instrument, harvest

        vm.warp(block.timestamp+31536000); 
        address instrument = address(Vault(vars.vault_ad).fetchInstrument(vars.marketId)); 
        vm.startPrank(jonna); 

        // Vault(vars.vault_ad).UNDERLYING().transfer(instrument, amount*2); 

        vm.stopPrank(); 
        Vault(vars.vault_ad).harvest(vars.marketId); 

        // pju should be same even after redemption  
        uint balNow = Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna); 
        uint exchangeRate1 = Vault(vars.vault_ad).previewMint(1e18); 
        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, issueQTY );
        ( uint psu, uint pju, ) = controller.getVault(vars.marketId).poolZCBValue(vars.marketId);
        console.log('not0', pju, psu); 
        assert(pju>0); 
        console.log('??');
        assert(psu != pju); 
                console.log('???');

        assert(vars.cbalnow2 < vars.cbalnow); 
        assertEq(exchangeRate1, Vault(vars.vault_ad).previewMint(1e18));

        // get vault profit 
        // assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalnow,
        //  precision * amount - pju.mulWadDown(issueQTY) , 100); 
        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) - balNow, pju.mulWadDown(issueQTY), 1000);
        if(pju> psu) assert(Vault(vars.vault_ad).UNDERLYING().balanceOf(jonna) > balStart); 

     
    }

    //approve test
    function testVaultExchangeRateSameAfterApprove()public {
        // test whether manager will get correct redemption amount at any time 
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        uint256 amount = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        // Let manager buy
        uint exchangeRate = Vault(vars.vault_ad).previewMint(1e18); 
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        // let validator invest to vault and approve, 
        // After approval, should remain same exchange rate
        uint exchangeRate1 = Vault(vars.vault_ad).previewMint(1e18); 
        doApprove(vars.marketId, vars.vault_ad);
        uint exchangeRate2 = Vault(vars.vault_ad).previewMint(1e18);
        console.log('exchangeRates',exchangeRate, exchangeRate1, exchangeRate2 ); 
        assertEq(exchangeRate, exchangeRate1); 

        assertEq(exchangeRate1, exchangeRate2);

        // even after approval, issueing bonds will not change exchange rate
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        marketmanager.issuePoolBond(vars.marketId, vars.amountToBuy); 
        assertEq(exchangeRate1, Vault(vars.vault_ad).previewMint(1e18));

        // console.log('doing trade'); 
        // vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice();
        // (vars.amountIn, vars.amountOut) =
        //     marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice *11/10, data); 
        // console.log('amountIn, amountout', vars.amountIn, vars.amountOut); 

    }

    function testShortZCBPool() public returns(testVars1 memory){ 
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        uint256 amount = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 

        // Let manager buy
        uint exchangeRate = Vault(vars.vault_ad).previewMint(1e18); 
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        vars.amountToBuy=vars.amountToBuy*90/100; 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.shortBond(vars.marketId, vars.amountToBuy, 0 , data); 

        // redeem shortzcb
        return vars; 
    }

    function testShortZCBPoolRedeem() public{
        testVars1 memory vars = testShortZCBPool(); 
        vm.prank(jonna); 
        bytes memory data; 

        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), precision , data); 

        doApprove(vars.marketId, vars.vault_ad);
        vars.balbefore = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vm.prank(jonna); 
        (, uint256 seniorAmount, uint256 juniorAmount) = marketmanager.redeemPerpShortZCB(vars.marketId, vars.amountToBuy); 

        assertEq(Data.getMarket(vars.marketId).shortZCB.balanceOf(jonna), 0); 
        assertEq(vars.balbefore - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) ,seniorAmount+juniorAmount ); 
        console.log("??", vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 
        assertEq(Vault(vars.vault_ad).previewMint(1e18) - vars.ratebefore, 0); 

        console.log("amounts", seniorAmount, juniorAmount, vars.amountToBuy ); 


    }

    function testShortZCBPoolSellProfit() public{
        
        // profit made when instrument balance goes down 
        // instrument balance goes down when pool zcb value pju goes down
        // pju goes down when time passes and no senior returns, or time
        // passes and instrument realizes a loss 

    }

    // // Redeem test 
    // function testVaultExchangeRateSameAfterRedemption() public{}
    // function testprofitSplit() public{}//profit split between vault and 
    // function testEveryoneRedeem() public{}
    // function testBorrowAndRepay() public{}

    // function testPricingWithOracle() public{}
    // function testLendingPool() public{}
    // function testMultipleEqualAmountTimeRedemption()public{}

    // // vault deposit goes back to same? 
    // function testSupplyWithdraw() public{

    // }

    // function testInstrumentBalance() public{}

    // function testVaultProfit() public{}//exchangerate should go up with instrument profit 

    // function testPricingIsSupplyAgnostic() public{}

    /// @notice tests asset oracle 
    /// checks: is last queried when no change in time
    /// checks: is current when dif in time > timewindow 
    /// checks: is between last and current if less than timewindow 
    function testAssetOracle(
        uint32 rate1, 
        uint32 rate2, 
        uint32 rate3, 
        uint32 rate4, 
        uint32 warp1, 
        uint32 warp2
        ) public {
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 
        uint256 timewindow = Data.TIME_WINDOW(); 

        uint256 rate1 = constrictToRange(fuzzput(rate1, 1e15), 3e17, 20e17); 
        uint256 rate2 = constrictToRange(fuzzput(rate2, 1e15), 3e17, 20e17); 
        uint256 rate3 = constrictToRange(fuzzput(rate3, 1e15), 3e17, 20e17); 
        uint256 rate4 = constrictToRange(fuzzput(rate4, 1e15), 3e17, 20e17); 

        uint256 warp1 = constrictToRange(fuzzput(warp1, 1),1, timewindow/1e18-1);//timewindow/1e18/2;
        uint256 warp2 = constrictToRange(fuzzput(warp2, 1),timewindow/1e18, timewindow*5/1e18);//timewindow*2/1e18;  

        console.log('params', rate1, rate2, rate3); 
        console.log('params2', rate4, warp1, warp2); 
        assert(rate1>=3e17 ); 
        assert(warp1>0); 

        Data.storeExchangeRateOracle(vars.marketId, rate1); 
        uint oracleRate = Data.queryExchangeRateOracle(vars.marketId); 
        console.log('oracle rate', oracleRate, rate1); 
        assertEq(oracleRate, rate1); 

        Data.storeExchangeRateOracle(vars.marketId,rate2 ); 

        // some time pass
        vm.warp(block.timestamp+warp1); 
        oracleRate = Data.queryExchangeRateOracle(vars.marketId);
        console.log('oracle rate', oracleRate, rate2); 

        if(rate2> rate1) assert(rate2 > oracleRate); 
        else if(rate2< rate1) assert(rate2 < oracleRate); 
        
        vm.warp(block.timestamp + warp2); 

        oracleRate = Data.queryExchangeRateOracle(vars.marketId); 
        assertEq(rate2, oracleRate); 
        console.log('oracle rate', oracleRate, rate2); 

        Data.storeExchangeRateOracle(vars.marketId,rate3 ); 
        vm.warp(block.timestamp + warp2); 
        oracleRate = Data.queryExchangeRateOracle(vars.marketId); 
        assertEq(rate3, oracleRate); 
        console.log('oracle rate', oracleRate, rate3); 

        Data.storeExchangeRateOracle(vars.marketId,rate4 ); 
        vm.warp(block.timestamp + warp1); 
        oracleRate = Data.queryExchangeRateOracle(vars.marketId); 
        if(rate4> rate3) assert(rate4 > oracleRate); 
        else if(rate3>rate4) assert(oracleRate > rate4) ;
        console.log('oracle rate', oracleRate, rate4); 
    }



        // uint newURate = 5e17; 
        // uint newURate2 = 95e16; 
        // uint time1 = 100; 
        // uint time2 = 50; 

        // uint incrementRate = 1e16; 
        // uint urateUpper = 9e17; 
        // uint urateLower = 5e17;
        // uint prevAccrueTime = block.timestamp ; 
        // uint prevURate = 0; 
        // uint maxBorrowable = 1e18; 

    /// @notice tests whether max borrow amount changes when manager
    /// check: whether loan to value is incrementing/decrementing correctly
    /// check: 
    function testMaxBorrowChange(
        uint newURate, 
        uint newURate2, 
        uint time1, 
        uint time2, 

        uint incrementRate, 
        uint urateUpper,
        uint urateLower,
        uint prevAccrueTime,
        uint prevURate, 
        uint maxBorrowable

        ) public{
        testVars1 memory vars; 
        vars.marketId = controller.getMarketId(toku); 
        console.log('wtf', newURate, newURate2, time1); 

        vm.assume(urateLower<=9e17);
        vm.assume(urateUpper >= urateLower + 1e17); 
        vm.assume(newURate>=3e17); 
        // vm.assume(time1<= 100); 
        // vm.assume(time2<= 100); 

        uint newURate = constrictToRange(newURate, 3e17, 1e18); 
        uint newURate2 = constrictToRange(newURate2, 3e17, 1e18); 
        uint time1 = constrictToRange(time1, 0, 100); 
        uint time2 = constrictToRange(time2, 0, 100); 

        uint incrementRate = constrictToRange(incrementRate, 1e8, 1e16);  
        uint urateUpper = constrictToRange(urateUpper, 7e17,95e16); 
        uint urateLower = constrictToRange(urateLower, 3e17, 6e17);
        uint prevAccrueTime = block.timestamp ; 
        uint prevURate = 0; 
        uint maxBorrowable = constrictToRange(maxBorrowable, 0, 100000e18); 

        console.log('params', newURate, newURate2, time1); 
        console.log('params2', time2, incrementRate, urateUpper); 
        console.log('params3', urateLower, prevAccrueTime, prevURate); 
        console.log('param4', maxBorrowable); 
        assert(newURate>=3e17); 
        Data.setPoolPricingParams(vars.marketId, PoolPricingParam(
            incrementRate, urateUpper, urateLower, prevAccrueTime, prevURate, maxBorrowable
            )
        ); 

        // refresh with initial urate, since no time pass maxborrowable should not change
        // When I am refreshing, I am using the previous refreshed urate accrued over the timesteps
        uint ltv = Data.refreshAndGetNewLTV(vars.marketId, newURate); 
        assertEq(maxBorrowable, ltv); 

        // refresh with some time pass
        vm.warp(block.timestamp + time1); 
        ltv = Data.refreshAndGetNewLTV(vars.marketId, newURate2); 
        if(newURate < urateLower) assertApproxEqAbs(ltv, maxBorrowable.mulWadDown((1e18+incrementRate).rpow(time1, 1e18)), 50); 
        else if(newURate > urateUpper) assertApproxEqAbs(ltv, 
            maxBorrowable.mulWadDown((1e18-incrementRate).rpow(time1, 1e18)), 50); 
        else assertApproxEqAbs(ltv, maxBorrowable, 10); 
        maxBorrowable = ltv; 

        vm.warp(block.timestamp + time2); 
        ltv = Data.refreshAndGetNewLTV(vars.marketId, newURate2);
        if(newURate2< urateLower) 
            assertApproxEqAbs(ltv, maxBorrowable.mulWadDown((1e18+incrementRate).rpow(time2, 1e18)), 50);
        else if(newURate2 > urateUpper) assertApproxEqAbs(ltv, 
            maxBorrowable.mulWadDown((1e18-incrementRate).rpow(time2, 1e18)), 50); 
        else assertApproxEqAbs(ltv, maxBorrowable, 10); 

    }

}

