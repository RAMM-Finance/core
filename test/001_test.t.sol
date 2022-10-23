pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "src/protocol/controller.sol";
import {MarketManager} from "src/protocol/marketmanager.sol";
import {ReputationNFT} from "src/protocol/reputationtoken.sol";
import {Cash} from "src/libraries/Cash.sol";
import {CreditLine, MockBorrowerContract} from "src/vaults/instrument.sol";
import {SyntheticZCBPoolFactory} from "src/bonds/synthetic.sol"; 
import {LinearCurve} from "src/bonds/GBC.sol"; 
import {FixedPointMath} from "src/bonds/libraries.sol"; 

contract FullCycleTest is Test {
    using FixedPointMath for uint256; 

    Controller controller;
    MarketManager marketmanager;
    Cash collateral;
    VaultFactory vaultFactory;
    ReputationNFT repToken;
    SyntheticZCBPoolFactory poolFactory;
    
    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    uint256 unit = 10**18; 
    uint256 constant precision = 1e18;
    address vault_ad; 

    // Participants 
    address jonna;
    address jott; 
    address gatdang;
    address sybal; 
    address chris; 
    address miku;
    address tyson; 
    address yoku;
    address toku; 
    address goku; 

    // Varaibles that sould be tinkered
    uint256 principal = 1000 * precision;
    uint256 interest = 100*precision; 
    uint256 duration = 1*precision; 
    uint256 faceValue = 1100*precision; 
    MockBorrowerContract borrowerContract = new MockBorrowerContract();
    CreditLine instrument;
    uint256 N = 1;
    uint256 sigma = precision/20; //5%
    uint256 alpha = precision*4/10; 
    uint256 omega = precision*2/10;
    uint256 delta = precision*2/10; 
    uint256 r = 10;
    uint256 s = precision*2;
    uint256 steak = precision;

    function setUp() public {

        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        repToken = new ReputationNFT(address(controller));
        collateral = new Cash("n","n",18);
  
        bytes32  data;
        marketmanager = new MarketManager(
            deployer,
            address(repToken),
            address(controller), 
            address(0),data, uint64(0)
        );
        poolFactory = new SyntheticZCBPoolFactory(address(controller)); 

        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setReputationNFT(address(repToken));
        controller.setPoolFactory(address(poolFactory)); 

        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak)
        ); //vaultId = 1; 
        vault_ad = controller.getVaultfromId(1); 

        jonna = address(0xbabe);
        vm.label(jonna, "jonna"); // manager1
        jott = address(0xbabe2); 
        vm.label(jott, "jott"); // utilizer 
        gatdang = address(0xbabe3); 
        vm.label(gatdang, "gatdang"); // validator
        sybal = address(0xbabe4);
        vm.label(sybal, "sybal");//manager2
        chris=address(0xbabe5);
        vm.label(chris, "chris");//manager3
        miku = address(0xbabe6);
        vm.label(miku, "miku"); //manager4
        goku = address(0xbabe7); 
        vm.label(goku, "goku"); //LP1 

        vm.prank(jonna); 
        collateral.faucet(100000*precision);
        vm.prank(jott); 
        collateral.faucet(100000*precision);
        vm.prank(gatdang); 
        collateral.faucet(100000*precision); 
        vm.prank(sybal); 
        collateral.faucet(100000*precision); 
        vm.prank(chris); 
        collateral.faucet(100000*precision); 
        vm.prank(miku); 
        collateral.faucet(100000*precision); 
        vm.prank(goku);
        collateral.faucet(100000*precision); 

        repToken.mint(jott); 
        repToken.mint(jonna);
        repToken.mint(gatdang); 
        repToken.mint(chris); 
        repToken.mint(miku); 
        repToken.mint(sybal); 

        vm.prank(jott);
        controller.testVerifyAddress();
        vm.prank(jonna);
        controller.testVerifyAddress();
        vm.prank(gatdang); 
        controller.testVerifyAddress(); 
        vm.prank(chris); 
        controller.testVerifyAddress(); 
        vm.prank(miku); 
        controller.testVerifyAddress(); 
        vm.prank(sybal); 
        controller.testVerifyAddress(); 

        instrument = new CreditLine(
            vault_ad, 
            jott, principal, interest, duration, faceValue, 
            address(collateral ), address(collateral), principal, 2
            ); 
        instrument.setUtilizer(jott); 


        initiateMarket(); 
    }

    function initiateMarket() public {
        Vault.InstrumentData memory data;

        data.trusted = false; 
        data.balance = 0;
        data.faceValue = faceValue;
        data.marketId = 0; 
        data.principal = principal;
        data.expectedYield = interest;
        data.duration = duration;
        data.description = "test";
        data.Instrument_address = address(instrument);
        data.instrument_type = Vault.InstrumentType.CreditLine;
        data.maturityDate = 10; 

        controller.initiateMarket(jott, data, 1); 

    }

    function doApproveCol(address _who, address _by) public{
        vm.prank(_by); 
        collateral.approve(_who, type(uint256).max); 
    }
    function doInvest(address vault, address _by, uint256 amount) public{
        vm.prank(_by); 
        Vault(vault).deposit(amount, _by); 
    }
    function cBal(address _who) public returns(uint256) {
        return collateral.balanceOf(_who); 
    }

    function testFailApproval() public{
        address proxy =  instrument.getProxy(); 
        borrowerContract.changeOwner(proxy); 
        assertEq(borrowerContract.owner(), proxy); 
        uint256 marketId = controller.getMarketId(jott); 

        controller.approveMarket(marketId);

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
    }

    function testOneLongNoShortApproval() public{
        testVars1 memory vars; 

        address proxy =  instrument.getProxy(); 
        borrowerContract.changeOwner(proxy); 
        borrowerContract.autoDelegate(proxy);
        assertEq(borrowerContract.owner(), proxy); 

        vars.marketId = controller.getMarketId(jott); 

        vars.vault_ad = controller.getVaultfromId(1); //
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal/2; 
        vars.curPrice = marketmanager.getPool(vars.marketId).pool().getCurPrice(); 
        assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 

        // Let manager buy
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice + precision/10 , data); 
        assertApproxEqAbs(vars.amountIn, vars.amountToBuy, 10); 
        assertEq(marketmanager.loggedCollaterals(vars.marketId),vars.amountIn); 
        assert(marketmanager.marketCondition(vars.marketId)); 
        assert(marketmanager.getPool(vars.marketId).pool().getCurPrice() > vars.curPrice ); 

        // let validator invest to vault and approve 
        vars.cbalnow = cBal(address(marketmanager.getPool(vars.marketId))); 
        doApproveCol(vars.vault_ad, gatdang); 
        doInvest(vars.vault_ad, gatdang, precision * 1000);
        doApproveCol(address(marketmanager), gatdang); 
        instrument.setValidator( gatdang);  
        vm.prank(gatdang); 
        vars.valamountIn = marketmanager.validatorApprove(vars.marketId); 
        assertApproxEqAbs(vars.cbalnow + vars.valamountIn - cBal(address(marketmanager.getPool(vars.marketId))), 
            vars.valamountIn + vars.amountIn,10); 

       //how much bond are issued? 
        assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna) +
        marketmanager.getZCB(vars.marketId).balanceOf(gatdang), marketmanager.getZCB(vars.marketId).totalSupply()); 

    }

    struct testVars2{
        uint256 marketId;
        address vault_ad; 
        uint curPrice; 
        uint principal; 
        uint amount1; 
        uint amount2; 
        uint amount3; 
        uint amount4; 

        uint amountIn;
        uint amountOut; 
        uint s_amountIn; 
        uint s_amountOut; 

        uint vaultBal; 
        uint cbalbefore; 
        uint vaultBalBeforeRedeem; 
        uint sumofcollateral; 
    }

    function somelongsomeshort(testVars2 memory vars, bool finish) public {

        address proxy =  instrument.getProxy(); 
        borrowerContract.changeOwner(proxy); 
        borrowerContract.autoDelegate(proxy);
        assertEq(borrowerContract.owner(), proxy); 

        vars.marketId = controller.getMarketId(jott); 

        vars.vault_ad = controller.getVaultfromId(1); //
        vars.curPrice = marketmanager.getPool(vars.marketId).pool().getCurPrice(); 
        assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 
        vars.principal = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal; 

        // try a bunch of numbers 
        vars.amount1 = vars.principal*11/100; 
        vars.amount2 = vars.principal*7/100; 
        vars.amount3 = vars.principal*11/100; //shorting 
        vars.amount4 = vars.principal*12/100; 
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
            marketmanager.shortBond(vars.marketId, vars.amount3, vars.curPrice + precision/10 , data); 

        doApproveCol(address(marketmanager), miku); 
        vm.prank(miku); 
        (vars.amountIn, vars.amountOut) =
            marketmanager.buyBond(vars.marketId, -int256(vars.amount4), vars.curPrice + precision/10 , data); 

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
            + marketmanager.getPool(vars.marketId).b() , marketmanager.getPool(vars.marketId).pool().getCurPrice(), 100000); 
        assert(!marketmanager.marketCondition(vars.marketId)); 

        // now buy 
        if (finish){
            doApproveCol(address(marketmanager), jonna); 
            vm.prank(jonna); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount3), vars.curPrice + precision/10 , data); 

            doApproveCol(address(marketmanager), sybal); 
            vm.prank(sybal); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount4), vars.curPrice + precision/10 , data); 
            vm.prank(sybal); 
            (vars.amountIn, vars.amountOut) =
                marketmanager.buyBond(vars.marketId, -int256(vars.amount4), vars.curPrice + precision/10 , data); 

        }

        console.log('collat', marketmanager.loggedCollaterals(vars.marketId), marketmanager.marketCondition(vars.marketId));
    }

    function doApprove(testVars2 memory vars) public{
        // validators invest and approve  
        doApproveCol(vars.vault_ad, gatdang); 
        doInvest(vars.vault_ad, gatdang, precision * 1000);
        doApproveCol(address(marketmanager), gatdang); 
        instrument.setValidator( gatdang);  
        vm.prank(gatdang); 
        marketmanager.validatorApprove(vars.marketId); 
    }

    function doDeny(testVars2 memory vars) public {

        vars.vaultBal = collateral.balanceOf(controller.getVaultAd(vars.marketId));  
        vars.cbalbefore = marketmanager.getPool(vars.marketId).cBal(); 
        vm.prank(gatdang); 
        controller.denyMarket(vars.marketId); 
        assertEq(marketmanager.getPool(vars.marketId).cBal(), 0); 
        assertApproxEqAbs(collateral.balanceOf(controller.getVaultAd(vars.marketId)) - vars.vaultBal, vars.cbalbefore, 10); 
        assert(!marketmanager.marketActive(vars.marketId)); 
    }

    function testSomeLongSomeShortApprove() public{
        testVars2 memory vars; 

        somelongsomeshort(vars, true);

        // validators invest and approve  
        doApprove(vars); 
        
        // did correct amount go to vault? the short collateral should stay in pool 
        assertApproxEqAbs(vars.s_amountIn, marketmanager.shortTrades(vars.marketId, chris), 10); 
        assertApproxEqAbs(marketmanager.getShortZCB(vars.marketId).balanceOf(chris), 
            marketmanager.getPool(vars.marketId).cBal(), 10); 

        // how does liquidity change after approval, can people trade in zero liq 
        assertEq(uint256(marketmanager.getPool(vars.marketId).pool().liquidity()), 0); 
    }


    function testSomeLongSomeShortDeny() public{
        testVars2 memory vars; 

        somelongsomeshort(vars, true);

        // validators deny 
        doDeny(vars); 

        vars.sumofcollateral = marketmanager.longTrades(vars.marketId, jonna)
        +marketmanager.longTrades(vars.marketId, sybal)
        +marketmanager.shortTrades(vars.marketId, chris)
        +marketmanager.longTrades(vars.marketId, chris)
        +marketmanager.longTrades(vars.marketId, miku); 
        assertApproxEqAbs(vars.sumofcollateral, vars.cbalbefore, 10); 

        vars.vaultBalBeforeRedeem = collateral.balanceOf(controller.getVaultAd(vars.marketId)); 

        // LEt everyone redeem, total redemption should equal their contribution 
        vm.prank(jonna); 
        marketmanager.redeemDeniedMarket(vars.marketId, true); 
        vm.prank(sybal); 
        marketmanager.redeemDeniedMarket(vars.marketId, true); 
        vm.prank(chris); 
        marketmanager.redeemDeniedMarket(vars.marketId, false); 
        vm.prank(miku); 
        marketmanager.redeemDeniedMarket(vars.marketId, true); 
        assertApproxEqAbs(
            vars.vaultBalBeforeRedeem - collateral.balanceOf(controller.getVaultAd(vars.marketId)) , 
            vars.sumofcollateral, 10
            ); 
    }

    function testLPsCanShortBeforeApproval() public{
        testVars2 memory vars; 

        somelongsomeshort(vars, false);

        bytes memory data; 
        doApproveCol(address(marketmanager), goku); 
        vm.prank(goku); 
        (vars.s_amountIn, vars.s_amountOut) =
            marketmanager.shortBond(vars.marketId, vars.amount1, vars.curPrice + precision/10 , data); 
        assertApproxEqAbs(marketmanager.getShortZCB(vars.marketId).balanceOf(goku),  vars.s_amountIn+ vars.s_amountOut, 10); 

        //redeem denied 
        uint balbefore = collateral.balanceOf(goku); 
        doDeny(vars); 
        vm.prank(goku); 
        marketmanager.redeemDeniedMarket(vars.marketId, false); 
        assertEq(marketmanager.getShortZCB(vars.marketId).balanceOf(goku), 0);
        assertApproxEqAbs(collateral.balanceOf(goku)-balbefore, vars.s_amountIn, 10);  
    }

    function testLPsCanLongAfterApproval() public{
    //     testVars2 memory vars; 

    //     somelongsomeshort(vars, true); 

    //     doApprove(vars); 

    //     //set ask at current price 
    //     bytes memory data = abi.encodePacked(uint16())

    //     // Liq is 0, so somebody has to provide liq or do limit order 
    //     marketmanager.buyBond(vars.marketId, amountIn, limit, data  )   uint256 _marketId, 
    // int256 _amountIn, 
    // uint256 _priceLimit, 
    // bytes calldata _tradeRequestData 

    }

    // function testPeopleCanTradeVibrantCDSMarket() public{}

    // function testManagersCompensation() public{}

    // function testValidatorCompensation() public{}

    // function testLpCompensation() public{}

    // function testLiquidityProvision() public{}

    // function testManyInstrumentsAccountingCorrect() public{}

    // function testDenyRedeemValidator() public{}

    // function testManagersClosePositionWhileAssessment() public{}

    // function testRedeemDeniedMarketDifferentPriceZCB() public{}

    // function testCrazyAmountOfAssessmentTrading() public{}

    // function testCrazyAmountOfPostAssessmentTrading() public{}

    // function testLongShortPayoff() public{}

    // function testPrematureResolveRedeem() public{}

    // function testDeniedResolveRedeem() public {}// funds go back to vault

    // function testReputationIncreaseAndLeverageUp() public {}

    // function testReputationDecreaseAndCantTrade() public {}

    // function testWithdrawRepayCredit() public {}

    // function testRestrictByProxyHandleDefault() public{}

    // function testRepayAndCloseMarket() public{} 
    
    // function testSellingFee() public {}

}

// contract UtilizerCycle is FullCycleTest{


// }
