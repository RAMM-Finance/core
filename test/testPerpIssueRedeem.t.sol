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
import "../contracts/global/types.sol"; 

contract IssueRedeemTest is CustomTestBase {
    using FixedPointMath for uint256; 
    using stdStorage for StdStorage; 

  
    function setUp() public {

        deploySetUps(); 

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

        // initiateLendingPool(vault_ad); 
        doInvest(vault_ad,  toku, 1e18*100000); 
    }

    /// @notice checks if issueing supplies to instruments, or withdraws from instruments
    /// by correct amount 
    function testUnitIssueFuzz(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 amountToIssue
        ) public returns(testVars1 memory){


        testVars1 memory vars = createLendingPoolAndPricer(
         multiplier, 

         saleAmount, 
         initPrice,
         promisedReturn, 
         inceptionPrice, 
         leverageFactor
        ); 

        uint amountToBuy = constrictToRange(fuzzput(amountToBuy, 1e14), vars.saleAmount, vars.saleAmount*5 ); 
        uint amountToIssue = constrictToRange(fuzzput(amountToIssue, 1e14), 1e12, vars.saleAmount*5 ); 

        vm.assume(amountToBuy <= marketmanager.getTraderBudget(vars.marketId, jonna)); 
        vm.assume(amountToIssue <= marketmanager.getTraderBudget(vars.marketId, jonna)); 

        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        doApproveFromStart(vars.marketId, amountToBuy); 

        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);  
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        uint zcbbalbefore = Data.getMarket(vars.marketId).longZCB.balanceOf(jonna);
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;

        vm.prank(jonna);
        marketmanager.issuePoolBond(vars.marketId, amountToIssue);

        // check vault exchange rate same
        assertEq( vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 

        // check instrument exchange rate same 
        assertEq(vars.rateBefore, ERC4626(instrument).previewMint(1e18)); 

        // check vault bal decrease is function of issueAmount and lev factor 
        console.log('senioramounthere', vars.pju, vars.psu, 
            (amountToIssue.divWadUp(vars.pju)).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu)); 
        assertApproxEqAbs(vars.cbalnow - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad), 
            (amountToIssue.divWadUp(vars.pju)).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu), 
            100); 

        // check vault correctly supplied to instrument; 
        // vault bal decrease + issueAmount = instrument increase
        assertApproxEqAbs(
            vars.cbalnow - Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) 
                + amountToIssue,  
            Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument)
              - vars.cbalnow2, 
            100
        ) ; 

        // Check correct amount minted 
        assertEq(Data.getMarket(vars.marketId).longZCB.balanceOf(jonna) - zcbbalbefore, 
            amountToIssue.divWadUp(vars.pju)); 

        // check psu pju same
        (uint psu, uint pju, ) = Data.viewCurrentPricing(vars.marketId) ;
        assertApproxEqAbs(pju, vars.pju, 10); 
        assertEq(psu, vars.psu); 

        vars.amountToIssue = amountToIssue; 
        return vars; 
    }

    /// @notice trader issues and redeems certain amount 
    /// checks if correct amount is withdrawn 
    function testUnitRedeemFuzz(
        uint256 multiplier, 

        uint32 saleAmount, 
        uint32 initPrice,
        uint32 promisedReturn, 
        uint32 inceptionPrice, 
        uint32 leverageFactor, 

        uint32 amountToBuy, 
        uint32 amountToIssue, 
        uint32 amountToRedeem
        ) public {

        testVars1 memory vars = testUnitIssueFuzz(
             multiplier, 

             saleAmount, 
             initPrice,
             promisedReturn, 
             inceptionPrice, 
             leverageFactor, 

             amountToBuy, 
             amountToIssue
            ); 

        uint amountToRedeem = constrictToRange(fuzzput(amountToBuy, 1e14), 0, vars.amountToIssue.divWadUp(vars.pju)); 

        address instrument = Data.getInstrumentData(vars.marketId).instrument_address; 
        vars.ratebefore = Vault(vars.vault_ad).previewMint(1e18); 
        vars.rateBefore = ERC4626(instrument).previewMint(1e18);  
        vars.cbalnow = Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad); 
        vars.cbalnow2 = Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument); 
        uint zcbbalbefore = Data.getMarket(vars.marketId).longZCB.balanceOf(jonna);
        (vars.psu, vars.pju, ) = Data.viewCurrentPricing(vars.marketId) ;

        vm.prank(jonna); 
        marketmanager.redeemPoolLongZCB(vars.marketId, amountToRedeem);

        // check vault exchange rate same
        assertEq( vars.ratebefore, Vault(vars.vault_ad).previewMint(1e18)); 

        // check instrument exchange rate same 
        assertEq(vars.rateBefore, ERC4626(instrument).previewMint(1e18)); 

        // check vault bal increase is function of issueAmount and lev factor 
        assertApproxEqAbs(Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) - vars.cbalnow, 
            (amountToRedeem).mulWadDown(vars.leverageFactor).mulWadDown(vars.psu), 
            100); 

        // check vault correctly withdrawn from instrument; 
        // vault bal increase + redeemAmount = instrument decrease 
        assertApproxEqAbs(
            Vault(vars.vault_ad).UNDERLYING().balanceOf(vars.vault_ad) -vars.cbalnow 
                + amountToRedeem.mulWadDown(vars.pju),  
            vars.cbalnow2 - Vault(vars.vault_ad).UNDERLYING().balanceOf(instrument), 
            100
        ) ; 


    }

    // ///  @notice check if can be continuously supplied and withdrawn by x people 
    // function testIssueRedeemOver() public{

    // }

        // redeem cases: x people issue and redeem, 

  

  

}


