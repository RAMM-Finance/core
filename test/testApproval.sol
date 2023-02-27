pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
// import {ReputationNFT} from "../contracts/protocol/reputationtoken.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {CreditLine, MockBorrowerContract} from "../contracts/vaults/instrument.sol";
import {LinearCurve} from "../contracts/bonds/GBC.sol";
import {FixedPointMath} from "../contracts/bonds/libraries.sol";
import {CoveredCallOTC} from "../contracts/vaults/dov.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SimpleNFTPool} from "../contracts/vaults/nftLending.sol";
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
import {CustomTestBase} from "./testbase.sol";
import "../contracts/global/types.sol";

contract ApprovalTest is CustomTestBase {
    using FixedPointMath for uint256;
    using stdStorage for StdStorage;

    function setUp() public {
        vm.startPrank(deployer);
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

        leverageManager = new LeverageManager(address(controller), address(marketmanager), address(reputationManager));
        Data = new StorageHandler();
        vm.stopPrank();
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

        // initiateLendingPool(vault_ad);
        doInvest(vault_ad,  toku, 1e18*10000);

    }



    /// @notice checks whether correct amount is supplied when perp is approved
    function testPerpApprovalVaultSupply(
        uint256 multiplier,
        uint32 saleAmount,
        uint32 initPrice,
        uint32 promisedReturn,
        uint32 inceptionPrice,
        uint32 leverageFactor,
        uint32 amountToBuy
    ) public {
        testVars1 memory vars = createLendingPoolAndPricer(
            multiplier,
            saleAmount,
            initPrice,
            promisedReturn,
            inceptionPrice,
            leverageFactor
        );

        uint256 amountToBuy = constrictToRange(
            fuzzput(amountToBuy, 1e14),
            vars.saleAmount,
            vars.saleAmount * 5
        );
        vm.assume(
            amountToBuy <= marketmanager.getTraderBudget(vars.marketId, jonna)
        );

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(
            vars.vault_ad
        );
        doApproveFromStart(vars.marketId, amountToBuy);
        console.log(
            "wtf",
            vars.cbalnow,
            Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad)
        );

        // Vault balance from approval differs by this much
        assertApproxEqBasis(
            vars.cbalnow -
                Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad),
            (Data.getMarket(vars.marketId).longZCB.totalSupply())
                .mulWadDown(vars.leverageFactor)
                .mulWadDown(vars.inceptionPrice) +
                Data.getInstrumentData(vars.marketId).poolData.managementFee,
            1000
        );
    }

    //function testFixedApprovalVaultSupply()
}

// contract UtilizerCycle is FullCycleTest{

// }
