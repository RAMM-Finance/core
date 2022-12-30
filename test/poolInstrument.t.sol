pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";
import "forge-std/StdStorage.sol";
import {Cash} from "../contracts/utils/Cash.sol";
import "@prb/math/SD59x18.sol";
import {PoolInstrument} from "../contracts/instruments/PoolInstrument.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {TestNFT} from "../contracts/utils/TestNFT.sol";
import {Vault} from "../contracts/vaults/vault.sol";
import {MarketManager} from "../contracts/protocol/marketmanager.sol";
import {VariableInterestRate} from "../contracts/instruments/VariableInterestRate.sol";
import {LinearInterestRate} from "../contracts/instruments/LinearInterestRate.sol";
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
import {Controller} from "contracts/protocol/controller.sol";
import {VaultFactory} from "contracts/protocol/factories.sol";

// Proof of concept contract pool tests.
contract PoolInstrumentTests is Test {
    using stdStorage for StdStorage;
    Vault vault;
    Controller controller;
    ReputationManager reputationManager;
    VaultFactory vaultFactory;
    MarketManager marketmanager;
    SyntheticZCBPoolFactory poolFactory;
    address deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
    Cash asset;
    Cash erc20_1;
    Cash erc20_2;
    Cash erc20_3;
    TestNFT nft1;
    TestNFT nft2;

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

    PoolInstrument pool;

    uint256 wad = 1e18;

    uint256 constant precision = 1e18;
    uint256 N = 1;
    uint256 sigma = precision/20; //5%
    uint256 alpha = precision*4/10; 
    uint256 omega = precision*2/10;
    uint256 delta = precision*2/10; 
    uint256 r = 0;
    uint256 s = precision*2;
    uint256 steak = precision;

    uint256 principal = 1000 * precision;
    uint256 interest = 100*precision; 
    uint256 duration = 1*precision; 
    uint256 faceValue = 1100*precision; 

    uint256 startTime;

    VariableInterestRate rateCalculator;
    LinearInterestRate linearRateCalculator;
    bytes initCallData;
    // abi.encode(uint256 _minInterest, uint256 _vertexInterest, uint256 _maxInterest, uint256 _vertexUtilization)

    function setupUsers() public {
        jonna = address(0xbabe);
        vm.label(jonna, "jonna"); // manager1
        jott = address(0xbabe2); 
        vm.label(jott, "jott"); // utilizer 
        gatdang = address(0xbabe3); 
        vm.label(gatdang, "gatdang"); // validator
        sybal = address(0xbabe4);
        vm.label(sybal, "sybal");//manager2
        chris=address(0xbabe5);
        vm.label(chris, "chris");//manager3
        miku = address(0xbabe6);
        vm.label(miku, "miku"); //manager4
        goku = address(0xbabe7); 
        vm.label(goku, "goku"); //LP1 
        toku = address(0xbabe8);
        vm.label(toku, "toku"); 
        zeke = address(0xbabe9);
        vm.label(zeke, "zeke");
    }

    function setupPool() public {
        vm.startPrank(address(vault));
        asset.approve(address(pool), 10*wad);
        pool.deposit(10*wad, address(vault)); // only the vault should be able to deposit.
        vm.stopPrank();
    }

    function setUp() public {

        erc20_1 = new Cash("ERC20_1", "ERC20_1", 18);
        erc20_2 = new Cash("ERC20_2", "ERC20_2", 18);
        erc20_3 = new Cash("ERC20_3", "ERC20_3", 18);

        nft1 = new TestNFT("NFT_1", "NFT_1");
        nft2 = new TestNFT("NFT_2", "NFT_2");

        asset = new Cash("vault asset", "vault asset", 18);

        controller = new Controller(deployer, address(0)); // zero addr for interep
        vaultFactory = new VaultFactory(address(controller));
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

        reputationManager.incrementScore(jonna, precision);

        setupUsers();

        // vm.prank(address(vault));
        // asset.faucet(100*wad);

        startTime = block.timestamp;
    }

    // function addInterest(uint64 _currentRatePerSec, uint256 _deltaTime, uint256 _utilization, uint256 _deltaBlocks) public returns (uint256 _interestAdded) {
    //     bytes memory _initData;
    //     bytes memory _data = abi.encode(_currentRatePerSec, _deltaTime, _utilization, _deltaBlocks);
    //     uint256 newRate = rateCalculator.getNewRate(_data, _initData); // in wad.

        
    // }

   
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

    function cBal(address _who) public returns(uint256) {
        return asset.balanceOf(_who); 
    }

    // function getToMarketCondition() public{
    //     testVars1 memory vars; 

    //     vars.marketId = controller.getMarketId(toku); 

    //     vars.vault_ad = controller.getVaultfromId(vars.marketId); //
    //     vars.amountToBuy = Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.saleAmount*3/2; 
    //     vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
    //     assertEq(vars.curPrice, marketmanager.getPool(vars.marketId).b()); 

    //     // Let manager buy
    //     bytes memory data; 
    //     doApproveCol(address(marketmanager), jonna); 
    //     vm.prank(jonna); 
    //     (vars.amountIn, vars.amountOut) =
    //         marketmanager.buyBond(vars.marketId, int256(vars.amountToBuy), vars.curPrice + precision/2 , data); 

    //     assertApproxEqAbs(vars.amountIn, vars.amountToBuy, 10); 
    //     assertEq(marketmanager.loggedCollaterals(vars.marketId),vars.amountIn); 
    //     assert(controller.marketCondition(vars.marketId)); 
    //     assert(marketmanager.getPool(vars.marketId).getCurPrice() > vars.curPrice ); 

    //     // price needs to be at inceptionPrice
    //     vars.curPrice = marketmanager.getPool(vars.marketId).getCurPrice(); 
    //     assertApproxEqAbs(vars.curPrice, Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice, 100); 

    //     // let validator invest to vault and approve 
    //     vars.cbalnow = cBal(address(marketmanager.getPool(vars.marketId))); 
    //     vars.cbalnow2 = cBal(address(nftPool)); 
    //     doApprove(vars.marketId, vars.vault_ad);
    //     assertApproxEqAbs(vars.cbalnow + vars.valamountIn - cBal(address(marketmanager.getPool(vars.marketId))), 
    //         vars.valamountIn + vars.amountIn,10); 

    //     // see how much is supplied to instrument 
    //     console.log('?',
    //     marketmanager.getZCB(vars.marketId).totalSupply().mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.leverageFactor)
    //     .mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice), 
    //      marketmanager.loggedCollaterals(vars.marketId), cBal(address(pool)) - vars.cbalnow2);
    //     assertApproxEqAbs(cBal(address(pool)) - vars.cbalnow2, 
    //      marketmanager.getZCB(vars.marketId).totalSupply().mulWadDown(1e18+ Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.leverageFactor)
    //     .mulWadDown(Vault(vars.vault_ad).fetchInstrumentData(vars.marketId).poolData.inceptionPrice), 100);

        
    //     // assertEq(marketmanager.getZCB(vars.marketId).balanceOf(jonna) +
    //     // marketmanager.getZCB(vars.marketId).balanceOf(gatdang), marketmanager.getZCB(vars.marketId).totalSupply()); 

    //     // 
    // }

    // function testERC20Auction1() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(32*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);
    //     pool.borrow(8*wad, address(erc20_1), 0, 32*wad, zeke);
    //     // can't call liquidate on non-liquidatable account
    //     changePrank(toku);
    //     vm.expectRevert("borrower is not liquidatable");
    //     pool.liquidate(zeke);

    //     (bool liquidatable, int256 accountLiq) = pool._isLiquidatable(zeke);
    //     assertTrue(!liquidatable);
    //     assertGt(accountLiq, 0);

    //     // set interest rate of 25% per year.

    //     vm.warp(startTime + 250*364.24 days);
    //     (uint256 _interestEarned, , , ) = pool.addInterest();

    //     console.log("interest earned", _interestEarned / wad);
        
    //     (liquidatable, accountLiq) = pool._isLiquidatable(zeke);
    //     assertTrue(liquidatable);
    //     assertLt(accountLiq, 0);


    //     (PoolInstrument.CollateralLabel memory _label, uint256 _auctionId) = pool.liquidate(zeke);
    //     assertEq(_label.tokenAddress, address(erc20_1));
    //     assertEq(_label.tokenId, 0);
    //     assertEq(_auctionId, 1);

    //     (address borrower, address _col, uint256 _tokenId, SD59x18 initialPrice, , ,SD59x18 _startTime, bool alive) = pool.auctions(1);
    //     console.logInt(accountLiq);

    //     assertEq(borrower, zeke);
    //     assertEq(_col, address(erc20_1));
    //     assertEq(_tokenId, 0);
    //     assertTrue(alive, "auction alive");

    //     console.logInt(SD59x18.unwrap(initialPrice));
    //     assertEq(uint256(SD59x18.unwrap(_startTime)) / wad, startTime + 250*364.24 days, "incorrect start time");
    //     assertGtDecimal(uint256(SD59x18.unwrap(initialPrice)), wad/2, 18);
    // }

    // function testERC20Auction2() public {
    //     // purchasing little collateral and not closing auction
    //     // purchasing lot collateral and closing auction
    //     // repaying during auction, so that not liquidatable anymore.
    //     setupPool();
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(32*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);
    //     pool.borrow(wad, address(erc20_1), 0, 4*wad, zeke);
    //     (uint256 shares, uint256 amount) = pool.totalBorrow();
    //     console.log("shares1: ", shares);
    //     console.log("amount1: ", amount);

    //     (bool liquidatable,) = pool._isLiquidatable(zeke);
    //     assertTrue(!liquidatable);
    //     vm.warp(startTime + 500*364.24 days);

    //     pool.addInterest();

    //     // pre auction
    //     int256 accountLiq;
    //     (liquidatable, accountLiq) = pool._isLiquidatable(zeke);
    //     assertTrue(liquidatable);
    //     console.log("A");
    //     console.logInt(accountLiq);

    //     // liquidate
    //     pool.liquidate(zeke);

    //     // toku buys little collateral
    //     changePrank(toku);
    //     erc20_1.faucet(30*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);
    //     asset.faucet(30*wad);
    //     asset.approve(address(pool), type(uint256).max);

    //     // (,,,SD59x18 Pi,,,,) = pool.auctions(1); 
    //     // console.log("Pi: ", uint256(SD59x18.unwrap(Pi)));
    //     // console.log("purchasePrice: ", pool.purchasePriceERC20(1, wad));
    //     // console.logInt(accountLiq);
    //     // pool.purchaseERC20Collateral(1, wad);
    //     // (liquidatable, accountLiq) = pool._isLiquidatable(zeke);
    //     // assertTrue(!liquidatable);
    //     // console.log("B");
    //     // console.logInt(accountLiq);

    //     // closes auction on buy
    //     pool.purchaseERC20Collateral(1, 4*wad);
    //     (liquidatable, accountLiq) = pool._isLiquidatable(zeke);
    //     assertTrue(!liquidatable, "account no longer liquidatable");    
    //     console.logInt(accountLiq);

    // }

    // function testERC20Auction3() public {
    //     // user can repay while auction is open.
    //     setupPool();
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(32*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);
    //     asset.faucet(32*wad);
    //     asset.approve(address(pool), type(uint256).max);
    //     pool.borrow(wad, address(erc20_1), 0, 4*wad, zeke);
    //     vm.warp(startTime + 500*364.24 days);
    //     pool.addInterest();

    //     pool.liquidate(zeke);
    //     pool.repay(wad, zeke);

    //     pool.closeAuction(zeke);

    //     assertEq(0,pool.userAuctionId(zeke));
    // }

    // // liquidate + purchase collateral + close auction.
    // function testERC721Auction1() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     nft1.freeMint(zeke, 1);
    //     nft1.approve(address(pool), 1);
    //     pool.borrow(wad/4, address(nft1), 1, 0, zeke);
    //     vm.warp(startTime + 500*364.24 days);

    //     pool.addInterest();

    //     pool.liquidate(zeke);

    //     changePrank(toku);

    //     asset.faucet(10*wad);
    //     asset.approve(address(pool), type(uint256).max);
    //     pool.purchaseERC721Collateral(1);
    //     assertEq(0,pool.userAuctionId(zeke));

    //     (bool liquidatable,) = pool._isLiquidatable(zeke);
    //     assertEq(liquidatable, false);
    // }

    // // liquidate + repay + close auction + can't purchase collaterl
    // function testERC721Auction2() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     nft1.freeMint(zeke, 1);
    //     nft1.approve(address(pool), 1);
    //     pool.borrow(wad/4, address(nft1), 1, 0, zeke);
    //     vm.warp(startTime + 500*364.24 days);

    //     pool.addInterest();

    //     pool.liquidate(zeke);

    //     // test start

    //     changePrank(toku);
        
    //     asset.faucet(100*wad);
    //     asset.approve(address(pool), type(uint256).max);
        
    //     changePrank(zeke);
    //     asset.approve(address(pool), type(uint256).max);
    //     asset.faucet(100*wad);
    //     pool.userBorrowShares(zeke);
    //     pool.repay(wad/4, zeke);

    //     vm.expectRevert("auction closed");
    //     pool.purchaseERC721Collateral(1);
    // }

    // function testAuction1() public {
        
    // }

    // function testCollateral1 () public {
    //     setupPool();
    //     // borrower adds collateral
    //     vm.prank(zeke);
    //     erc20_3.faucet(10*wad);

    //     erc20_3.approve(address(pool), 10*wad);

    //     // can't add non-approved collateral
        
    //     vm.prank(zeke);
    //     vm.expectRevert("collateral not approved");
    //     pool.addCollateral(address(erc20_3), 0, wad, zeke);

    //     vm.expectRevert("WRONG_FROM");
    //     pool.addCollateral(address(nft2), 1, 0, zeke);

    //     vm.expectRevert("collateral not approved");
    //     pool.removeCollateral(address(erc20_3), 0, wad, zeke);

    //     // can add approved-collateral
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(10*wad);
    //     nft1.freeMint(zeke, 1);

    //     console.log(nft1.ownerOf(1));

    //     erc20_1.approve(address(pool), wad);
    //     nft1.approve(address(pool), 1);

    //     pool.addCollateral(address(erc20_1), 0, wad, zeke); 
    //     pool.addCollateral(address(nft1), 1, 0, zeke);
    //     vm.stopPrank();

    //     vm.startPrank(zeke);
    //     pool.removeCollateral(address(nft1), 1, 0, zeke);

    //     // pool._canBorrow(zeke);

    //     pool.removeCollateral(address(erc20_1), 0, wad, zeke);
    //     // console.log(pool._canBorrow(zeke));
    //     // vm.stopPrank();
        
    // }

    // function testCollateral2() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(10*wad);
    //     nft1.freeMint(zeke, 1);

    //     erc20_1.approve(address(pool), wad);
    //     nft1.approve(address(pool), 1);

    //     pool.addCollateral(address(erc20_1), 0, wad, zeke); 
    //     pool.addCollateral(address(nft1), 1, 0, zeke);
    //     vm.stopPrank();

    //     // can't remove another person's collateral
    //     vm.prank(toku);
    //     vm.expectRevert("not owner of nft");
    //     pool.removeCollateral(address(nft1), 1, 0, toku);

    //     vm.prank(toku);
    //     vm.expectRevert(stdError.arithmeticError);
    //     pool.removeCollateral(address(erc20_1), 0, wad, toku);

    //     // can't remove more than existing collateral;
    //     vm.prank(zeke);
    //     vm.expectRevert(stdError.arithmeticError);
    //     pool.removeCollateral(address(erc20_1), 0, wad*2, zeke);
    // }

    // function testCollateral3() public {
    //     setupPool();
    //     // can't remove collateral if post-removal borrower is insolvent
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(10*wad);
    //     erc20_1.approve(address(pool), 2*wad);
    //     pool.borrow(wad/2, address(erc20_1), 0, 2*wad, zeke);
    //     //log_named_decimal_int
    //     (uint256 bamount, uint256 bshares) = pool.totalBorrow();
    //     assertEqDecimal(wad/2, bshares, 18);
    //     assertEqDecimal(wad/2, bamount, 18);

    //     vm.expectRevert("borrower is insolvent");
    //     pool.removeCollateral(address(erc20_1), 0, wad, zeke);
    // }

    // function testBorrow1() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     nft2.freeMint(zeke,1);
    //     nft2.approve(address(pool), 1);

    //     vm.expectRevert("borrower is insolvent");
    //     pool.borrow(wad, address(nft2), 1, 0, zeke);

    //     console.log("shares: ", pool.borrow(wad/4, address(nft2), 1, 0, zeke));
        
    //     vm.expectRevert("WRONG_FROM");
    //     pool.borrow(wad, address(nft2), 1, 0, zeke);

    //     vm.expectRevert("borrower is insolvent");
    //     pool.borrow(wad, address(0),0,0, zeke);
    //     vm.stopPrank();
    // }

    // function testBorrow2() public {
    //     setupPool();
    //     vm.startPrank(zeke);
    //     erc20_1.faucet(10*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);

    //     // borrow math
    //     pool.borrow(wad/4, address(erc20_1), 0, wad, zeke);
    //     assertEq(10*wad - wad, erc20_1.balanceOf(zeke));
    //     assertEq(wad, erc20_1.balanceOf(address(pool)));
    //     assertEq(wad, pool.userCollateralERC20(address(erc20_1), zeke));
    //     assertEq(wad/4, pool.userBorrowShares(zeke));

    //     vm.stopPrank();
    //     vm.startPrank(toku);
    //     erc20_1.faucet(10*wad);
    //     erc20_1.approve(address(pool), type(uint256).max);
    //     vm.expectRevert("insufficient contract asset balance");
    //     pool.borrow(10*wad, address(erc20_1), 0, wad, toku);
        

    //     pool.borrow(2*wad, address(erc20_1), 0, 8*wad, toku);
    //     assertEq(pool.userBorrowShares(toku), 2*wad);

    //     vm.stopPrank();
    // }

    // function testInterest1() public {
    //     setupPool();
    //     // 1 borrower shares created
    //     vm.startPrank(zeke);
        
    //     // zeke adds collateral of 1 wad, to borrow 1/4 wad.
    //     erc20_1.faucet(10*wad);
    //     erc20_1.approve(address(pool), wad);
    //     pool.borrow(wad/4, address(erc20_1), 0, wad, zeke); 
    //     vm.stopPrank();

    //     // TODO: check variable interest rate.
    // }

    // function testERC4626() public {
    //     vm.startPrank(address(vault));
    //     asset.faucet(100*wad);
    //     asset.approve(address(pool), type(uint256).max);
    //     pool.deposit(wad, address(vault));

    //     assertEqDecimal(wad, pool.totalAssets(), 18);
    //     assertEqDecimal(wad, pool.totalSupply(), 18);

    //     vm.expectRevert('not enough asset');
    //     pool.withdraw(2*wad, address(vault), address(vault));
    //     uint256 ts = pool.totalSupply();
    //     pool.mint(wad, address(vault));
    //     assertEqDecimal(wad*2, pool.totalSupply(), 18);
    //     uint256 new_asset_supply = wad + wad * wad/(ts);
    //     assertEq(new_asset_supply, pool.totalAssets());
    // }
}