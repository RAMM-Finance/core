pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Controller} from "contracts/protocol/controller.sol";

contract ReputationSystemTests is Test {
    Controller controller;
    address jonna;
    address jott; 
    address gatdang;
    address sybal; 
    address chris; 
    address miku;
    address tyson; 
    address yoku;
    address toku; 
    address goku;
    address zeke;
    address jeong;
    
    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    uint256 W = 1e18; 

    function setUp() public {
        controller = new Controller(deployer, address(0));
        jonna = address(0xbabe);
        vm.label(jonna, "jonna");
        jott = address(0xbabe2); 
        vm.label(jott, "jott");
        gatdang = address(0xbabe3); 
        vm.label(gatdang, "gatdang");
        sybal = address(0xbabe4);
        vm.label(sybal, "sybal");
        chris=address(0xbabe5);
        vm.label(chris, "chris");
        miku = address(0xbabe6);
        vm.label(miku, "miku");
        goku = address(0xbabe7); 
        vm.label(goku, "goku");
        toku = address(0xbabe8);
        vm.label(toku, "toku"); 
        zeke = address(0xbabe9);
        vm.label(zeke, "zeke");
        jeong = address(0xbabe10);
        vm.label(jeong, "jeong");

    }

    function addUsers() public {
        controller._incrementScore(jonna, 10);
        controller._incrementScore(jott, 20);
        controller._incrementScore(gatdang, 30);
        controller._incrementScore(goku, 40);
        controller._incrementScore(toku, 50);
        controller._incrementScore(miku, 60);
        controller._incrementScore(chris, 70);
        controller._incrementScore(sybal, 80);
        controller._incrementScore(zeke, 90);
        controller._incrementScore(jeong, 100);
        
    }

    function testIncrementDecrement() public {
        controller._incrementScore(jonna, 10);
        controller._incrementScore(jott, 20);
        controller._incrementScore(gatdang, 15);
        controller._decrementScore(jonna, 5);

        // jott - 20, gatdang - 15, jonna - 5;
        assertEq(controller.traders(0), jott);
        assertEq(controller.traders(1), gatdang);
        assertEq(controller.traders(2), jonna);   

        controller._incrementScore(jonna, 20);
        assertEq(controller.traders(0), jonna);
        assertEq(controller.traders(1), jott);
        assertEq(controller.traders(2), gatdang);

        controller._decrementScore(jonna, 30);
        assertEq(controller.traders(0), jott);
        assertEq(controller.traders(1), gatdang);
        assertEq(controller.traders(2), jonna);  

        controller._incrementScore(jonna, 17);
        assertEq(controller.traders(0), jott);
        assertEq(controller.traders(1), jonna);
        assertEq(controller.traders(2), gatdang);

        controller._decrementScore(jott, 4);
        assertEq(controller.traders(0), jonna);
        assertEq(controller.traders(1), jott);
        assertEq(controller.traders(2), gatdang);
    }

    function testReputable() public {
        addUsers();

        assertEq(controller.isReputable(jeong, 90*W), true);
        assertEq(controller.isReputable(zeke, 50*W), true);
        assertEq(controller.isReputable(goku, 30*W), true);

        assertEq(controller.isReputable(jeong, 95*W), false);
    }

    function testMinRepScore() public {
        addUsers();
        assertEq(controller.calculateMinScore(50*W), 60);
        assertEq(controller.calculateMinScore(55*W), 60);
        assertEq(controller.calculateMinScore(0), 0);
    }

    function testSelectTraders() public {
        addUsers();
        address[] memory vals = controller.filterTraders(40*1e18, address(0));
        console.log("length: ", vals.length);

        vals = controller.filterTraders(90*1e18, address(0));
        console.log("length: ", vals.length);
    }
}