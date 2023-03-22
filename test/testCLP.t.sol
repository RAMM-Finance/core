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

// TODO test with collateral that is not 18.
contract PoolInstrumentTest is CustomTestBase {
    using FixedPointMath for uint256;
    using stdStorage for StdStorage;


    uint256 totalCollateral;

    // auction parameters

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
            0,
            maxDiscount,
            buf
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
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
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
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        collateralAmount = bound(collateralAmount, 1, type(uint256).max / maxBorrow);
        bytes32 cash1Id = poolInstrument.computeId(address(cash1), 0);
        vm.startPrank(borrower1);
        cash1.faucet(collateralAmount);
        poolInstrument.addCollateral(address(cash1), 0, collateralAmount, borrower1);

        poolInstrument.removeCollateral(address(cash1), 0, collateralAmount, borrower1);

        assertTrue(poolInstrument.totalCollateral(cash1Id) == 0, "total collateral equality");
        assertTrue(poolInstrument.userCollateralBalances(borrower1, cash1Id) == 0, "user balance equality");
        assertTrue(poolInstrument.userMaxBorrowCapacity(borrower1) == 0, "user max borrow");
        assertTrue(poolInstrument.getUserCollaterals(borrower1).length == 0, "active collateral");
        assertTrue(!poolInstrument.userCollateralBool(borrower1, cash1Id), "user collateral bool");
    }

    function test_unit_borrow(uint256 collateralAmount, uint256 borrowAmount) public {
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        
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
                (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        
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
        (uint256 maxBorrow_i,uint256 maxAmount_i,,,,,,) = poolInstrument.config();

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

        (uint256 maxBorrow_f, uint256 maxAmount_f, uint256 step, uint256 lowerUtil, uint256 upperUtil,,,) = poolInstrument.config();
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

    // invariants to test: totalCollateral, totalAssetAvailable, userCollateralBalances, userBorrowShares, 
    struct LiqInvars {
        uint256 TCollateral_i;
        uint256 TAssetAvailable_i;
        uint256 uCollateralBalance_i;
        uint256 uBorrowShares_i;
        uint128 TBorrowAmount_i;
        uint128 TBorrowShares_i;
        uint128 TAssetAmount_i;
        uint128 TAssetShares_i;
        uint256 debt_i;
        uint256 maxDebt_i;

        uint256 TCollateral_f;
        uint256 TAssetAvailable_f;
        uint256 uCollateralBalance_f;
        uint256 uBorrowShares_f;
        uint128 TBorrowAmount_f;
        uint128 TBorrowShares_f;
        uint128 TAssetAmount_f;
        uint128 TAssetShares_f;
        uint256 debt_f;
        uint256 maxDebt_f;
    }

    function test_unit_liquidateERC20_closePosition(uint256 collateralAmount, uint256 maxDebt) public {
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        
        collateralAmount = bound(collateralAmount, 1e8, type(uint128).max / maxBorrow);
        
        uint256 borrowAmount = (maxBorrow * collateralAmount / 1e18);
        bytes32 id = poolInstrument.computeId(address(cash1), 0);
        // uint256 borrowAmount = userMaxBorrowable;

        maxDebt = bound(maxDebt, borrowAmount/16, borrowAmount);

        vm.startPrank(deployer);
        collateral.faucet(borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(borrowAmount, deployer);
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

        // (,,uint256 utilRate) = poolInstrument.borrowRateInfo();
        // assertTrue(UTIL_PREC == utilRate, "util1"); // utilization rate of 100%.

        uint256 newMaxAmount = maxDebt.mulDivDown(1e18, collateralAmount);
        uint256 newMaxBorrow = newMaxAmount * 4 / 5;


        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(0)
        .checked_write(newMaxBorrow);

        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(1)
        .checked_write(newMaxAmount);

        
        uint256 totalAsset_i = poolInstrument.totalAssets();
        assertTrue(poolInstrument.isLiquidatable(borrower1), "liq");
        (uint256 debt_i, uint256 maxDebt_f) = poolInstrument.userAccountLiquidity(borrower1);
        assertApproxEqAbs(debt_i, borrowAmount, 4e2);
        assertApproxEqAbs(maxDebt_f, maxDebt, 4e2);
        
        // repay the debt
        vm.startPrank(deployer);

        (uint256 repayLimit, uint256 discount) = poolInstrument.computeLiqOpp(borrower1, address(cash1), 0);

        logDec("repayLimit", repayLimit, 18);

        // repayAmount = bound(repayAmount, 1, borrowAmount);

        assertTrue(repayLimit <= debt_i, "repayLimit");
        collateral.approve(address(poolInstrument), type(uint128).max);
        collateral.faucet(repayLimit);

        // close out the position
        poolInstrument.liquidateERC20(borrower1, address(cash1), repayLimit);

        // (uint256 debt_f,) = poolInstrument.userAccountLiquidity(borrower1);

        assertTrue(poolInstrument.userBorrowShares(borrower1) == uint256(0),"!closed");
        logDec("userBorrowShares", poolInstrument.userBorrowShares(borrower1), 18);
        assertTrue(poolInstrument.userCollateralBalances(borrower1, id) == 0, "0 user collateral");
        logDec("userCollateralBalances", poolInstrument.userCollateralBalances(borrower1, id), 18);
        assertTrue(poolInstrument.totalCollateral(id) == 0, "0 total collateral");
        logDec("totalCollateral", poolInstrument.totalCollateral(id), 18);
        assertTrue(poolInstrument.totalAssetAvailable() == (repayLimit), "totalAssetAvailable");
        (uint128 TborrowAmount, uint128 TborrowShares) = poolInstrument.totalBorrow();

        assertTrue(TborrowAmount == 0, "0 TborrowAmount");
        logDec("TborrowAmount", TborrowAmount, 18);
        assertTrue(TborrowShares == 0, "0 TborrowShares");
        logDec("TborrowShares", TborrowShares, 18);

        // if bad debt then total asset should be less than before
        if (repayLimit < debt_i) {
            assertTrue(totalAsset_i - (debt_i - repayLimit) == poolInstrument.totalAssets(), "bad debt");
        }
    }

    function test_unit_liquidateERC20_variableRepay(uint256 collateralAmount, uint256 maxDebt, uint256 repayAmount) public {
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        LiqInvars memory iv;
        
        collateralAmount = bound(collateralAmount, 1e8, type(uint128).max / maxBorrow);
        
        bytes32 id = poolInstrument.computeId(address(cash1), 0);
        uint256 borrowAmount = (maxBorrow * collateralAmount / 1e18);

        // uint256 borrowAmount = userMaxBorrowable;

        maxDebt = bound(maxDebt, borrowAmount/16, borrowAmount);

        vm.startPrank(deployer);
        collateral.faucet(borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(borrowAmount, deployer);
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

        // (,,uint256 utilRate) = poolInstrument.borrowRateInfo();
        // assertTrue(UTIL_PREC == utilRate, "util1"); // utilization rate of 100%.

        uint256 newMaxAmount = maxDebt.mulDivDown(1e18, collateralAmount);
        uint256 newMaxBorrow = newMaxAmount * 4 / 5;


        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(0)
        .checked_write(newMaxBorrow);

        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(1)
        .checked_write(newMaxAmount);


        assertTrue(poolInstrument.isLiquidatable(borrower1), "liq");
        (iv.debt_i, iv.maxDebt_i) = poolInstrument.userAccountLiquidity(borrower1);
        assertApproxEqAbs(iv.debt_i, borrowAmount, 4e2, "debt");
        assertApproxEqAbs(iv.maxDebt_i, maxDebt, 4e2, "maxDebt");

        // repay the debt
        vm.startPrank(deployer);
        (uint256 repayLimit, uint256 discount) = poolInstrument.computeLiqOpp(borrower1, address(cash1), 0);

        uint256 repayAmount = bound(repayAmount, 1e4, repayLimit);

        iv.TAssetAvailable_i = poolInstrument.totalAssetAvailable();
        iv.uCollateralBalance_i = poolInstrument.userCollateralBalances(borrower1, id);
        iv.uBorrowShares_i = poolInstrument.userBorrowShares(borrower1);
        (iv.TBorrowAmount_i, iv.TBorrowShares_i) = poolInstrument.totalBorrow();
        (iv.TAssetAmount_i, iv.TAssetShares_i) = poolInstrument.totalAsset();
        iv.TCollateral_i = poolInstrument.totalCollateral(id);

        uint256 bSharesDelta = poolInstrument.toBorrowShares(repayAmount, false);

        /// LIQUIDATION ACTION vvv
        collateral.faucet(repayAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.liquidateERC20(borrower1, address(cash1), repayAmount);
        vm.stopPrank();
        /// LIQUIDATION ACTION ^^^

        iv.TAssetAvailable_f = poolInstrument.totalAssetAvailable();
        iv.uCollateralBalance_f = poolInstrument.userCollateralBalances(borrower1, id);
        iv.uBorrowShares_f = poolInstrument.userBorrowShares(borrower1);
        (iv.TBorrowAmount_f, iv.TBorrowShares_f) = poolInstrument.totalBorrow();
        (iv.TAssetAmount_f, iv.TAssetShares_f) = poolInstrument.totalAsset();
        iv.TCollateral_f = poolInstrument.totalCollateral(id);
        (iv.debt_f, iv.maxDebt_f) = poolInstrument.userAccountLiquidity(borrower1);

        uint256 d = cash1.decimals();

        uint256 collateralToLiquidator = repayLimit == repayAmount ? 
        iv.uCollateralBalance_i
        : repayAmount.mulDivDown(10 ** (18 + d), newMaxAmount * (unit - discount)).divWadDown(buf);
    
        // check all the invariants
        assertTrue(repayAmount == iv.TAssetAvailable_f, "total asset");
        assertApproxEqAbs(iv.uCollateralBalance_i - iv.uCollateralBalance_f, collateralToLiquidator, 1e4, "collateral");
        // logDec("collateralToLiquidator", collateralToLiquidator, d);
        // logDec("uCollateralBalance_i", iv.uCollateralBalance_i, d);
        // logDec("uCollateralBalance_f", iv.uCollateralBalance_f, d);
        if (repayAmount < repayLimit) {
            assertTrue(iv.TBorrowAmount_i - iv.TBorrowAmount_f == repayAmount, "borrow amount");
            logDec("TBorrowAmount_i", iv.TBorrowAmount_i, d);
            logDec("TBorrowAmount_f", iv.TBorrowAmount_f, d);
            logDec("repayAmount", repayAmount, d);
            assertTrue(iv.TBorrowShares_i - iv.TBorrowShares_f == bSharesDelta, "borrow shares");
            logDec("TBorrowShares_i", iv.TBorrowShares_i, d);
            logDec("TBorrowShares_f", iv.TBorrowShares_f, d);
            logDec("bSharesDelta", bSharesDelta, d);
        } else {
            assertTrue(iv.TBorrowAmount_f == 0, "borrow amount");
            assertTrue(iv.TBorrowShares_f == 0, "borrow shares");
        }

    }

    function test_unit_liquidateERC721(uint256 maxDebt) public {     
        (uint256 maxBorrow,,,,,,,) = poolInstrument.config();
        
        uint256 borrowAmount = (maxBorrow);
        bytes32 id = poolInstrument.computeId(address(cash1), 0);
        // uint256 borrowAmount = userMaxBorrowable;

        maxDebt = bound(maxDebt, borrowAmount/16, borrowAmount);

        vm.startPrank(deployer);
        collateral.faucet(borrowAmount);
        collateral.approve(address(poolInstrument), type(uint128).max);
        poolInstrument.deposit(borrowAmount, deployer);
        vm.stopPrank();

        vm.startPrank(borrower1);

        nft1.freeMint(borrower1, 1);
        nft1.approve(address(poolInstrument), 1);
        poolInstrument.borrow(
            borrowAmount,
            address(nft1),
            1,
            1,
            borrower1
        );
        vm.stopPrank();

        // (,,uint256 utilRate) = poolInstrument.borrowRateInfo();
        // assertTrue(UTIL_PREC == utilRate, "util1"); // utilization rate of 100%.

        uint256 newMaxAmount = maxDebt;
        uint256 newMaxBorrow = newMaxAmount * 4 / 5;


        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(0)
        .checked_write(newMaxBorrow);

        stdstore
        .target(address(poolInstrument))
        .sig("config()")
        .depth(1)
        .checked_write(newMaxAmount); 

        assertTrue(poolInstrument.isLiquidatable(borrower1), "liq");

        uint256 totalAsset_i = poolInstrument.totalAssets();
        (uint256 debt_i, uint256 maxDebt_f) = poolInstrument.userAccountLiquidity(borrower1);
        (,uint256 discount) = poolInstrument.computeLiqOpp(borrower1, address(nft1), 1);
        // repay the debt
        vm.startPrank(deployer);
        collateral.faucet(newMaxAmount.mulWadDown(unit - discount));
        collateral.approve(address(poolInstrument), type(uint256).max);
        poolInstrument.liquidateERC721(borrower1, address(nft1), 1);
        vm.stopPrank();

        assertTrue(poolInstrument.userBorrowShares(borrower1) == uint256(0),"!closed");
        assertTrue(poolInstrument.totalCollateral(id) == 0, "0 total collateral");
        assertTrue(poolInstrument.totalAssetAvailable() == (newMaxAmount.mulWadDown(unit - discount)), "totalAssetAvailable");
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
}