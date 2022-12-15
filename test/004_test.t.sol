pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Controller} from "contracts/protocol/controller.sol";
import {MarketManager} from "contracts/protocol/marketmanager.sol";
import {VaultFactory} from "contracts/protocol/factories.sol";
import {CreditLine, MockBorrowerContract} from "contracts/vaults/instrument.sol";
import {Vault} from "contracts/vaults/vault.sol";
import {SyntheticZCBPoolFactory} from "contracts/bonds/synthetic.sol";
import {Cash} from "contracts/utils/Cash.sol";
import {ERC4626} from "contracts/vaults/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract AMMTest is Test {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;
    Controller c;
    MarketManager mm;
    VaultFactory vf;
    SyntheticZCBPoolFactory pf; 
    Cash cash;
    Vault v;
    CreditLine instrument;
    MockBorrowerContract borrowerContract = new MockBorrowerContract();

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
    address zeke;
    address jeong;
    
    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    uint256 W = 1e18; 

    uint256 id = 1;

    uint256 principal = 1000 * precision;
    uint256 interest = 100*precision; 
    uint256 duration = 1*precision; 
    uint256 faceValue = 1100*precision;
    uint256 N = 3;
    uint256 constant precision = 1e18;
    uint256 sigma = precision/20; //5%
    uint256 alpha = precision*4/10; 
    uint256 omega = precision*2/10;
    uint256 delta = precision*2/10; 
    uint256 r = 0;
    uint256 s = precision*2;
    uint256 steak = precision;

    uint256[] randomWords;

    function setUp() public {
        c = new Controller(deployer, address(0));
        cash = new Cash("n","n",18);
        bytes32 data;
        mm = new MarketManager(
            deployer,
            address(c),
            address(0),
            data,
            uint64 (0)
        );

        vf = new VaultFactory(
            address(c)  
        );

        pf = new SyntheticZCBPoolFactory(address(c));


        addressSetup();
        addUserScores();
        addUserFunds();

        c.setMarketManager(address(mm));
        c.setVaultFactory(address(vf));
        c.setPoolFactory(address(pf));

        c.createVault(
            address(cash),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak)
        );

        v = Vault(c.getVaultfromId(1));

        instrument = new CreditLine(
            address(v), 
            jott, principal, interest, duration, faceValue, 
            address(cash), address(cash), principal, 2
            ); 
        instrument.setUtilizer(jott); 
    }



    function initiateCreditMarket() public {
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

        c.initiateMarket(jott, data, 1);

        uint256[] memory words = new uint256[](3);
        words[0] = 19238489189248918234;
        words[1] = 172837;
        words[2] = 18928;
        c.fulfillRandomWords(1, words);

        (bool assess, bool onlyrep, bool resolved, bool alive, bool atloss, uint256 budget) = mm.restriction_data(1);

        assertEq(assess, true);
        assertEq(onlyrep, true);   
        assertEq(alive, true);
        assertEq(address(v.Instruments(1)), address(instrument));
    }

    function testFilterTraders() public {
        address [] memory stuff = c._filterTraders(10, jott);
        
        c._filterTraders(90*W, jeong);

        c._filterTraders(50*W, jeong);
    }

    function testChooseValidators() public {
        initiateCreditMarket();
        emit log_array(c.viewValidators(1));
        assertEq(c.viewValidators(1).length, N);
    }

    function testDenyBeforeMarketApproval1() public  {
        initiateCreditMarket();
        address[] memory vals = c.viewValidators(1);

        // when not validator
        vm.prank(zeke);
        vm.expectRevert("not validator for market");
        c.denyMarket(1);

        // when validator
        vm.prank(vals[0]);
        c.denyMarket(1);

        // market manager checks
        (bool assess, bool onlyrep, bool resolved, bool alive, bool atloss, uint256 budget) = mm.restriction_data(1);
        assertEq(alive, false);
        
        // vault checks
        assertEq(address(v.Instruments(1)), address(0));
    }

    function valApprove(address v, address val) public {
        doApproveCol(address(v), val);
        doInvest(address(v), val, 1000*precision);
        doApproveVT(address(v), address(c), val);
        doApproveCol(address(mm), val);
        vm.prank(val);
        c.validatorApprove(1);
    }

    function testDenyBeforeMarketApproval2() public {
        initiateCreditMarket();
        address[] memory vals = c.viewValidators(1);
        // test retrieve stake
        meetMarketCondition();

        valApprove(address(v), vals[0]);

        vm.prank(vals[1]);
        c.denyMarket(1);

        vm.prank(vals[0]);
        c.unlockValidatorStake(1);
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

    function meetMarketCondition() public  {
                testVars1 memory vars; 

        address proxy =  instrument.getProxy(); 
        borrowerContract.changeOwner(proxy); 
        borrowerContract.autoDelegate(proxy);
        assertEq(borrowerContract.owner(), proxy); 

        vars.marketId = c.getMarketId(jott); 

        vars.vault_ad = c.getVaultfromId(1);
        vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).principal/2; 
        vars.curPrice = mm.getPool(vars.marketId).pool().getCurPrice(); 
        assertEq(vars.curPrice, mm.getPool(vars.marketId).b()); 
       
        // Let manager buy
        bytes memory data;
        doApproveCol(address(mm), jonna); 
        vm.prank(jonna); 
        (vars.amountIn, vars.amountOut) = mm.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice + precision/10 , data); 
        assertApproxEqAbs(vars.amountIn, vars.amountToBuy, 10); 
        assertEq(mm.loggedCollaterals(vars.marketId),vars.amountIn);
        assert(mm.marketCondition(vars.marketId));
    }


    // function testResolveBeforeMaturity() public {
    //     initiateCreditMarket();
    //     address[] memory vals = c.viewValidators(1);
    //     // test retrieve stake
    //     meetMarketCondition();

    //     doApprove(address(v), vals[0]);
    //     doApprove(address(v), vals[1]);
    //     doApprove(address(v), vals[2]);

    //     (bool assess, bool onlyrep, bool resolved, bool alive, bool atloss, uint256 budget) = mm.restriction_data(1);
    //     assertEq(!assess, true);
    //     assertEq(alive, true);

    //     // can't unlock before resolve
    //     vm.prank(vals[0]);
    //     vm.expectRevert("market still alive");
    //     mm.unlockValidatorStake(1);

    //     // validator unlock
    //     for (uint256 i=0; i<vals.length; i++) {
    //         vm.prank(vals[i]);
    //         c.validatorResolve(1);
    //     }

    //     assertEq(c.resolveCondition(1), true);
    // }

    // function testUpdateValidatorStake() public {
    //     initiateCreditMarket();
    //     address[] memory vals = c.viewValidators(1);
    //     emit log_array(vals);
    //     // test retrieve stake
    //     meetMarketCondition();
        
    //     (bool assess, bool onlyrep, bool resolved, bool alive, bool atloss, uint256 budget) = mm.restriction_data(1);

    //     assertEq(assess, true);

    //     doApprove(address(v), vals[0]);
    //     doApprove(address(v), vals[1]);
    //     doApprove(address(v), vals[2]);

    //     vm.prank(vals[0]);
    //     c.validatorResolve(1);
    //     vm.prank(vals[1]);
    //     c.validatorResolve(1);
    //     vm.prank(vals[2]);
    //     c.validatorResolve(1);

    //     assertEq(c.resolveCondition(1), true);
        
    //     c.beforeResolve(1);

    //     vm.prank(vals[0]);
    //     c.afterResolve(1);

    //     // test update stake
    //     uint256 p = Vault(c.getVaultfromId(1)).fetchInstrumentData(1).principal;

    //     uint256 total = c.getTotalStaked(1);
    //     c._updateValidatorStake(1, principal, principal/2);
    //     uint256 newtotal = total/2 + ( principal - principal/2 ).divWadDown(principal).mulWadDown(total/2);
    //     assertEq(newtotal, c.getTotalStaked(1));
    // }

    function doApprove(uint256 marketId, address vault) public{ //TODO: update
        // validators invest and approve 
        address[] memory vals = c.viewValidators(marketId);
        console.log("val.length", vals.length);
        uint256 initialStake = c.getInitialStake(marketId);
        for (uint i=0; i < vals.length; i++) {
            doApproveCol(vault, vals[i]);
            doApproveVault(vault, vals[i], address(c));
            doApproveCol(address(mm), vals[i]);
            doMint(vault, vals[i], initialStake);
            vm.prank(vals[i]);
            c.validatorApprove(marketId);
        }
    }

    function doApproveVault(address vault, address _from, address _to) public {
        vm.prank(_from);
        ERC20(vault).approve(_to, type(uint256).max);
    }

    function doMint(address vault, address _by, uint256 shares) public {
        vm.prank(_by);
        Vault(vault).mint(shares, _by);
    }

    function addressSetup() public {
        jonna = address(0xbabe);
        vm.label(jonna, "jonna");
        jott = address(0xbabe2); 
        vm.label(jott, "jott");
        gatdang = address(0xbabe3); 
        vm.label(gatdang, "gatdang");
        sybal = address(0xbabe4);
        vm.label(sybal, "sybal");
        chris=address(0xbabe5);
        vm.label(chris, "chris");
        miku = address(0xbabe6);
        vm.label(miku, "miku");
        goku = address(0xbabe7); 
        vm.label(goku, "goku");
        toku = address(0xbabe8);
        vm.label(toku, "toku"); 
        zeke = address(0xbabe9);
        vm.label(zeke, "zeke");
        jeong = address(0xbabe10);
        vm.label(jeong, "jeong");

        vm.prank(jonna); 
        c.testVerifyAddress(); 
        vm.prank(jott);
        c.testVerifyAddress();
        vm.prank(gatdang);
        c.testVerifyAddress();
        vm.prank(sybal);
        c.testVerifyAddress();
        vm.prank(chris);
        c.testVerifyAddress();
        vm.prank(miku);
        c.testVerifyAddress();
        vm.prank(goku);
        c.testVerifyAddress();
        vm.prank(toku);
        c.testVerifyAddress();
        vm.prank(zeke);
        c.testVerifyAddress();
        vm.prank(jeong);
        c.testVerifyAddress();
    }

    function addUserScores() public {
        c._incrementScore(jonna, 10);
        c._incrementScore(jott, 20);
        c._incrementScore(gatdang, 30);
        c._incrementScore(goku, 40);
        c._incrementScore(toku, 50);
        c._incrementScore(miku, 60);
        c._incrementScore(chris, 70);
        c._incrementScore(sybal, 80);
        c._incrementScore(zeke, 90);
        c._incrementScore(jeong, 100);
    }

    function addUserFunds() public {
        vm.prank(jonna);
        cash.faucet(100000*precision);
        vm.prank(jott);
        cash.faucet(100000*precision);
        vm.prank(gatdang);
        cash.faucet(100000*precision);
        vm.prank(goku);
        cash.faucet(100000*precision);
        vm.prank(toku);
        cash.faucet(100000*precision);
        vm.prank(miku);
        cash.faucet(100000*precision);
        vm.prank(chris);
        cash.faucet(100000*precision);
        vm.prank(sybal);
        cash.faucet(100000*precision);
        vm.prank(zeke);
        cash.faucet(100000*precision);
        vm.prank(jeong);
        cash.faucet(100000*precision);
    }

    function doInvest(address vault, address _by, uint256 amount) public{
        vm.prank(_by); 
        Vault(vault).deposit(amount, _by);
    }

    function doApproveCol(address _who, address _by) public{
        vm.prank(_by); 
        cash.approve(_who, type(uint256).max); 
    }

    function doApproveVT(address vault, address _who, address _by) public {
        vm.prank(_by);
        v.approve(_who, type(uint256).max);
    }

    function cBal(address _who) public returns(uint256) {
        return cash.balanceOf(_who); 
    }
}