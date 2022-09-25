pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "src/protocol/controller.sol";
import {MarketManager} from "src/protocol/marketmanager.sol";
import {ReputationNFT} from "src/protocol/reputationtoken.sol";
import {Cash} from "src/libraries/Cash.sol";
import {CreditLine} from "src/vaults/instrument.sol";

contract FullCycleTest is Test {
    // Controller controller;
    // MarketManager MM;
    // Cash collateral;
    // VaultFactory vaultFactory;
    // ReputationNFT repToken;
    // CreditLine instrument;
    
    // address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    // uint256 unit = 10**18; 

    // function setUp() public {

    //     controller = new Controller(deployer, address(0)); // zero addr for interep
    //     vaultFactory = new VaultFactory(address(controller));
    //     repToken = new ReputationNFT(address(controller));

    //     MM = new MarketManager(
    //         deployer,
    //         address(repToken),
    //         address(controller),
    //         address(0), // vrf coordinator
    //         bytes32(0), // key hash
    //         uint64(0) // subscription id
    //     );

    //     controller.setMarketManager(MM);
    //     controller.setVaultFactory(vaultFactory);
    //     controller.setReputationNFT(repToken);
    //     MarketManager.MarketParameters memory default_params;
        // controller.createVault(
        //     address(collateral),
        //     false,
        //     0,
        //     type(uint256).max,
        //     type(uint256).max,
        //     MarketManager.MarketParameters(
                
        //     )
        // );
    // }

    function testInitiateMarket() public {

    }
}