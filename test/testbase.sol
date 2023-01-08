pragma solidity ^0.8.17;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {SyntheticZCBPoolFactory} from "../contracts/bonds/synthetic.sol"; 
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {LeverageModule} from "../contracts/protocol/LeverageModule.sol"; 
import {Instrument} from "../contracts/vaults/instrument.sol"; 

contract CustomTestBase is Test {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    Controller controller;
    MarketManager marketmanager;
    Cash collateral;
    VaultFactory vaultFactory;
    SyntheticZCBPoolFactory poolFactory; 
    Cash collateral2; 
    CoveredCallOTC otc; 
    MockBorrowerContract borrowerContract = new MockBorrowerContract();
    CreditLine instrument;
    SimpleNFTPool nftPool; 
    LeverageModule leverageModule; 
    ValidatorManager validatorManager; 
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
        if(address(otc) == address(0))
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
        controller.initiateMarket(toku, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function initiateSimpleNFTLendingPool() public {
        Vault.InstrumentData memory data; 
        Vault.PoolData memory poolData; 

        // poolData.saleAmount = principal/4; 
        // poolData.initPrice = 7e17; 
        // poolData.promisedReturn = 3000000000; 
        // poolData.inceptionTime = block.timestamp; 
        // poolData.inceptionPrice = 8e17; 
        // poolData.leverageFactor = 3e18; 

        poolData.saleAmount = principal/4; 
        poolData.initPrice = 7e17; 
        poolData.promisedReturn = 3000000000; 
        poolData.inceptionTime = block.timestamp; 
        poolData.inceptionPrice = 8e17; 
        poolData.leverageFactor = 5e18; 

        data.isPool = true; 
        data.trusted = false; 
        data.balance = 0;
        data.faceValue = 0;
        data.marketId = 0; 
        data.principal = 0;
        data.expectedYield = 0;
        data.duration = 0;
        data.description = "test";
        data.instrument_address = address(nftPool);
        data.instrument_type = Vault.InstrumentType.LendingPool;
        data.maturityDate = 0; 
        data.poolData = poolData; 

        controller.initiateMarket(toku, data, 1); 

        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);

    }

    function initiateLeverageModule() public {
        leverageModule = new LeverageModule(address(controller)); 
    }

    function donateToInstrument(address vaultad, address instrument, uint256 amount) public {
        vm.startPrank(jonna); 
        Vault(vaultad).UNDERLYING().transfer(instrument, amount); 
        vm.stopPrank(); 
        if(Vault(vaultad).isTrusted(Instrument(instrument)))
            Vault(vaultad).harvest(instrument); 
    }


    function doApproveCol(address _who, address _by) public{
        vm.prank(_by); 
        collateral.approve(_who, type(uint256).max); 
    }
    function doInvest(address vault, address _by, uint256 amount) public{
        doApproveCol(vault, _by ); 
        vm.prank(_by); 
        Vault(vault).deposit(amount, _by); 
    }
    function doApproveVault(address vault, address _from, address _to) public {
        vm.prank(_from);
        ERC20(vault).approve(_to, type(uint256).max);
    }

    function doMint(address vault, address _by, uint256 shares) public {
        vm.prank(_by);
        Vault(vault).mint(shares, _by);
    }
    function cBal(address _who) public returns(uint256) {
        return collateral.balanceOf(_who); 
    }
    function doApprove(uint256 marketId, address vault) public{ //TODO: update
        // validators invest and approve 
        // address[] memory vals = controller.viewValidators(marketId);
        // console.log("val.length", vals.length);
        // uint256 initialStake = controller.getInitialStake(marketId);
        // for (uint i=0; i < vals.length; i++) {
        //     doApproveCol(vault, vals[i]);
        //     doApproveVault(vault, vals[i], address(controller));
        //     doApproveCol(address(marketmanager), vals[i]);
        //     doMint(vault, vals[i], initialStake);
        //     vm.prank(vals[i]);
        //     controller.validatorApprove(marketId);
        // }
        vm.prank(deployer); 
        controller.testApproveMarket(marketId);
    }
   
}