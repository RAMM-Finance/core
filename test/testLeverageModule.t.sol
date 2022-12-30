pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {SyntheticZCBPoolFactory, ZCBFactory} from "../contracts/bonds/synthetic.sol"; 
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";

import {CustomTestBase} from "./testbase.sol";
import {LeverageModule} from "../contracts/protocol/LeverageModule.sol"; 
import {PoolInstrument} from "../contracts/instruments/PoolInstrument.sol";
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";

contract LeverageModuleTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    PoolInstrument pool; 
    bytes initCallData;

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
        reputationManager = new ReputationManager(address(controller), address(marketmanager));

        vm.startPrank(deployer); 
        controller.setMarketManager(address(marketmanager));
        controller.setVaultFactory(address(vaultFactory));
        controller.setPoolFactory(address(poolFactory)); 
        controller.setReputationManager(address(reputationManager));
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

        nftPool = new SimpleNFTPool(  vault_ad, toku, address(collateral)); 
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        doInvest(vault_ad,  toku, 1e18*10000); 

        leverageModule = new LeverageModule(address(controller));

        VariableInterestRate rateCalculator = new VariableInterestRate();
        
        pool = new PoolInstrument(
            vault_ad,
            deployer,
            address(collateral),
            "pool 1",
            "P1",
            address(rateCalculator),
            initCallData
        );
        
        vm.prank(vault_ad);
        pool.addAcceptedCollateral(
            vault_ad,
            0,
            precision, 
            precision*9/10
        );

    }
   

    struct testVars1{
        uint256 marketId;
        address vault_ad; 
        uint amountToBuy; 
        uint curPrice; 

        uint amountIn;
        uint amountOut; 

        uint valamountIn; 
        uint cbalnow; 
        uint cbalnow2; 
    }


    function testMintWithLeverage() public{
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 

        uint poolCapital = 1000*precision; 
        uint suppliedCapital = 100*precision; 
        uint leverageFactor = 3*precision; 
    
        address leverageModule_ad = address(leverageModule); 
        vm.prank(jonna); 
        collateral.approve(leverageModule_ad, type(uint256).max); 
        doApproveCol(vars.vault_ad, jonna); 
        vm.prank(jonna); 
        Vault(vars.vault_ad).deposit(poolCapital, jonna); 

        doApproveCol(address(pool), vars.vault_ad); 
        vm.prank(vars.vault_ad);
        pool.deposit(1000*precision, vars.vault_ad); 

        leverageModule.addLeveragePool(1, address(pool));
        vm.prank(jonna); 
        leverageModule.mintWithLeverage(1, suppliedCapital, leverageFactor); 


    }

    //function testWithdraw
    //function testProfit

    

}


