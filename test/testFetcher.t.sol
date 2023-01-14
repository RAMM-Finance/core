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
import {ReputationManager} from "contracts/protocol/reputationmanager.sol";
import {PoolInstrument} from "contracts/instruments/poolInstrument.sol";
import {VariableInterestRate} from "contracts/instruments/VariableInterestRate.sol";
import {TestNFT} from "contracts/utils/TestNFT.sol";
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";

contract FetcherTest is Test {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    ReputationManager reputationManager;

    Controller controller;
    MarketManager marketmanager;
    Cash collateral;
    VaultFactory vaultFactory;
    SyntheticZCBPoolFactory poolFactory; 
    Cash collateral2; 
    CoveredCallOTC otc;
    VariableInterestRate rateCalculator;
    LinearInterestRate linearRateCalculator; 
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
    PoolInstrument poolInstrument;
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

    // lending pool collateral data.
    Cash col1;
    Cash col2;
    TestNFT nft1;
    TestNFT nft2;
    uint256 wad = 1e18;

    PoolInstrument.CollateralLabel[] clabels;
    PoolInstrument.Collateral[] collaterals;

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

        reputationManager.incrementScore(jonna, precision);
        reputationManager.incrementScore(jott, precision);
        reputationManager.incrementScore(gatdang, precision);
        reputationManager.incrementScore(sybal, precision);
        reputationManager.incrementScore(chris, precision);
        reputationManager.incrementScore(miku, precision);
        reputationManager.incrementScore(goku, precision);
        reputationManager.incrementScore(toku, precision);

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
        clabels.push(
            PoolInstrument.CollateralLabel(
                address(collateral),
                0
            )
        );
        collaterals.push(
            PoolInstrument.Collateral(
            0,
            wad/2,
            wad/4,
            true
        )
        );
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
        reputationManager = new ReputationManager(address(controller), address(marketmanager));
        
        ZCBFactory zcbfactory = new ZCBFactory(); 
        poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory));    

        vm.startPrank(deployer); 
        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setPoolFactory(address(poolFactory)); 
        controller.setReputationManager(address(reputationManager));
        // controller.setValidatorManager(address(validatorManager));
        vm.stopPrank();

        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
            "description"
        ); //vaultId = 1; 
        vault_ad = controller.getVaultfromId(1); 

        console.log("A");
        setUsers();
        console.log("B");

        instrument = new CreditLine(
            vault_ad, 
            jott, principal, interest, duration, faceValue, 
            address(collateral ), address(collateral), principal, 2
            ); 
        instrument.setUtilizer(jott); 

        rateCalculator = new VariableInterestRate();

        col1 = new Cash("ERC20_1", "ERC20_1", 6);
        col2 = new Cash("ERC20_2", "ERC20_2", 7);

        nft1 = new TestNFT("NFT_1", "NFT_1");
        nft2 = new TestNFT("NFT_2", "NFT_2");
        
        bytes memory bites;
        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Collateral[] memory _collaterals = collaterals;
        poolInstrument = new PoolInstrument(
            vault_ad,
            address(controller),
            chris,
            address(collateral),
            "pool name",
            "POOL1",
            address(rateCalculator),
            bites,
            _clabels,
            _collaterals
        );
        otc = new CoveredCallOTC(
            vault_ad, toku, address(collateral2), 
            strikeprice, //strikeprice 
            pricePerContract, //price per contract
            shortCollateral, 
            longCollateral, 
            address(collateral), 
            address(0), 
            10, 
            block.timestamp); 
        otc.setUtilizer(toku); 
        

        // initiateCreditMarket(); 
        // initiateOptionsOTCMarket(); 
        initiateLendingPool();
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
        data.name = "credit line name";

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
        data.instrument_type = Vault.InstrumentType.CoveredCallShort;
        data.maturityDate = 10; 
        data.name = "options instrument";
        controller.initiateMarket(toku, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }
    function testInitiatePool() public {
        initiateLendingPool();
    }

    function initiateLendingPool() public {

        // rateCalculator = new VariableInterestRate();
        // linearRateCalculator = new LinearInterestRate();

        // pool = new PoolInstrument(
        //     address(vault),
        //     address(controller),
        //     deployer,
        //     address(asset),
        //     "pool 1",
        //     "P1",
        //     address(rateCalculator),
        //     initCallData
        // );
        Vault.InstrumentData memory data; 
        Vault.PoolData memory poolData; 

        poolData.saleAmount = principal/4; 
        poolData.initPrice = 7e17; 
        poolData.promisedReturn = 3000000000; 
        poolData.inceptionTime = block.timestamp; 
        poolData.inceptionPrice = 8e17; 
        poolData.leverageFactor = 3e18; 

        data.isPool = false; 
        data.trusted = false; 
        data.balance = 0;
        data.faceValue = 110*1e18;
        data.marketId = 0; 
        data.principal = 100*1e18;
        data.expectedYield = 10*1e18;
        data.duration = 100;
        data.description = "test";
        data.instrument_address = address(poolInstrument);
        data.instrument_type = Vault.InstrumentType.LendingPool;
        data.maturityDate = 0; 
        data.poolData = poolData; 
        data.name = "pool instrument";
        controller.initiateMarket(
            chris,
            data,
            1
        );
        vm.startPrank(chris);

        console.log("Pool collateral length: ", poolInstrument.getAcceptedCollaterals().length);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
        vm.stopPrank();
    }

    function testFetcher() public {
        vault_ad = controller.getVaultfromId(1); 
        Vault vault = Vault(vault_ad);

        vm.prank(goku);
        collateral.faucet(1000000);

        vm.prank(goku);
        collateral.approve(address(vault), 1000);
        
        vm.prank(goku);
        vault.deposit(1000, goku);

        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
            "description"
        ); //vaultId = 2;
        controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketManager.MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
            "description"
        ); //vaultId = 3;
        uint256 numVaults = vaultFactory.numVaults();
        Fetcher fetcher = new Fetcher();

        vault.fetchInstrumentData(1);
        for (uint256 i=1; i < numVaults+1; i++) {
            (
                Fetcher.VaultBundle memory v,
                Fetcher.MarketBundle[] memory m,
                Fetcher.InstrumentBundle[] memory instrs,
                uint256 timestamp
            ) = fetcher.fetchInitial(controller, marketmanager, i);

            // console.log("VAULT LOG: ");
            // console.log("vault id: ", v.vaultId);
            emit log_array(v.marketIds);
            //console.log("params: ", v.default_params.N, v.default_params.sigma, v.default_params.alpha, v.default_params.omega, v.default_params.delta, v.default_params.r, v.default_params.s, v.default_params.steak);
            // console.log("params: ", v.default_params.N);
            // console.log("onlyVerified: ", v.onlyVerified);
            // console.log("r: ", v.r);
            // console.log("asset_limit: ", v.asset_limit);
            // console.log("total_asset_limit: ", v.total_asset_limit);
            // console.log("want: ", v.want.symbol);
            // console.log("totalShares: ", v.totalShares);
            // console.log("vault address: ", v.vault_address);
            // console.log("vault name: ", v.name);
            // console.log("utilization_rate: ", v.utilizationRate);
            // console.log("totalAssets: ", v.totalAssets);
            // console.log("exchangeRate: ", v.exchangeRate);
            // console.log("totalEstimatedAPR: ", v.totalEstimatedAPR);
            // console.log("goalAPR: ", v.goalAPR);
            // console.log("totalProtection: ", v.totalProtection);

            console.log("MARKET LOG: ");
            if (m.length > 0) {
                for (uint j; j < m.length; j++) {
                    // console.log("market id: ", m[j].marketId);
                    // console.log("vaultId", m[j].vaultId);
                    // console.log("creationTimestamp", m[j].creationTimestamp);
                    // console.log("longZCB", m[j].longZCB);
                    // console.log("shortZCB", m[j].shortZCB);
                    // console.log("approved_principal", m[j].approved_principal);
                    // console.log("approved_yield", m[j].approved_yield);
                    // console.log("bondPool", address(m[j].bondPool));
                    //console.log("parameters", m[j].parameters.N, m[j].parameters.sigma, m[j].parameters.alpha, m[j].parameters.omega, m[j].parameters.delta, m[j].parameters.r, m[j].parameters.s, m[j].parameters.steak);
                    // console.log("parameters", m[j].parameters.N);
                    //console.log("phase:", m[j].phase.duringAssessment, m[j].phase.onlyReputable, m[j].phase.resolved, m[j].phase.alive, m[j].phase.atLoss);
                    // console.log("phase: ", m[j].phase.alive);
                    // console.log("longZCBsupply", m[j].longZCBsupply);
                    // console.log("longZCBprice", m[j].longZCBprice);
                    // emit log_array(m[j].validatorData.validators);
                    // console.log("val_cap", m[j].validatorData.val_cap);
                    // console.log("avg_price", m[j].validatorData.avg_price);
                    // console.log("totalSales", m[j].validatorData.totalSales);
                    // console.log("totalStaked", m[j].validatorData.totalStaked);
                    // console.log("numApproved", m[j].validatorData.numApproved);
                    // console.log("initialStake", m[j].validatorData.initialStake);
                    // console.log("finalStake", m[j].validatorData.finalStake);
                    // console.log("numResolved", m[j].validatorData.numResolved);

                }
            }
            if (instrs.length > 0) {
                console.log("INSTRUMENT LOG: ");
                for (uint k; k < instrs.length; k++) {
                    Fetcher.InstrumentBundle memory instr = instrs[k];

                    console.log("name: ",string(abi.encode(instr.name)));
                    console.log("isPool: ",instr.isPool);
                    console.log("type: ", uint256(instr.instrument_type));
                    
                    if (instr.isPool) {
                        console.log("saleAmount: ", instr.poolData.saleAmount);
                        console.log("initPrice: ", instr.poolData.initPrice);
                        console.log("promisedReturn: ", instr.poolData.promisedReturn);
                        console.log("inceptionTime: ", instr.poolData.inceptionTime);
                        console.log("inceptionPrice: ", instr.poolData.inceptionPrice);
                        console.log("leverageFactor: ", instr.poolData.leverageFactor);
                        console.log("managementFee: ", instr.poolData.managementFee);
                        console.log("pju: ", instr.poolData.pju);
                        console.log("psu: ", instr.poolData.psu);
                        console.log("manager stake", instr.managers_stake);

                        console.log("collaterals: ", instr.poolData.collaterals.length);
                        for (uint l; l < instr.poolData.collaterals.length; l++) {
                            console.log("collateral: ", instr.poolData.collaterals[l].name);
                            console.log("collateral decimals: ", instr.poolData.collaterals[l].decimals);
                        }

                    }
                }

            }
        }
    }
}
