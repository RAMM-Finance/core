pragma solidity ^0.8.17;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
// import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {ERC20CreditLine} from "../contracts/instruments/creditline.sol";
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol";
import {Instrument} from "../contracts/vaults/instrument.sol";
import {StorageHandler} from "../contracts/global/GlobalStorage.sol";
import "contracts/global/types.sol"; 
import {PoolInstrument} from "../contracts/instruments/poolInstrument.sol";
import {TestNFT} from "../contracts/utils/TestNFT.sol";
// import {Auctioneer} from "../contracts/instruments/auctioneer.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
import {OrderManager} from "../contracts/protocol/ordermanager.sol"; 

// Tests structure: 0 State starts at test base, modify it 

// 0. Every test have a purpose, write it down and changeable parameters + states
// 1. Fuzz unit tests as much as possible 
//  - contract states that deviate from 0 state
//  - random inputs  
// 2. else integration tests, fuzz this if possible 
// 3. else Edge case tests, 

// invariants: 
// 1. junior supply invariant,
// 2. instrument balance invariant, 
// 3. for a single instrument, everything is solvent(enough funds to redeem)
// 4. senior supply invariant 

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
    ERC20CreditLine erc20Creditline;
    SimpleNFTPool nftPool; 
    LeverageManager leverageManager; 
    ValidatorManager validatorManager; 
    OrderManager orderManager; 
    StorageHandler Data; 
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


    // participants
    address utilizer1;
    address manager1;
    address manager2;
    address manager3;
    address validator1;
    address borrower1;

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

    // pool instrument vars
    Cash cash1;
    Cash cash2;
    TestNFT nft1;
    TestNFT nft2;

    PoolInstrument poolInstrument;
    // Auctioneer auctioneer;

    /// LOGGING FUNCTIONALITY
    function logDec(string memory s, uint256 x, uint256 y) public {
        emit log_named_decimal_uint(s, x, y);
    }

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

        utilizer1 = address(0xbabe10);
        vm.label(utilizer1, "utilizer1");
        manager1 = address(0xbabe11);
        vm.label(manager1, "manager1");
        manager2 = address(0xbabe12);
        vm.label(manager2, "manager2");
        manager3 = address(0xbabe13);
        vm.label(manager3, "manager3");
        validator1 = address(0xbabe14);
        vm.label(validator1, "validator1");
        borrower1 = address(0xbabe15);
        vm.label(borrower1, "borrower1");
        


        vm.startPrank(deployer);
        reputationManager.incrementScore(jonna, precision);
        reputationManager.incrementScore(jott, precision);
        reputationManager.incrementScore(gatdang, precision);
        reputationManager.incrementScore(sybal, precision);
        reputationManager.incrementScore(chris, precision);
        reputationManager.incrementScore(miku, precision);
        reputationManager.incrementScore(goku, precision);
        reputationManager.incrementScore(toku, precision);
        vm.stopPrank();

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

        vm.startPrank(deployer);
        controller.verifyAddress(toku); 

        controller.verifyAddress(jott);

        controller.verifyAddress(jonna);

        controller.verifyAddress(gatdang); 

        controller.verifyAddress(chris); 

        controller.verifyAddress(miku); 

        controller.verifyAddress(sybal);
        vm.stopPrank();
    }


    // only for pool instrument.
    function setCollaterals() public {
       // collateral = new Cash("Collateral", "COLL", 18);
        cash1 = new Cash("cash1", "CASH1", 18);
        cash2 = new Cash("cash2", "CASH2", 18);
        nft1 = new TestNFT("NFT1", "NFT1");
        nft2 = new TestNFT("NFT2", "NFT2");
    }

    /// @notice test setup
    function testSetup() public {
        deploySetUps();
        setUsers();
        setCollaterals();
        controllerSetup();
    }


    PoolInstrument.Config poolConfig;
    PoolInstrument.CollateralLabel[] clabels;
    uint256 step = 5.64701 * 1e11;
    uint256 internal constant UTIL_PREC = 1e5;
    uint256 lowerUtil = UTIL_PREC * 6 / 10;
    uint256 upperUtil = UTIL_PREC * 8 / 10;
    uint256 buf = 1.1e18;
    uint256 maxDiscount = 2e17; // 20%

    function setupCollateral() public{
        setCollaterals(); 

        clabels.push(
            PoolInstrument.CollateralLabel(
                address(cash1),
                0,
                true
            )
        );
        clabels.push(
            PoolInstrument.CollateralLabel(
                address(nft1),
                1,
                false
            )
        );

        poolConfig = PoolInstrument.Config(
            unit,
            5 * unit / 4,
            step,
            lowerUtil,
            upperUtil,
            0,
            maxDiscount,
            buf
        );
    }

    function deploySetUps() public{
        
        controller = new Controller(deployer);
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
        reputationManager = new ReputationManager(address(controller), address(marketmanager));
        
        leverageManager = new LeverageManager(address(controller), address(marketmanager), address(reputationManager));
        Data = new StorageHandler(); 
        validatorManager = new ValidatorManager(address(controller), address(marketmanager),address(reputationManager) );     
        leverageManager = new LeverageManager(address(controller), address(marketmanager),address(reputationManager) );
        orderManager = new OrderManager(address(controller));
        Data = new StorageHandler(); 
        controllerSetup(); 

    }

    function controllerSetup() public{
        vm.startPrank(deployer);

        bytes memory stuff = abi.encode(
        address(marketmanager), 
        address(reputationManager), 
        address(validatorManager), 
        address(leverageManager), 
        address(orderManager),
        address(vaultFactory),
        address(poolFactory),
        address(Data)
        ); 

        controller.initialize(stuff);
        vm.stopPrank();
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
        data.instrument_address = address(erc20Creditline);
        data.instrument_type = InstrumentType.CreditLine;
        data.maturityDate = 10; 

        controller.initiateMarket(jott, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function initiateCreditline() public {
        erc20Creditline = new ERC20CreditLine(
            vault_ad,
            jott,
            principal,
            interest,
            duration,
            address(collateral),
            principal
        );
        //instrument.setUtilizer(jott); 

        initiateCreditMarket(); 
    }

    // function makeCreditlineMarket(address creditline, uint256 vaultId) public returns (uint256 marketId) {
    //     InstrumentData memory data;
    //     data.trusted = false; 
    //     data.balance = 0;

    //     data.principal = BaseCreditLine(creditline).principal();
    //     data.expectedYield = CreditLine(creditline).notionalInterest();
    //     data.faceValue = CreditLine(creditline).faceValue();
    //     data.marketId = 0;
    //     data.duration = CreditLine(creditline).duration();
    //     data.description = "test";
    //     data.instrument_address = address(creditline);
    //     data.instrument_type = InstrumentType.CreditLine;
    //     data.maturityDate = 0;
    //     marketId = controller.initiateMarket(
    //         creditline,
    //         data,
    //         vaultId
    //     );
    // }

    // function createCreditlineInstrument(uint256 vaultId, uint256 principal, uint256 yield, uint256 duration) public returns (address creditline) {
    //     address vault = address(controller.getVaultfromId(vaultId));
    //     CreditLine creditline = new CreditLine(
    //         vault,
    //         utilizer1, 
    //         principal,
    //         yield,
    //         duration,
    //         address(0),
    //         address(0),
    //         0,
    //         3
    //     );
    //     return address(creditline);
    // }

    function initiateOptionsOTCMarket() public{
        if(address(otc) == address(0))
        otc = new CoveredCallOTC(
            vault_ad, toku, 
            strikeprice, //strikeprice 
            pricePerContract, //price per contract
            shortCollateral, 
            longCollateral, 
            address(collateral),
            10,
            block.timestamp); 

        // otc.setUtilizer(toku); 
        InstrumentData memory data;
        data.trusted = false; 
        data.balance = 0;
        data.faceValue = faceValue;
        data.marketId = 0; 
        data.principal = principal;
        data.expectedYield = longCollateral;
        data.duration = duration;
        data.description = "test";
        data.instrument_address = address(otc);
        data.instrument_type = InstrumentType.CoveredCallShort;
        data.maturityDate = 10; 
        controller.initiateMarket(toku, data, 1);
        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function initiateSimpleNFTLendingPool() public {
        InstrumentData memory data; 
        PoolData memory poolData; 

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
        data.instrument_type = InstrumentType.LendingPool;
        data.maturityDate = 0; 
        data.poolData = poolData; 

        controller.initiateMarket(toku, data, 1); 

        uint256[] memory words = new uint256[](N);
        for (uint256 i=0; i< words.length; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(i)));
        }
        controller.fulfillRandomWords(1, words);
    }

    function generatePerpInstrumentData(
        uint256 saleAmount, 
        uint256 initPrice,
        uint256 promisedReturn, 
        uint256 inceptionPrice, 
        uint256 leverageFactor, 

        address instrument_address 

        ) public returns(InstrumentData memory, PoolData memory) {
        InstrumentData memory data; 
        PoolData memory poolData; 

        poolData.saleAmount = saleAmount; 
        poolData.initPrice = initPrice; 
        poolData.promisedReturn = promisedReturn; 
        poolData.inceptionTime = block.timestamp; 
        poolData.inceptionPrice = inceptionPrice; 
        poolData.leverageFactor = leverageFactor; 

        data.isPool = true; 
        data.trusted = false; 
        data.balance = 0;
        data.faceValue = 0;
        data.marketId = 0; 
        data.principal = 0;
        data.expectedYield = 0;
        data.duration = 0;
        data.description = "test";
        data.instrument_address = instrument_address;
        data.instrument_type = InstrumentType.LendingPool;
        data.maturityDate = 0; 
        data.poolData = poolData; 

        return (data, poolData); 
    }

    /**
        wrapper for resolving market.
     */
    function resolveMarket(uint256 marketId) public {
        vm.startPrank(deployer);
        //controller.resolveInstrument1(marketId); 

        controller.beforeResolve(marketId); 
        controller.resolveMarket(marketId);
        vm.stopPrank();
    }

    function borrowFromPool(uint256 collateralAmount, uint256 amount, address who) public{

        vm.startPrank(who); 
        cash1.approve(address(poolInstrument), collateralAmount); 
        cash1.faucet(collateralAmount);

        poolInstrument.addCollateral(
            address(cash1),
            0,
            collateralAmount,
            who
        );
        // poolInstrument.addCollateral(
        //     address(nft1),
        //     1,
        //     0,
        //     toku,
        //     true
        // );

        

        poolInstrument.borrow(
            amount,
            address(0),
            0,
            0,
            who
        );
        vm.stopPrank(); 
    }

    function setupPricer(
        uint256 multiplier, 
        bool constantRF, 

        uint256 saleAmount, 
        uint256 initPrice,
        uint256 promisedReturn, 
        uint256 inceptionPrice, 
        uint256 leverageFactor, 

        address instrument_address
        ) public returns(uint256){

        CoreMarketData memory mdata; 
        mdata.longZCB = ERC20(address(collateral)); 
        mdata.isPool = true; 
        (InstrumentData memory idata, ) = generatePerpInstrumentData(
         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor, 
         instrument_address 
        ); 

        uint256 marketId = controller.initiateMarket(toku, idata, 1); 
        return marketId; 
           
    }

    function createLendingPoolAndPricer(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor

        ) public returns(testVars1 memory){
        testVars1 memory vars; 

        vars.saleAmount = constrictToRange(fuzzput(saleAmount, 1e17), 10e18, 10000000e18); 
        vars.initPrice = constrictToRange(fuzzput(initPrice, 1e17), 1e17, 95e16); 
        vars.promisedReturn = constrictToRange(fuzzput(promisedReturn, 10), 1, 30000000000); 
        vars.inceptionPrice = constrictToRange(fuzzput(inceptionPrice, 1e17), 1e17, 95e16); 
        vars.leverageFactor = constrictToRange(fuzzput(leverageFactor, 1e17), 1e18, 5e18); 
        vm.assume(vars.initPrice < vars.inceptionPrice); 

        console.log('Params', vars.saleAmount, vars.initPrice, vars.promisedReturn); 
        console.log('Parmas2', vars.inceptionPrice, vars.leverageFactor); 

        deployExampleLendingPool(
            controller.getVaultfromId(1)
        ); 

        vars.vault_ad = controller.getVaultfromId(1); 

        vars.marketId = setupPricer(
             0, false, 
            vars.saleAmount, vars.initPrice, vars.promisedReturn, vars.inceptionPrice, vars.leverageFactor, 
            address(poolInstrument)
        ); 

        return vars; 
    }


    function deployExampleLendingPool(
        address vault_ad
        ) public{

        LinearInterestRate linearRateCalculator = (new LinearInterestRate());
        uint256 _minInterest = 0;
        uint256 _vertexInterest = 8319516187; // 30% APR
        uint256 _maxInterest = 12857214404; // 50% APR
        uint256  UTIL_PREC = 1e5;
        uint256 _vertexUtilization = UTIL_PREC * 4/5; // 80% utilization

        bytes memory linearRateData;
        linearRateData = abi.encode(_minInterest,_vertexInterest, _maxInterest, _vertexUtilization);
        setupCollateral(); 

        PoolInstrument.CollateralLabel[] memory _clabels = clabels ;
        PoolInstrument.Config memory _config = poolConfig; 

        poolInstrument = new PoolInstrument(
            vault_ad,
            address(reputationManager),
            address(utilizer1),
            address(linearRateCalculator),
            "Pool1",
            "P1",
            linearRateData,
            _config,
            clabels
        );
    }

    function closeMarket(uint256 marketId) public {
        vm.prank(deployer);
        controller.beforeResolve(marketId); 
        controller.resolveMarket( marketId); 

    }

    function donateToInstrument(address vaultad, address instrument, uint256 amount, uint256 marketId) public {
        vm.startPrank(jonna); 
        Vault(vaultad).UNDERLYING().transfer(instrument, amount); 
        vm.stopPrank(); 
        if(Vault(vaultad).isTrusted(Instrument(instrument)))
            Vault(vaultad).harvest(marketId); 
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
        controller.approveMarket(marketId);
    }

    function doApproveFromStart(uint256 marketId, uint256 amountToBuy) public returns(uint256){

        address vault_ad = controller.getVaultfromId(marketId); 
        // vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
        bytes memory data; 
        doApproveCol(address(marketmanager), jonna); 

        // doInvest(vault_ad, gatdang, precision * 100000);
        console.log('wtf'); 
        vm.prank(jonna); 
        
        (, uint256 amountOut) = marketmanager.buyBond(marketId, int256(amountToBuy), precision , data); 
                console.log('wtf2'); 

        // let validator invest to vault and approve 
        doApprove(marketId, vault_ad);
        return amountOut; 
    }

    function assertSameExchangeRate(uint startExchangeRate, address vault_ad) public {
        assertEq(startExchangeRate, Vault(vault_ad).previewMint(1e18)); 
    } 

    function assertApproxEqBasis(uint a, uint b, uint basis ) public{
        if(a/10000 < 100)  assertApproxEqAbs(a, b, 1000); 

        else assertApproxEqAbs(a, b, basis * a/10000); 
    }

    function constrictToRange(
        uint256 x,
        uint256 min,
        uint256 max
    ) internal view returns (uint256 result) {
        require(max >= min, "MAX_LESS_THAN_MIN");
        // vm.assume(x<=max); 
        // vm.assume(x>= min);

        if (min == max) return min;  // A range of 0 is effectively a single value.

        if (x >= min && x <= max) return x;  // Use value directly from fuzz if already in range.

        if (min == 0 && max == type(uint256).max) return x;  // The entire uint256 space is effectively x.

        result = (x % ((max - min) + 1)) + min;  // Given the above exit conditions, `(max - min) + 1 <= type(uint256).max`.
        require(result>=min && result <= max, "MAX_LESS_THAN_MIN_AF"); 
    }

    // ALL input will be mod 2**32, to limit fuzzing space 
    function fuzzput(
        uint32 x, 
        uint256 base //some number like 1e16 or 0.001
        ) internal view returns(uint256){
        return uint256(x) * base; 
    }


    struct testVars1{
        uint256 marketId;
        address vault_ad; 
        address instrument; 
        uint amountToBuy; 
        uint curPrice; 

        uint amountIn;
        uint amountOut; 
        uint amountIn2; 
        uint amountOut2; 
        uint amountToIssue; 

        uint valamountIn; 
        uint cbalnow; 
        uint cbalnow2; 
        uint cbalnow3; 

        uint pju; 
        uint psu;
        uint pju2; 
        uint psu2; 

        uint saleAmount;
        uint initPrice;
        uint promisedReturn;
        uint inceptionPrice;
        uint leverageFactor;

        uint issueAmount; 
        uint orderId; 

        uint rateBefore; 
        uint256 balbefore;
        uint balBefore; 
        uint256 ratebefore; 

        uint amount1; 
        uint amount2; 
        uint amount3; 
        uint amount4; 

        uint totalSupply; 
        uint budget; 

        uint collateral_redeem_amount; 
        uint seniorAmount; 
        uint pjuDiscounted; 

        uint urate1; 
        uint urate2; 
        uint start; 
        uint mid; 
    }



   
}