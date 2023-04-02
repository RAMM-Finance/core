pragma solidity ^0.8.16;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Controller} from "../contracts/protocol/controller.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {CustomTestBase} from "./testbase.sol";
import {Vault} from "../contracts/vaults/vault.sol";
import "../contracts/global/types.sol";
import {ReputationManager} from "../contracts/protocol/reputationmanager.sol";
// import {CreditLine} from "../contracts/vaults/instrument.sol";
import {SyntheticZCBPool} from "../contracts/bonds/bondPool.sol";

// integration tests for all things assessment.
contract TestAssessment is CustomTestBase {
    
    Vault vault;

    MarketManager MM;
    ReputationManager RM;
    bytes constant ZERO_BYTES = new bytes(0);

    function setUp() public {
        deploySetUps();
        setUsers();
        controllerSetup();

        vault = Vault(controller.createVault(
            address(collateral),
            false,
            0,
            type(uint256).max,
            type(uint256).max,
            MarketParameters(N, sigma, alpha, omega, delta, r, s, steak),
            "description"
        ));
        
        MM = marketmanager;
        RM = reputationManager;
    }


    // function test_fixed_buyBondAssessment(uint256 amountIn, uint256 principal, uint256 yield) public {
    //     principal = bound(principal, 1e6, type(uint256).max / 3 * 2); // principal + principal/2 < type(uint256).max
    //     yield = bound(yield, principal/1e5, principal/2);
    //     amountIn = bound(amountIn, 0, principal);
    //     vm.assume(type(uint256).max > principal + yield);

    //     amountIn = constrictToRange(amountIn, 0, principal);

    //     console.log(
    //         "amountIn: %s, principal: %s, yield: %s", amountIn, principal, yield
    //     );
        
    //     address creditline = createCreditlineInstrument(
    //         1,
    //         principal,
    //         yield,
    //         duration
    //     );
    //     // console.log("faceValue: %s", CreditLine(creditline).faceValue());

    //     uint256 marketId = makeCreditlineMarket(
    //         creditline,
    //         1
    //     );

    //     vm.prank(manager1);

    //     MM.buyBond(marketId, int256(amountIn), 0, ZERO_BYTES);

    //     ReputationManager.RepLog memory repLog = RM.getRepLog(manager1, marketId);

    //     ERC20 underlying = vault.UNDERLYING();
    //     uint256 bp_bal = underlying.balanceOf(getBondPool(marketId));
        
    //     assertEq(amountIn, bp_bal, "amountIn === balanceOf(bp)");

    // }

    function getBondPool(uint256 marketId) public returns (address) {
        CoreMarketData memory m = Data.getMarket(marketId);
        return address(m.bondPool);
    }
}
