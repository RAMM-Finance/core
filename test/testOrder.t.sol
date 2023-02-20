pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol"; 
import {FixedPointMath} from "../contracts/bonds/libraries.sol"; 
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol"; 
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";

import {CustomTestBase} from "./testbase.sol";
import {LeverageManager} from "../contracts/protocol/leveragemanager.sol"; 
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
import {OrderManager} from "../contracts/protocol/ordermanager.sol";
import "../contracts/global/types.sol"; 

contract OrderTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

    PoolInstrument pool; 
    bytes initCallData;

    uint256 wad = 1e18;

    PoolInstrument.CollateralLabel[] clabels;
    PoolInstrument.Config[] collaterals;

    function setUp() public {

        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
        collateral = new Cash("n","n",18);
        collateral2 = new Cash("nn", "nn", 18); 
        bytes32  data;

        clabels.push(
            PoolInstrument.CollateralLabel(
                address(collateral),
                0
            )
        );
        collaterals.push(
            PoolInstrument.Config(
            0,
            wad/2,
            wad/4,
            true,
            0,0,0,0
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

        nftPool = new SimpleNFTPool(  vault_ad, toku, address(collateral)); 
        nftPool.setUtilizer(toku); 

        initiateSimpleNFTLendingPool(); 
        doInvest(vault_ad,  toku, 1e18*10000); 



        VariableInterestRate rateCalculator = new VariableInterestRate();

        PoolInstrument.CollateralLabel[] memory _clabels = clabels;
        PoolInstrument.Config[] memory _collaterals = collaterals;

        pool = new PoolInstrument(
            vault_ad,
            address(reputationManager), 
            0,
            deployer,
            "pool 1",
            "P1",
            address(rateCalculator),
            initCallData,
            _clabels,
            _collaterals
        );
               
        // vm.prank(a);
        pool.addAcceptedCollateral(
            vault_ad,
            0,
            PoolInstrument.Config(
            0,
            precision, 
            precision*9/10, 
            true,
            0,
            0,
            0,
            0)
        );      

    }
   

    // struct testVars1{
    //     uint256 marketId;
    //     address vault_ad; 
    //     uint amountToBuy; 
    //     uint curPrice; 

    //     uint amountIn;
    //     uint amountOut; 

    //     uint valamountIn; 
    //     uint cbalnow; 
    //     uint cbalnow2; 

    //     uint issueAmount; 
    //     uint orderId; 
    // }

    function submitOrder(
        testVars1 memory vars,
        address submitter, 
        uint amountIn, 
        bool isLong, 
        uint price) public returns(uint256){
        doApproveCol(address(orderManager), submitter); 
        vm.prank(submitter); 
        return orderManager.submitOrder(vars.marketId, amountIn, isLong, price);
    }

    function testSubmitOrder() public returns(testVars1 memory vars){
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 

        uint amountIn = 100e18; 
        bool isLong = true; 
        uint price = 8e17; 

        doApproveCol(address(orderManager), jonna);
        vars.valamountIn = amountIn.mulWadDown(price); 
        vm.prank(jonna); 
        vars.orderId = orderManager.submitOrder(vars.marketId, amountIn, isLong, price); 

        return vars; 
    }

    function testFillSingleOrder() public{
        testVars1 memory vars = testSubmitOrder(); 

        doApproveCol(address(orderManager), toku); 
        vars.cbalnow = Data.getMarket(vars.marketId).bondPool.baseToken().balanceOf(toku); 
        vm.prank(toku); 
        orderManager.fillCompleteSingleOrderMint(vars.marketId, vars.orderId);

        assertEq(Data.getMarket(vars.marketId).longZCB.balanceOf(jonna), 
            Data.getMarket(vars.marketId).shortZCB.balanceOf(toku)); 
        assertApproxEqAbs(vars.cbalnow - Data.getMarket(vars.marketId).bondPool.baseToken().balanceOf(toku)
            + vars.valamountIn, Data.getMarket(vars.marketId).longZCB.balanceOf(jonna), 10); 

    }

    function testFillMultipleOrder() public{
        testVars1 memory vars; 

        vars.marketId = controller.getMarketId(toku); 
        vars.vault_ad = controller.getVaultfromId(vars.marketId); 

        submitOrder(vars, jonna,100e18, true, 8e17 ); 
        submitOrder(vars, toku, 90e18, true, 8e17);
        submitOrder(vars, jonna, 100e18, true, 8e17); 

        uint fillAmount = 120e18; 

        vm.prank(jonna); 
        orderManager.fillMultipleOrders(vars.marketId, 8e17, fillAmount, true);

        // jonna is filled first
        assertEq(Data.getMarket(vars.marketId).longZCB.balanceOf(jonna), 100e18); 
        assertEq(Data.getMarket(vars.marketId).longZCB.balanceOf(toku), 20e18); 
        assertEq(Data.getMarket(vars.marketId).shortZCB.balanceOf(jonna), 120e18); 

    
    }







    

}


