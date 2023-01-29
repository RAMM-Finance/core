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
import {ReputationManager} from "contracts/protocol/reputationmanager.sol";
import "contracts/global/types.sol"; 

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
    ReputationManager reputationManager;

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
    }

    function setUp() public {

        
    }


    function initiateCreditMarket() public {
        InstrumentData memory data;

        data.trusted = false; 
        data.balance = 0;
        data.faceValue = faceValue;
        data.marketId = 0; 
        data.principal = principal;
        data.expectedYield = interest;
        data.duration = duration;
        data.description = "test";
        data.instrument_address = address(instrument);
        data.instrument_type = InstrumentType.CreditLine;
        data.maturityDate = 0; 
        data.name = "name";

        reputationManager.incrementScore(jonna, precision);

        controller.initiateMarket(jott, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);

    }
}