pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "contracts/protocol/controller.sol";
import {MarketManager} from "contracts/protocol/marketmanager.sol";
import {ReputationNFT} from "contracts/protocol/reputationtoken.sol";
import {Cash} from "contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "contracts/vaults/instrument.sol";
import {SyntheticZCBPoolFactory,ZCBFactory} from "contracts/bonds/synthetic.sol"; 
import {LinearCurve} from "contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Fetcher} from "contracts/utils/fetcher.sol";

contract FullCycleTest is Test {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    Controller controller;
    MarketManager marketmanager;
    Cash collateral;
    VaultFactory vaultFactory;
    SyntheticZCBPoolFactory poolFactory; 
    Cash collateral2; 
    CoveredCallOTC otc; 
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
    uint256 r = 0;
    uint256 s = precision*2;
    uint256 steak = precision;
    uint256 amount1; 
    uint256 amount2; 
    uint256 amount3; 
    uint256 amount4; 

    uint256 strikeprice = precision; 
    uint256 pricePerContract = precision/10; //pricepercontract * 
    uint256 shortCollateral = principal; 
    uint256 longCollateral = shortCollateral.mulWadDown(pricePerContract); 

    function setUsers() public {
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
        toku = address(0xbabe8);
        vm.label(toku, "toku"); 

        controller._incrementScore(jonna, precision);
        controller._incrementScore(jott, precision);
        controller._incrementScore(gatdang, precision);
        controller._incrementScore(sybal, precision);
        controller._incrementScore(chris, precision);
        controller._incrementScore(miku, precision);
        controller._incrementScore(goku, precision);
        controller._incrementScore(toku, precision);

        vm.prank(jonna); 
        collateral.faucet(10000000*precision);
        vm.prank(jott); 
        collateral.faucet(10000000*precision);
        vm.prank(gatdang); 
        collateral.faucet(10000000*precision); 
        vm.prank(sybal); 
        collateral.faucet(10000000*precision); 
        vm.prank(chris); 
        collateral.faucet(10000000*precision); 
        vm.prank(miku); 
        collateral.faucet(10000000*precision); 
        vm.prank(goku);
        collateral.faucet(10000000*precision); 
        vm.prank(toku);
        collateral.faucet(10000000*precision);

        vm.prank(toku); 
        controller.testVerifyAddress(); 
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
    }

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

        vm.startPrank(deployer); 
        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setPoolFactory(address(poolFactory)); 
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

        instrument = new CreditLine(
            vault_ad, 
            jott, principal, interest, duration, faceValue, 
            address(collateral ), address(collateral), principal, 2
            ); 
        instrument.setUtilizer(jott); 

        otc = new CoveredCallOTC(
            vault_ad, toku, address(collateral2), 
            strikeprice, //strikeprice 
            pricePerContract, //price per contract
            shortCollateral, 
            longCollateral, 
            address(collateral), 
            address(0), 
            10); 
        otc.setUtilizer(toku); 

        initiateCreditMarket(); 
        initiateOptionsOTCMarket(); 
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
        data.instrument_address = address(instrument);
        data.instrument_type = Vault.InstrumentType.CreditLine;
        data.maturityDate = 10; 

        controller.initiateMarket(jott, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function initiateOptionsOTCMarket() public{
        Vault.InstrumentData memory data;
        data.trusted = false; 
        data.balance = 0;
        data.faceValue = faceValue;
        data.marketId = 0; 
        data.principal = principal;
        data.expectedYield = interest;
        data.duration = duration;
        data.description = "test";
        data.instrument_address = address(otc);
        data.instrument_type = Vault.InstrumentType.CoveredCall;
        data.maturityDate = 10; 
        controller.initiateMarket(toku, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function testFetcher() public {
        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak)
        ); //vaultId = 2;
        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak)
        ); //vaultId = 3;
        uint256 numVaults = vaultFactory.numVaults();
        Fetcher fetcher = new Fetcher();
        for (uint256 i=1; i < numVaults+1; i++) {
            (
                Fetcher.VaultBundle memory v,
                Fetcher.MarketBundle[] memory m,
                Fetcher.InstrumentBundle[] memory instrs,
                uint256 timestamp
            ) = fetcher.fetchInitial(controller, marketmanager, i);

            console.log("VAULT LOG: ");
            console.log("vault id: ", v.vaultId);
            emit log_array(v.marketIds);
            //console.log("params: ", v.default_params.N, v.default_params.sigma, v.default_params.alpha, v.default_params.omega, v.default_params.delta, v.default_params.r, v.default_params.s, v.default_params.steak);
            console.log("params: ", v.default_params.N);
            console.log("onlyVerified: ", v.onlyVerified);
            console.log("r: ", v.r);
            console.log("asset_limit: ", v.asset_limit);
            console.log("total_asset_limit: ", v.total_asset_limit);
            console.log("want: ", v.want.symbol);
            console.log("totalShares: ", v.totalShares);
            console.log("vault address: ", v.vault_address);
            console.log("vault name: ", v.name);

            console.log("MARKET LOG: ");
            if (m.length > 0) {
                for (uint j; j < m.length; j++) {
                    console.log("market id: ", m[j].marketId);
                    console.log("vaultId", m[j].vaultId);
                    console.log("creationTimestamp", m[j].creationTimestamp);
                    console.log("longZCB", m[j].longZCB);
                    console.log("shortZCB", m[j].shortZCB);
                    console.log("approved_principal", m[j].approved_principal);
                    console.log("approved_yield", m[j].approved_yield);
                    console.log("bondPool", address(m[j].bondPool));
                    //console.log("parameters", m[j].parameters.N, m[j].parameters.sigma, m[j].parameters.alpha, m[j].parameters.omega, m[j].parameters.delta, m[j].parameters.r, m[j].parameters.s, m[j].parameters.steak);
                    console.log("parameters", m[j].parameters.N);
                    //console.log("phase:", m[j].phase.duringAssessment, m[j].phase.onlyReputable, m[j].phase.resolved, m[j].phase.alive, m[j].phase.atLoss);
                    console.log("phase: ", m[j].phase.alive);
                    console.log("longZCBsupply", m[j].longZCBsupply);
                    console.log("longZCBprice", m[j].longZCBprice);
                }
            }
        }
    }
}
