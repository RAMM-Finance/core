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
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol"; 
import {Instrument} from "../contracts/vaults/instrument.sol"; 
import {StorageHandler} from "../contracts/global/GlobalStorage.sol"; 
import "contracts/global/types.sol"; 
import {PoolInstrument} from "../contracts/instruments/poolInstrument.sol";
import {TestNFT} from "../contracts/utils/TestNFT.sol";
import {CustomTestBase} from "./testbase.sol";
import {ZCBFactory} from "../contracts/bonds/synthetic.sol";
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {VaultAccount} from "../contracts/instruments/VaultAccount.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
import {Auctioneer} from "../contracts/instruments/auctioneer.sol";


contract PoolInstrumentTest is CustomTestBase {
    using FixedPointMath for uint256;

    PoolInstrument.Config[] configs;
    PoolInstrument.CollateralLabel[] clabels;

    uint256 totalCollateral; 
    uint256 maxAmount = unit/2 + unit/10;
    uint256 maxBorrowAmount = unit/2;

    // auction parameters
    uint256 tau = 1000 seconds; // seconds after auction start when the price reaches zero -> linearDecrease
    uint256 cusp = unit/2; // percentage price drop that can occur before an auction must be reset.
    uint256 tail = 500 seconds; // seconds that can elapse before an auction must be reset. 
    uint256 buf = unit*5/4; // auction start price = buf * maxAmount

    VariableInterestRate variableRateCalculator;
    LinearInterestRate linearRateCalculator;

    uint256 _minInterest = 0;
    uint256 _vertexInterest = 8319516187; // 30% APR
    uint256 _maxInterest = 12857214404; // 50% APR
    uint256 _vertexUtilization = UTIL_PREC * 4/5; // 80% utilization
    uint256 constant UTIL_PREC = 1e5;

    bytes linearRateData;

    function setUp() public {
        linearRateData = abi.encode(_minInterest,_vertexInterest, _maxInterest, _vertexUtilization);
        setCollaterals();
        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        bytes32  data;

        variableRateCalculator = (new VariableInterestRate());
        linearRateCalculator = (new LinearInterestRate());

        clabels.push(
            PoolInstrument.CollateralLabel(
                address(cash1),
                0
            )
        );
        clabels.push(
            PoolInstrument.CollateralLabel(
                address(nft1),
                1
            )
        );

        configs.push(
            PoolInstrument.Config(
            0,
            unit/2 + unit/10,
            unit/2,
            true,
            tau,
            cusp, // 50%
            tail,
            buf // 125%
            )
        );
        
        configs.push(
            PoolInstrument.Config(
            0,
            unit + unit/10,
            unit,
            false,
            tau,
            cusp, // 50%
            tail,
            buf // 125%
            )
        );
        marketmanager = new MarketManager(
            deployer,
            address(controller), 
            address(0),data, uint64(0)
        );
        ZCBFactory zcbfactory = new ZCBFactory(); 
        poolFactory = new SyntheticZCBPoolFactory(address(controller), address(zcbfactory)); 
        reputationManager = new ReputationManager(address(controller), address(marketmanager));

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
        controllerSetup();
    }

    function testAuction1() public {
        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _configs = configs;
        deployPoolInstrument(
            _clabels,
            _configs,
            vault_ad,
            0,
            deployer,
            address(linearRateCalculator),
            linearRateData
        );

        // poolInstrument.updateConfig(
        //     PoolInstrument.CollateralLabel(
        //         address(cash1),
        //         0
        //     ),
        //     PoolInstrument.Config(
        //         0,
        //         unit,
        //         unit,
        //         true,
        //         tau,
        //         cusp,
        //         tail,
        //         buf
        //     )
        // )

        vm.prank(toku);
        vm.expectRevert("!assetsAvailable");
        poolInstrument.borrow(unit, address(0), 0, 0, toku, false);

        vm.startPrank(vault_ad);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);

        // deposit 100 collateral.
        poolInstrument.deposit(100*unit, vault_ad);

        // toku setup
        changePrank(toku);
        cash1.faucet(1000*unit);
        cash1.approve(address(poolInstrument), type(uint256).max);
        
       //  logUserPoolState(poolInstrument, toku);


        assertTrue(poolInstrument._canBorrow(toku), "solvent");

        // add collateral and don't enable
        poolInstrument.addCollateral(address(cash1), 0, unit*10, toku, false);

        assertTrue(accountLiquidity(toku) == 0, "AL == 0");

        // trigger auction on yourself?
        vm.expectRevert("!liquidatable");
        poolInstrument.triggerAuction(toku, address(cash1), 0);

        // enable collateral
        poolInstrument.enableCollateral(address(cash1), 0);

        // logUserPoolState(poolInstrument, toku);
        // logPoolState(poolInstrument, true);
        
        changePrank(goku);
        vm.expectRevert("!liquidatable");
        poolInstrument.triggerAuction(toku, address(cash1), 0);

        assertTrue(accountLiquidity(toku) > 0, "AL > 0");

        changePrank(toku);
        // borrow the max amount
        poolInstrument.borrow(maxBorrowAmount * 10, address(0), 0, 0, toku, false);

        assertTrue(accountLiquidity(toku) >= 0, "AL >= 0");

        timeSkipLinear(uint256(accountLiquidity(toku)) + unit/20);

        logPoolState(poolInstrument, true);

        assertTrue(accountLiquidity(toku) < 0, "AL < 0");

        changePrank(goku);
        vm.expectRevert("!collateral_approved");
        poolInstrument.triggerAuction(toku, address(cash2), 0);

        vm.expectRevert("!liquidatable");
        poolInstrument.triggerAuction(miku, address(cash1), 0);
    }

    function testAuction2() public {
        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _configs = configs;
        deployPoolInstrument(
            _clabels,
            _configs,
            vault_ad,
            0,
            deployer,
            address(linearRateCalculator),
            linearRateData
        );

        vm.startPrank(vault_ad);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);
        poolInstrument.deposit(10*unit, vault_ad);


        // setup
        changePrank(toku);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);
        cash1.faucet(1000*unit);
        cash1.approve(address(poolInstrument), type(uint256).max);
        nft1.freeMint(toku, 1);
        nft1.approve(address(poolInstrument), 1);


        poolInstrument.addCollateral(
            address(cash1),
            0,
            unit,
            toku,
            true
        );
        poolInstrument.addCollateral(
            address(nft1),
            1,
            0,
            toku,
            true
        );

        assertTrue(uint256(accountLiquidity(toku)) == unit/2 + unit/10 + unit + unit/10, "AL ne");
        
        PoolInstrument.CollateralLabel[] memory collaterals = poolInstrument.getUserCollateral(toku);
        assertTrue(collaterals.length == 2, "collaterals.length ne");
        assertTrue(collaterals[0].tokenAddress == address(cash1), "collaterals[0].collateral ne");
        assertTrue(collaterals[1].tokenAddress == address(nft1), "collaterals[1].collateral ne");

        poolInstrument.borrow(
            poolInstrument.getMaxBorrow(toku),
            address(0),
            0,
            0,
            toku,
            false
        );

        assertTrue(accountLiquidity(toku) >= 0, "AL >= 0");
        logUserPoolState(poolInstrument, toku);

        timeSkipLinear(uint256(accountLiquidity(toku)) + unit / (10**7));
        poolInstrument.addInterest();
        // logPoolState(poolInstrument, true);
        assertTrue(accountLiquidity(toku) < 0, "AL < 0");

        changePrank(goku);

        // can trigger both auctions
        poolInstrument.triggerAuction(toku, address(cash1), 0);
        poolInstrument.triggerAuction(toku, address(nft1), 1);

        

        // can't trigger the same auction twice
        vm.expectRevert("!auction");
        poolInstrument.triggerAuction(toku, address(cash1), 0);
        vm.expectRevert("!auction");
        poolInstrument.triggerAuction(toku, address(nft1), 1);

        // user repays during the auction
        changePrank(toku);
        poolInstrument.repay(poolInstrument.userBorrowShares(toku), toku);

        assertTrue(accountLiquidity(toku) >= 0, "AL >= 0");

        assertTrue(auctioneer.getActiveUserAuctions(toku).length == 0, "no more auctions");
    }

    function twoAuctionSetup() public {
        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _configs = configs;
        deployPoolInstrument(
            _clabels,
            _configs,
            vault_ad,
            0,
            deployer,
            address(linearRateCalculator),
            linearRateData
        );

        vm.startPrank(vault_ad);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);
        poolInstrument.deposit(10*unit, vault_ad);


        // setup
        changePrank(toku);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);
        cash1.faucet(1000*unit);
        cash1.approve(address(poolInstrument), type(uint256).max);
        nft1.freeMint(toku, 1);
        nft1.approve(address(poolInstrument), 1);


        poolInstrument.addCollateral(
            address(cash1),
            0,
            unit,
            toku,
            true
        );
        poolInstrument.addCollateral(
            address(nft1),
            1,
            0,
            toku,
            true
        );

        assertTrue(uint256(accountLiquidity(toku)) == unit/2 + unit/10 + unit + unit/10, "AL ne");
        
        PoolInstrument.CollateralLabel[] memory collaterals = poolInstrument.getUserCollateral(toku);
        assertTrue(collaterals.length == 2, "collaterals.length ne");
        assertTrue(collaterals[0].tokenAddress == address(cash1), "collaterals[0].collateral ne");
        assertTrue(collaterals[1].tokenAddress == address(nft1), "collaterals[1].collateral ne");

        poolInstrument.borrow(
            poolInstrument.getMaxBorrow(toku),
            address(0),
            0,
            0,
            toku,
            false
        );

        assertTrue(accountLiquidity(toku) >= 0, "AL >= 0");

        timeSkipLinear(uint256(accountLiquidity(toku)) + unit / (10**7));
        poolInstrument.addInterest();
        // logPoolState(poolInstrument, true);
        assertTrue(accountLiquidity(toku) < 0, "AL < 0");

        changePrank(goku);

        // can trigger both auctions
        poolInstrument.triggerAuction(toku, address(cash1), 0);
        poolInstrument.triggerAuction(toku, address(nft1), 1);

        vm.stopPrank();
    }

    function testAuction4() public {
        twoAuctionSetup();

        Auctioneer.Auction memory auction = auctioneer.getAuctionWithId(auctioneer.computeAuctionId(toku, address(cash1), 0));
        PoolInstrument.Config memory config = poolInstrument.getCollateralConfig(poolInstrument.computeId(address(cash1), 0));
        assertTrue(auction.alive, "auction alive");

        uint256 top = auctioneer.purchasePrice(toku, address(cash1), 0);
        assertTrue(top == config.buf.mulWadDown(config.maxAmount));

        vm.startPrank(goku);
        collateral.faucet(10000*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);
        bytes32 cash1Id = poolInstrument.computeId(address(cash1), 0);
        bytes32 nft1Id = poolInstrument.computeId(address(nft1), 1);

        // logUserPoolState(poolInstrument, toku);

        // full purchase + makes solvent.
        uint256 amount = poolInstrument.purchaseCollateral(
            toku,
            PoolInstrument.CollateralLabel(
                address(cash1),
                0
            ),
            poolInstrument.userERC20s(cash1Id, toku)
        );

        // logUserPoolState(poolInstrument, toku);

        assertTrue(auctioneer.getActiveUserAuctions(toku).length == 0, "no more auctions");
    }

    

    function logUserAuctionState(address borrower) public {
        bytes32[] memory auctionIds = auctioneer.getActiveUserAuctions(borrower);

        for (uint256 i=0; i < auctionIds.length; i++) {
            Auctioneer.Auction memory auction = auctioneer.getAuctionWithId(auctionIds[i]);
            console.log("collateral: ", auction.collateral);
            console.log("tokenId: ", auction.tokenId);
            console.log("creationTimestamp: ", auction.creationTimestamp);
            console.log("alive: ", auction.alive);
        }
    }

    function accountLiquidity(address _user) public returns (int256 _userAccountLiquidity) {
        (
            ,
            ,
            ,
            ,
            _userAccountLiquidity,
            
        ) = poolInstrument.getUserSnapshot(_user);
    }

    /**
     fxn for getting the amount of time needed to skip given the interest you want to accrue + current util rate.
     for linear interest rate 
     */
    function timeSkipLinear(uint256 interestAccrued) public {
        // abi.encode(uint64 _currentRatePerSec, uint256 _deltaTime, uint256 _utilization, uint256 _deltaBlocks)
        (uint256 borrowAmount, uint256 borrowShares) = poolInstrument.totalBorrow();
        (uint256 supplyAmount, uint256 supplyShares) = poolInstrument.totalAsset();
        uint256 utilizationRate = (UTIL_PREC * borrowAmount) / supplyAmount;
        bytes memory data = abi.encode(uint64(0), uint256(0), utilizationRate, uint256(0));
        uint256 ratePerSec = linearRateCalculator.getNewRate(data,linearRateData);
        // (uint64 lastBlock,
        // uint64 lastTimestamp,
        // uint64 ratePerSec) = poolInstrument.currentRateInfo();
        
        // _interestEarned = (_deltaTime * _totalBorrow.amount * _currentRateInfo.ratePerSec) / 1e18;

        uint256 deltaTime = interestAccrued * (10**18) /  ratePerSec / borrowAmount;

        skip(deltaTime);
    }

    function logPoolState(PoolInstrument _pool, bool accrue) public {
        console.log("POOL STATE BEGIN");


        if (accrue) {
            (
                uint256 _interestEarned,
                uint256 _feesAmount,
                uint256 _feesShare,
                uint64 _newRate
            ) = _pool.addInterest();
            console.log("interestEarned: ", _interestEarned);
            console.log("feesAmount: ", _feesAmount);
            console.log("feesShare: ", _feesShare);
            console.log("newRate: ", _newRate);
        }

        (uint256 borrowAmount, uint256 borrowShares) = _pool.totalBorrow();
        (uint256 supplyAmount, uint256 supplyShares) = _pool.totalAsset();

        console.log("total borrow amount: ", borrowAmount);
        console.log("total borrow shares: ", borrowShares);
        console.log("total supply amount: ", supplyAmount);
        console.log("total supply shares: ", supplyShares);
        uint256 _utilizationRate = supplyAmount == 0 ? 0 : (UTIL_PREC * borrowAmount) / supplyAmount;
        console.log("utilization rate: ", _utilizationRate);
        console.log("POOL STATE END");  
        console.log("\n");
    }

    function logUserPoolState(PoolInstrument _pool, address _user) public {
        // what do you want otl user borrow shares/amount, isliquidatable + maxBorrow + canBorrow
        (
            uint256 _userAssetShares,
            uint256 _userAssetAmount,
            uint256 _userBorrowShares,
            uint256 _userBorrowAmount,
            int256 _userAccountLiquidity,
            PoolInstrument.CollateralLabel[] memory _userCollateral
        ) = _pool.getUserSnapshot(_user);

        console.log("USER POOL STATE BEGIN");
        console.log("user asset shares: ", _userAssetShares);
        console.log("user asset amount: ", _userAssetAmount);
        console.log("user borrow shares: ", _userBorrowShares);
        console.log("user borrow amount: ", _userBorrowAmount);
        console.log("account liq:");
        console.logInt(_userAccountLiquidity);

        console.log("user collateral: ");
        for (uint i = 0; i < _userCollateral.length; i++) {
            console.log("collateral: ", _userCollateral[i].tokenAddress);
            console.log("collateral id: ", _userCollateral[i].tokenId);
            bytes32 id = _pool.computeId(_userCollateral[i].tokenAddress, _userCollateral[i].tokenId);
            (,,,bool isERC20,,,,) = _pool.collateralConfigs(id);
            if (isERC20) {
                console.log("collateral balance: ", _pool.userERC20s(id, _user));
            } else {
                console.log("collateral balance: ", _pool.userERC721s(id));
            }
        }

        console.log("USER POOL STATE END");
        console.log("\n");
    }

    function logDec(uint256 _amount) public {
        console.log("amount: ", _amount / (10**18));
    }
}