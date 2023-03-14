pragma solidity ^0.8.17;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
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
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {VaultAccount} from "../contracts/instruments/VaultAccount.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
// import {Auctioneer} from "../contracts/instruments/auctioneer.sol";


contract PoolInstrumentTest is CustomTestBase {
    using FixedPointMath for uint256;


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

    bytes linearRateData;

    function setUp() public {
        linearRateData = abi.encode(_minInterest,_vertexInterest, _maxInterest, _vertexUtilization);
        setCollaterals();
        // controller = new Controller(deployer); // zero addr for interep
        // vaultFactory = new VaultFactory(address(controller));
        bytes32 data;

        variableRateCalculator = (new VariableInterestRate());
        linearRateCalculator = (new LinearInterestRate());

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

        

        deploySetUps();
        controllerSetup(); 

        poolConfig = PoolInstrument.Config(
            unit,
            unit * 5 / 4,
            step,
            lowerUtil,
            upperUtil,
            0
        );

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

        poolInstrument = new PoolInstrument(
            vault_ad,
            address(reputationManager),
            address(utilizer1),
            address(linearRateCalculator),
            "Pool1",
            "P1",
            linearRateData,
            poolConfig,
            clabels
        );

        // borrower setup
        vm.startPrank(borrower1);
        cash1.approve(address(poolInstrument), type(uint256).max);
        vm.stopPrank();
    }

    function test_unit_addCollateral(uint256 collateralAmount) public {

        bytes32 cash1Id = poolInstrument.computeId(address(cash1), 0);
        vm.startPrank(borrower1);
        (uint256 maxBorrow,,,,,) = poolInstrument.config();
        collateralAmount = bound(collateralAmount, 1, type(uint256).max / maxBorrow);
        cash1.faucet(collateralAmount);
        cash1.approve(address(poolInstrument), type(uint256).max);

        poolInstrument.addCollateral(address(cash1), 0, collateralAmount, borrower1);
        assertTrue(poolInstrument.totalCollateral(cash1Id) == collateralAmount, "total collateral equality");
        assertTrue(poolInstrument.userCollateralBalances(borrower1, cash1Id) == collateralAmount, "user balance equality");
        assertTrue(poolInstrument.userMaxBorrowCapacity(borrower1) == collateralAmount * maxBorrow / 1e18, "user max borrow amount");
        assertTrue(poolInstrument.getUserCollaterals(borrower1).length == 1, "active collateral");
    }

    function test_unit_removeCollateral(uint256 collateralAmount) public {
        (uint256 maxBorrow,,,,,) = poolInstrument.config();
        collateralAmount = bound(collateralAmount, 1, type(uint256).max / maxBorrow);
        console.log("collateralAmount:", collateralAmount);
        bytes32 cash1Id = poolInstrument.computeId(address(cash1), 0);
        vm.startPrank(borrower1);
        cash1.faucet(collateralAmount);
        poolInstrument.addCollateral(address(cash1), 0, collateralAmount, borrower1);

        poolInstrument.removeCollateral(address(cash1), 0, collateralAmount, borrower1);

        assertTrue(poolInstrument.totalCollateral(cash1Id) == 0, "total collateral equality");
        assertTrue(poolInstrument.userCollateralBalances(borrower1, cash1Id) == 0, "user balance equality");
        assertTrue(poolInstrument.userMaxBorrowCapacity(borrower1) == 0, "user max borrow");
        assertTrue(poolInstrument.getUserCollaterals(borrower1).length == 0, "active collateral");
    }

    function test_unit_borrow(uint256 collateralAmount, uint256 borrowAmount) public {
        (uint256 maxBorrow,,,,,) = poolInstrument.config();
        
        collateralAmount = bound(collateralAmount, 1, type(uint128).max / maxBorrow);
        
        uint256 userMaxBorrowable = (maxBorrow * collateralAmount / 1e18);
        borrowAmount = bound(borrowAmount, 1, userMaxBorrowable);

        vm.startPrank(deployer);
        collateral.faucet(2*borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(2*borrowAmount, deployer);
        vm.stopPrank();

        vm.startPrank(borrower1);
        cash1.faucet(collateralAmount);
        poolInstrument.borrow(
            borrowAmount,
            address(cash1),
            0,
            collateralAmount,
            borrower1
        );
        vm.stopPrank();
        (uint256 debt,) = poolInstrument.userAccountLiquidity(borrower1);
        assertTrue(debt <= poolInstrument.userMaxBorrowCapacity(borrower1), "user health factor");
        assertTrue(poolInstrument.totalAssetAvailable() == borrowAmount, "asset in pool");
        assertTrue(poolInstrument.totalBorrowAmount() == borrowAmount, "asset in totalBorrow");
    }

    function test_unit_repay(uint256 collateralAmount, uint256 borrowAmount) public {
                (uint256 maxBorrow,,,,,) = poolInstrument.config();
        
        collateralAmount = bound(collateralAmount, 1, type(uint128).max / maxBorrow);
        
        uint256 userMaxBorrowable = (maxBorrow * collateralAmount / 1e18);
        borrowAmount = bound(borrowAmount, 1, userMaxBorrowable);

        vm.startPrank(deployer);
        collateral.faucet(2*borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(2*borrowAmount, deployer);
        vm.stopPrank();

        vm.startPrank(borrower1);
        cash1.faucet(collateralAmount);
        poolInstrument.borrow(
            borrowAmount,
            address(cash1),
            0,
            collateralAmount,
            borrower1
        );


        collateral.faucet(borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.repay(
            poolInstrument.toBorrowShares(borrowAmount, true),
            borrower1
        );

        (uint256 debt,) = poolInstrument.userAccountLiquidity(borrower1);
        assertTrue(debt == 0, "user health factor");
        assertTrue(poolInstrument.totalAssetAvailable() == 2*borrowAmount, "asset in pool");
        assertTrue(poolInstrument.totalBorrowAmount() == 0, "asset in totalBorrow");       
    }

    function test_unit_updateBorrowParams(uint256 supply1, uint256 borrow1) public {
        (uint256 maxBorrow_i,uint256 maxAmount_i,,,,) = poolInstrument.config();

        // can either vary the time or the rate
        // util1 -> util2, with an interval of time1.
        supply1 = bound(supply1, 1, type(uint128).max);
        borrow1 = bound(borrow1, 1, supply1);

        uint256 c = block.timestamp;

        vm.startPrank(deployer);
        cash1.faucet(borrow1 * 1e18 / maxBorrow_i);
        cash1.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.addCollateral(address(cash1), 0, (borrow1) * 1e18 / maxBorrow_i, deployer);
        console.log("userMaxBorrowCapacity:", poolInstrument.userMaxBorrowCapacity(deployer));
        assertTrue(poolInstrument.userMaxBorrowCapacity(deployer) == borrow1, "borrow1");
        collateral.faucet(supply1);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(supply1, deployer);
        poolInstrument.borrow(borrow1, address(0), 0, 0, deployer);
        vm.stopPrank();

        assertTrue(poolInstrument.getUtilizationRate() == borrow1 * 1e18 / (supply1), "util1");

        skip(2 days);

        poolInstrument.updateBorrowParameters();

        (uint256 maxBorrow_f, uint256 maxAmount_f, uint256 step, uint256 lowerUtil, uint256 upperUtil,) = poolInstrument.config();
        (uint64 lastBlock, uint64 lastTimestamp, uint256 lastUtilizationRate) = poolInstrument.borrowRateInfo();


        assertTrue(lastBlock == block.number, "lastBlock");
        assertTrue(lastTimestamp == block.timestamp, "lastTimestamp");
        assertTrue(lastUtilizationRate == borrow1 * 1e5 / (supply1), "lastUtilizationRate");
        
        // log the lastUtilizationRate and the argument in the equality
        console.log("lastUtilizationRate:", lastUtilizationRate, borrow1 * 1e5 / (supply1));

        if (lastUtilizationRate <= upperUtil && lastUtilizationRate >= lowerUtil) {
            assertTrue(maxBorrow_f == maxBorrow_i, "maxBorrow");
            assertTrue(maxAmount_f == maxAmount_i, "maxAmount");
        } else if (lastUtilizationRate > upperUtil) {
            assertTrue(maxBorrow_f == (unit - step).rpow(2 days, unit).mulWadDown(maxBorrow_i), "maxBorrow uabove");
            console.log("maxBorrow_f:", maxBorrow_f, (unit - step).rpow(2 days, unit).mulWadDown(maxBorrow_i));
            assertTrue(maxAmount_f == (unit - step).rpow(2 days, unit).mulWadDown(maxAmount_i), "maxAmount uabove");
            console.log("maxAmount_f:", maxAmount_f, (unit - step).rpow(2 days, unit).mulWadDown(maxAmount_i));
        } else if (lastUtilizationRate < lowerUtil) {
            assertTrue(maxBorrow_f == (unit + step).rpow(2 days, unit).mulWadDown(maxBorrow_i), "maxBorrow ubelow");
            assertTrue(maxAmount_f == (unit + step).rpow(2 days, unit).mulWadDown(maxAmount_i), "maxAmount ubelow");
        }
    }

    function test_unit_liquidateERC20() public {
        
    }

    function test_unit_liquidateERC721() public {

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

        console.log("USER POOL STATE END");
        console.log("\n");
    }

    function logDec(uint256 _amount) public {
        console.log("amount: ", _amount / (10**18));
    }
}