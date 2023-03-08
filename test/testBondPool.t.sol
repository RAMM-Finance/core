pragma solidity ^0.8.16;
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {SyntheticZCBPool} from "../contracts/bonds/bondPool.sol";
import {CustomTestBase} from "./testbase.sol";
import "../contracts/global/types.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import {ZCBFactory, SyntheticZCBPoolFactory} from "../contracts/protocol/factories.sol";

contract SyntheticZCBPoolUnitTest is TestBase {

    SyntheticZCBPool pool;
    ZCBFactory zcbFactory;
    SyntheticZCBPoolFactory poolFactory;

    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    Cash base;

    function setUp() public {
        vm.startPrank(deployer);
        base = new Cash("base", "base", 18);
        zcbFactory = new ZCBFactory();
        poolFactory = new SyntheticZCBPoolFactory(deployer, address(zcbFactory));
        poolFactory.newPool(address(base), deployer);
        vm.stopPrank();
    }

    // function testSetUp() public {
    //     vm.startPrank(deployer);
    //     base = new Cash("base", "base", 18);
    //     zcbFactory = new ZCBFactory();
    //     poolFactory = new SyntheticZCBPoolFactory(deployer, address(zcbFactory));
    //     poolFactory.newPool(address(base), deployer);
    //     vm.stopPrank();
    // }

    function testCalculateInitCurveParams(uint256 P, uint256 I) public {

    }
}