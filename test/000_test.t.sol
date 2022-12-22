pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Controller} from "contracts/protocol/controller.sol";
import {ReputationManager} from "contracts/protocol/reputationmanager.sol";

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
    ReputationManager reputationManager;

    function setUp() public {
        controller = new Controller(deployer, address(0));
        reputationManager = new ReputationManager(address(controller), msg.sender);
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
        reputationManager.incrementScore(jonna, 10);
        reputationManager.incrementScore(jott, 20);
        reputationManager.incrementScore(gatdang, 30);
        reputationManager.incrementScore(goku, 40);
        reputationManager.incrementScore(toku, 50);
        reputationManager.incrementScore(miku, 60);
        reputationManager.incrementScore(chris, 70);
        reputationManager.incrementScore(sybal, 80);
        reputationManager.incrementScore(zeke, 90);
        reputationManager.incrementScore(jeong, 100);
        
    }

    function testIncrementDecrement() public {
        reputationManager.incrementScore(jonna, 10);
        reputationManager.incrementScore(jott, 20);
        reputationManager.incrementScore(gatdang, 15);
        reputationManager.decrementScore(jonna, 5);

        // jott - 20, gatdang - 15, jonna - 5;
        assertEq(reputationManager.traders(0), jott);
        assertEq(reputationManager.traders(1), gatdang);
        assertEq(reputationManager.traders(2), jonna);   

        reputationManager.incrementScore(jonna, 20);
        assertEq(reputationManager.traders(0), jonna);
        assertEq(reputationManager.traders(1), jott);
        assertEq(reputationManager.traders(2), gatdang);

        reputationManager.decrementScore(jonna, 30);
        assertEq(reputationManager.traders(0), jott);
        assertEq(reputationManager.traders(1), gatdang);
        assertEq(reputationManager.traders(2), jonna);  

        reputationManager.incrementScore(jonna, 17);
        assertEq(reputationManager.traders(0), jott);
        assertEq(reputationManager.traders(1), jonna);
        assertEq(reputationManager.traders(2), gatdang);

        reputationManager.decrementScore(jott, 4);
        assertEq(reputationManager.traders(0), jonna);
        assertEq(reputationManager.traders(1), jott);
        assertEq(reputationManager.traders(2), gatdang);
    }

    function testReputable() public {
        addUsers();

        assertEq(reputationManager.isReputable(jeong, 90*W), true);
        assertEq(reputationManager.isReputable(zeke, 50*W), true);
        assertEq(reputationManager.isReputable(goku, 0), true);

        assertEq(reputationManager.isReputable(jeong, 95*W), false);
    }

    function testMinRepScore() public {
        addUsers();
        assertEq(reputationManager.calculateMinScore(50*W), 60);
        assertEq(reputationManager.calculateMinScore(55*W), 60);
        assertEq(reputationManager.calculateMinScore(0), 0);
    }

    // function testSelectTraders() public {
    //     addUsers();
    //     address[] memory vals = controller.filterTraders(40*1e18, address(0));
    //     console.log("length: ", vals.length);

    //     vals = controller.filterTraders(90*1e18, address(0));
    //     console.log("length: ", vals.length);
    // }
}