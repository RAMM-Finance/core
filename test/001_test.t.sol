pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "src/protocol/controller.sol";
import {MarketManager} from "src/protocol/marketmanager.sol";
import {ReputationNFT} from "src/protocol/reputationtoken.sol";
import {Cash} from "src/libraries/Cash.sol";
import {CreditLine, MockBorrowerContract} from "src/vaults/instrument.sol";
import {SyntheticZCBPoolFactory} from "src/bonds/synthetic.sol"; 

contract FullCycleTest is Test {
    Controller controller;
    MarketManager marketmanager;
    Cash collateral;
    VaultFactory vaultFactory;
    ReputationNFT repToken;
    CreditLine instrument;
    SyntheticZCBPoolFactory poolFactory; 
    
    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    uint256 unit = 10**18; 
    uint256 constant precision = 1e18;
    address vault_ad; 

    address jonna;
    address jott; 
    address gatdang;
    address sybal; 
    address chris; 
    address kory; 
    address moka;
    address tyson;

    // Varaibles that sould be tinkered
    uint256 principal = 1000 * precision;
    // uint256 drawdown = 5000000; 
    uint256 interest = 100*precision; 
    uint256 duration = 1*precision; 
    uint256 faceValue = 1100*precision; 
    MockBorrowerContract borrwerContract = new MockBorrowerContract();

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
            MarketManager.MarketParameters(
                1, precision/20, precision*4/10, precision*2/10, precision*2/10, 
                10, precision*2, precision) 
        );
        vault_ad = controller.getVaultfromId(1); 

        jonna = address(0xbabe);
        vm.label(jonna, "jonna"); // manager1
        jott = address(0xbabe2); 
        vm.label(jott, "jott"); // utilizer 

        vm.prank(jonna); 
        collateral.faucet(100000*precision);
        vm.prank(jott); 
        collateral.faucet(100000*precision);

        vm.prank(jott); 
        repToken.mint(jott); 
        vm.prank(jonna); 
        repToken.mint(jonna); 

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

    function testThis() public{
    }
}