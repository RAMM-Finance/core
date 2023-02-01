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


contract PoolInstrumentTest is CustomTestBase {

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

    address variableRateCalculator;
    address linearRateCalculator;

    uint256 _minInterest = 0;
    uint256 _vertexInterest = 8319516187; // 30% APR
    uint256 _maxInterest = 12857214404; // 50% APR
    uint256 _vertexUtilization = UTIL_PREC * 4/5; // 80% utilization
    uint256 constant UTIL_PREC = 1e5;

    bytes rateData;

    function setUp() public {
        rateData = abi.encode(_minInterest,_vertexInterest, _maxInterest, _vertexUtilization);
        setCollaterals();
        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        bytes32  data;

        variableRateCalculator = address(new VariableInterestRate());
        linearRateCalculator = address(new LinearInterestRate());

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
            maxAmount,
            maxBorrowAmount,
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
            maxAmount,
            maxBorrowAmount,
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

    function testAuction() public {
        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _configs = configs;
        deployPoolInstrument(
            _clabels,
            _configs,
            vault_ad,
            0,
            deployer,
            linearRateCalculator,
            rateData
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

        vm.startPrank(vault_ad);
        collateral.faucet(10*unit);
        collateral.approve(address(poolInstrument), type(uint256).max);

        logPoolState(poolInstrument);
        
        // 100 units of collateral deposited
        poolInstrument.deposit(unit*10, vault_ad);

        logPoolState(poolInstrument);

        changePrank(toku);
        cash1.faucet(1000*unit);
        cash1.approve(address(poolInstrument), type(uint256).max);
        
        logUserPoolState(poolInstrument, toku);
        poolInstrument.borrow(
            unit*5, // 50% utilization
            address(cash1),
            0,
            unit*10,
            address(toku),
            true
        );
        logUserPoolState(poolInstrument, toku);
        logPoolState(poolInstrument);


        // what do you want to test?
        // 1. I want to create an auction and see if it works
        // define work
        // well ig the auction should properly terminate, ability to reset, instant settement
        // you should also adjust the loan parmaeters to see what happens in extreme scenarios
        // well what is the base case?
        // base case would be that the buyer can buy the collateral and then the borrower is no longer insolvent.
        // need to make it easy to manipulate the borrowers shares + amount + collateral.

        // toku will be the borrower, goku will be the liquidator.
    }

    function logPoolState(PoolInstrument _pool) public {
        console.log("POOL STATE BEGIN");
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
}