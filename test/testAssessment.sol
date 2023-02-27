pragma solidity ^0.8.16;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Controller} from "../contracts/protocol/controller.sol";
import {CustomTestBase} from "./testbase.sol"; 

// integration tests for all things assessment.
contract TestAssessment is CustomTestBase {

    /**
        tests:
        create market, fuzz different parameters and then buyBond + test leverageBuys.
        Fixed vs. Perps.
     */

     function setUp() public {
        deploySetUps();
        
     }
}