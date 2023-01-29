pragma solidity ^0.8.4; 
//https://github.com/poap-xyz/poap-contracts/tree/master/contracts
import {ERC20} from "solmate/tokens/ERC20.sol";
import  "openzeppelin-contracts/token/ERC721/extensions/ERC721Enumerable.sol"; 
import {Controller} from "./controller.sol";
import "forge-std/console.sol";
import {Vault} from "../vaults/vault.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PoolInstrument} from "../instruments/poolInstrument.sol"; 
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {MarketManager} from "./marketmanager.sol"; 
import {ReputationManager} from "./reputationmanager.sol"; 
import {ERC4626} from "../vaults/mixins/ERC4626.sol"; 
import {SyntheticZCBPool} from "../bonds/synthetic.sol"; 
import {StorageHandler} from "../global/GlobalStorage.sol"; 

/// @notice borrow from leverageVault to leverage mint vaults
contract LeverageManager is ERC721Enumerable{
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    uint256 constant precision =1e18; 
    Controller controller; 
    MarketManager marketManager; 
    ReputationManager reputationManager; 
  modifier _lock_() {
    require(!_mutex, "ERR_REENTRY");
    _mutex = true;
    _;
    _mutex = false;
  }
    bool private _mutex; 
    constructor(
        address controller_ad, 
        address marketManager_ad, 
        address reputationManager_ad
        )ERC721Enumerable() ERC721("RAMM lv", "RammLV") {
        controller = Controller(controller_ad); 
        marketManager = MarketManager(marketManager_ad); 
        reputationManager = ReputationManager(reputationManager_ad); 
    }
  modifier onlyController(){
    require(address(controller) == msg.sender , "!controller"); 
    _;
  }

  StorageHandler public Data; 
  function setDataStore(address dataStore) public onlyController{
    Data = StorageHandler(dataStore); 
  }
    mapping(uint256=>mapping(address=> LeveredBond)) public leveragePosition; 
    struct LeveredBond{
        uint256 debt; //how much collateral borrowed from vault 
        uint256 amount; // how much bonds were bought with the given leverage
    }

    struct LocalVars{
        uint256 psu; 
        uint256 pju; 
        uint256 levFactor; 
        uint256 seniorAmount; 
        uint256 budget; 

        Vault vault; 
    }

    function getPosition(uint256 marketId, address trader) public view returns(LeveredBond memory){
        return leveragePosition[marketId][trader]; 
    }

    /// @notice issue longzcb to this contract, create note to for trader 
    function issuePerpBondLevered(
        uint256 _marketId, 
        uint256 _amountIn, 
        uint256 _leverage
        ) external returns(uint256 issueQTY){
        require(_leverage <= getMaxLeverage(msg.sender) && _leverage >= precision, "!leverage");

        marketManager._canIssue(msg.sender, int256(_amountIn), _marketId); 
        MarketManager.CoreMarketData memory market = marketManager.getMarket(_marketId); 
        ERC20 underlying = ERC20(address(market.bondPool.BaseToken())); 

        // stack collateral from trader and loan from vault 
        uint256 amountPulled = _amountIn.divWadDown(_leverage); 
        underlying.transferFrom(msg.sender, address(this), amountPulled); 
        controller.pullLeverage(_marketId, _amountIn - amountPulled); 

        underlying.approve(address(marketManager), _amountIn); 
        issueQTY = marketManager.issueBond(_marketId, _amountIn, address(this), msg.sender); 

        leveragePosition[_marketId][msg.sender].debt += (_amountIn - amountPulled); 
        leveragePosition[_marketId][msg.sender].amount += (issueQTY); 
    }

    /// @notice redeem longzcb in this contract, send redeemed amount to vault
    /// and if debt fully repaid, send remaining to trader 
    /// param redeemAmount is in longZCB 
    function redeemLeveredPerpLongZCB(
        uint256 marketId, 
        uint256 redeemAmount
        ) external  returns(
            uint256 collateral_redeem_amount, 
            uint256 postRepayLeftOver, 
            uint256 paidDebt){
        LocalVars memory vars; 
        vars.vault = controller.getVault(marketId); 
        LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
        require(position.amount>=redeemAmount, "Amount ERR"); 

        // Redeem longZCB in this address and get back collateral_redeem_amount to this address
        /// Get back collateral, need to send repaid capital back to the vault 
        (collateral_redeem_amount, ) = 
            marketManager.redeemPerpLongZCB(marketId, redeemAmount, address(this), msg.sender); 
        vars.vault.UNDERLYING().transfer(address(vars.vault), collateral_redeem_amount); 

        // Need to first pay all of debt 
        if(position.debt > collateral_redeem_amount){
            paidDebt = collateral_redeem_amount; 
            position.debt -= collateral_redeem_amount; 
        } else{
            paidDebt = position.debt; 
            position.debt = 0 ; 
        }

        unchecked{position.amount -= redeemAmount;}

        // If debt is fully paid, can send unlocked funds 
        if (position.debt==0) {//100-70 = 30 send me back 30!!
            postRepayLeftOver = collateral_redeem_amount - paidDebt; 
            controller.redeem_transfer(postRepayLeftOver, msg.sender, marketId);
        }

        leveragePosition[marketId][msg.sender] = position; 
    }

    /// @notice for managers that are a) meet certain reputation threshold and b) choose to be more
    /// capital efficient with their zcb purchase. 
    /// @param _amountIn (in collateral) already accounts for the leverage, so the actual amount manager is transferring
    /// is _amountIn/_leverage 
    /// @dev the marketmanager should take custody of the quantity bought with leverage
    /// and instead return notes of the levered position 
    function buyBondLevered(
        uint256 _marketId, 
        uint256 _amountIn, 
        uint256 _priceLimit, 
        uint256 _leverage //in 18 dec 
        ) external _lock_ returns(uint256 amountIn, uint256 amountOut){
        require(_leverage <= getMaxLeverage(msg.sender) && _leverage >= precision, "!leverage");
        MarketManager.CoreMarketData memory market = marketManager.getMarket(_marketId); 
        ERC20 underlying = ERC20(address(market.bondPool.BaseToken())); 

        // stack collateral from trader and borrowing from vault 
        uint256 amountPulled = _amountIn.divWadDown(_leverage); 
        underlying.transferFrom(msg.sender, address(this), amountPulled); 
        controller.pullLeverage(_marketId, _amountIn - amountPulled); 

        // Buy bond to this address 
        bytes memory emptyByte; 
        underlying.approve(address(marketManager), _amountIn); 
        (amountIn, amountOut) = marketManager.buylongZCB(_marketId, int256(_amountIn),
            _priceLimit, emptyByte, address(this), msg.sender);  
   
        // create note to trader 
        leveragePosition[_marketId][msg.sender].debt += (_amountIn - amountPulled); 
        leveragePosition[_marketId][msg.sender].amount += amountOut; 
    }

    mapping(uint256=>mapping(address=> bool)) redeemed; 

    /// @notice redeem all zcb at maturity 
    function redeemLeveredBond(uint256 marketId) public{
        require(marketManager.isMarketResolved( marketId), "!resolved"); 
        require(!redeemed[marketId][msg.sender], "Redeemed");
        redeemed[marketId][msg.sender] = true; 

        if (controller.isValidator(marketId, msg.sender)) controller.redeemValidator(marketId, msg.sender); 

        LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
        require(position.amount>0, "0 Amount"); 

        uint256 redemption_price = marketManager.redemption_prices(marketId); 
        uint256 collateral_back = redemption_price.mulWadDown(position.amount) ; 
        uint256 collateral_redeem_amount = collateral_back >= uint256(position.debt)  
            ? collateral_back - uint256(position.debt) : 0; 

        if (!controller.isValidator(marketId, msg.sender)) {
          // bool increment = redemption_price >= config.WAD? true: false;
          // controller.updateReputation(marketId, msg.sender, increment);
          // reputationManager.recordPush(msg.sender, marketId, redemption_price, false, zcb_redeem_amount); 
        }
        marketManager.burnAndTransfer(marketId, address(this), position.amount, msg.sender, collateral_redeem_amount); 

        position.amount = 0; 
        position.debt = 0; 
        leveragePosition[marketId][msg.sender] = position;  
    }


    function redeemDeniedLeveredBond(uint256 marketId) public returns(uint collateral_amount){
        LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
        require(position.amount>0, "ERR"); 
        leveragePosition[marketId][msg.sender].amount = 0; 

        // TODO this means if trader's loss will be refunded if loss was realized before denied market
        if (controller.isValidator(marketId, msg.sender)) {
          collateral_amount = controller.deniedValidator(marketId, msg.sender);
        }else{
          collateral_amount = marketManager.longTrades(marketId, msg.sender);  
          // delete longTrades[marketId][msg.sender]; 
        }

        marketManager.burnAndTransfer(marketId, address(this), position.amount, msg.sender, collateral_amount); 
    }

    /// @notice returns the manager's maximum leverage 
    function getMaxLeverage(address manager) public view returns(uint256){
        //TODO experiment 
        return 5e18 ;//min((controller.getTraderScore(manager) * 1e18).sqrt(), 5e18);
    }
    /// @notice called by pool when buying, transfers funds from trader to pool 
    function tradeCallBack(uint256 amount, bytes calldata data) external{
        SyntheticZCBPool(msg.sender).BaseToken().transferFrom(abi.decode(data, (address)), msg.sender, amount); 
    }




    mapping(uint256=> Position) public positions; 
    mapping(uint256=> address)  leveragePools; 

    struct Position{
        address vaultAd; 
        uint256 totalShares; 

        uint256 suppliedCapital; 
        uint256 borrowedCapital; 

        uint256 borrowTimeStamp;
        uint256 endStateBalance; 
    }

    function getPosition(uint256 tokenId) public view returns (Position memory position){
        return positions[tokenId]; 
    }

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;
    /// @dev The ID of the next pool that is used for the first time. Skips 0
    uint80 private _nextPoolId = 1;

    function addLeveragePool(uint256 vaultId, address pool) public 
    //onlyowner
    {
        leveragePools[vaultId] = pool; 
    }
    /// @notice Allow people to borrow from leverageVault and use that to
    /// create leveraged Vault positions 
    /// @dev steps
    // 0. transfer to this address
    // 1. mint vault to this address
    // 2. borrow to this address,
    // 3. mint new vault to this address 
    // 4. borrow new vault to this 
    function _mintWithLeverage(
        uint256 vaultId, 
        uint256 availableLiquidity, 
        uint256 borrowAmount, 
        uint256 collateralAmount, 
        MintLocalVars memory vars) 
        internal{

        // Check collateral specific borrowable 
        uint256 maxBorrowableAmount = min(borrowAmount, vars.collateralPower.mulWadDown(collateralAmount)); 

        // Check if liquidity available
        vars.maxBorrowableAmount = min(maxBorrowableAmount, availableLiquidity); 

        // Depleted lendingpool if availableLiquidity < maxBorrowableAmount
        vars.noMoreLiq = (vars.maxBorrowableAmount < maxBorrowableAmount); 

        vars.vault.approve(address(vars.leveragePool), collateralAmount); 

        vars.leveragePool.borrow(
            vars.maxBorrowableAmount, address(vars.vault), 
            0, collateralAmount, address(this),
            true
            ); 

        console.log('new collateral amount', collateralAmount); 
        console.log('maxBorrowableAmount', vars.maxBorrowableAmount); 

        vars.shares = vars.vault.deposit(vars.maxBorrowableAmount, address(this));      
    }

    struct MintLocalVars{
        Vault vault; 
        PoolInstrument leveragePool; 

        uint256 totalBorrowAmount; 
        uint256 maxBorrowAmount; 
        bool noMoreLiq; 
        uint256 shares; 
        uint256 mintedShares; 
        uint256 borrowedAmount; 

        uint256 availableLiquidity; 
        uint256 maxBorrowableAmount; 
        uint256 collateralPower; 

    }

    function mintLev() public {
        //1. borrow from child pool, 
        //2. if child pool has not enough liq, go to parent pool 
        //3. debt: 10 to child pool, 5 to parent pool or 15 to child pool
        // or 15 to parent pool. First pay off parent pool, 
        // 
    }
    /// @notice Implements a leverage loop 
    // TODO implement with flash minting, maybe more gas efficient 
    function mintWithLeverage(
        uint256 vaultId, 
        uint256 suppliedCapital, 
        uint256 leverageFactor) public returns(uint256 tokenId, Position memory newPosition) {
        MintLocalVars memory vars; 
        vars.vault = controller.vaults(vaultId); 

        ERC20 underlying = ERC20(address(vars.vault.UNDERLYING()));
        underlying.transferFrom(msg.sender, address(this), suppliedCapital); 
        underlying.approve(address(vars.vault), suppliedCapital.mulWadDown(precision + leverageFactor)); 

        vars.leveragePool = PoolInstrument(leveragePools[vaultId]); 
        vars.availableLiquidity = vars.leveragePool.totalAssetAvailable(); 

        if(vars.availableLiquidity == 0) revert("Not Enough Liq"); 
        (,,vars.collateralPower,) = vars.leveragePool.collateralConfigs(vars.leveragePool.computeId(address(vars.vault),0)); 

        // Initial minting 
        vars.shares = vars.vault.deposit(suppliedCapital, address(this));

        // borrow until leverage is met, 
        vars.totalBorrowAmount = suppliedCapital.mulWadDown(leverageFactor); 

        while(true){
            vars.mintedShares += vars.shares; 
            console.log('___NEW___'); 
            console.log('totalBorrowAmount', vars.borrowedAmount); 
            console.log('borrowedAmount Left', vars.totalBorrowAmount); 
            _mintWithLeverage( 
                vaultId, 
                vars.availableLiquidity, 
                vars.totalBorrowAmount, 
                vars.shares,
                vars 
            ); 

            vars.borrowedAmount += vars.maxBorrowableAmount; 

            if(vars.totalBorrowAmount>= vars.maxBorrowableAmount)
                (vars.totalBorrowAmount) -= vars.maxBorrowableAmount;

            else vars.totalBorrowAmount = 0; 

            if(vars.totalBorrowAmount == 0 || vars.noMoreLiq) break; 
        }
        vars.mintedShares += vars.shares; 

        _mint(msg.sender,  (tokenId = _nextId++)); 

        newPosition = Position(
            address(vars.vault),
            vars.mintedShares, 
            suppliedCapital, 
            vars.borrowedAmount, 
            block.timestamp, 
            vars.shares
        );

        positions[tokenId] = newPosition; 



    }

    struct RewindLocalVars{
        uint256 assetReturned; 

        uint256 withdrawAmount; 
        uint256 removed; 
        uint256 totalAssetReturned;
        uint256 sharesRedeemed; 

    }

    /// @notice Allows leverage minters to close their positions, and share profit with the leverageVault
    /// @dev step goes 1. repay to instrument,  
    function rewindPartialLeverage(
        uint256 vaultId, 
        uint256 tokenId, 
        uint256 withdrawAmount) public{
        //0. redeem 
        //1. repay to leverage pool
        //2. get vault collateral back 
        //3. redeem
        //4. repay to leverage pool 
        RewindLocalVars memory vars; 

        Position memory position = positions[tokenId]; 
        require(position.totalShares >= withdrawAmount, "larger than position"); 

        Vault vault = controller.vaults(vaultId); 

        ERC20 underlying = ERC20(address(vault.UNDERLYING())); 
        PoolInstrument leveragePool = PoolInstrument(leveragePools[vaultId]); 
        underlying.approve(address(leveragePool), vault.previewMint(withdrawAmount)); //TODO 

        vars.withdrawAmount = withdrawAmount; 

        // Begin with initial redeem 


        // vars.redeemedShares = position.endStateBalance; 

        while(vars.withdrawAmount!=0 ){
            vars.sharesRedeemed = min(position.endStateBalance, vars.withdrawAmount); 
            vars.assetReturned = vault.redeem(
                vars.sharesRedeemed, 
                address(this),
                address(this)//70, 100=70, 80,30= 30
                ); 
            leveragePool.repayWithAmount(vars.assetReturned, address(this)); //70->80
            // get 70 collateral in, 30 collateral in, 
            vars.removed = leveragePool.removeAvailableCollateral(address(vault), 0, address(this)); 
            // get 80 collateral out , 34 collateral out
            console.log('___NEW___'); 
            console.log('withdraw left', vars.withdrawAmount); 
            console.log('redeemed shares',min(position.endStateBalance, vars.withdrawAmount) ); 
            console.log('redeemed/repayed', vars.assetReturned); 
            console.log('removed', vars.removed); 

            // Revert if err
            vars.withdrawAmount -= vars.sharesRedeemed; 

            vars.totalAssetReturned += vars.assetReturned; 

            position.endStateBalance = position.endStateBalance >= vars.withdrawAmount
                                        ? position.endStateBalance - vars.withdrawAmount + vars.removed 
                                        : vars.removed; 
            console.log('totalAssetReturned', vars.totalAssetReturned);                             
            console.log('endStateBalance', position.endStateBalance); 

        }// how does this take care of losses? how does interest accrue? 
        position.totalShares -= withdrawAmount; 

        if(position.borrowedCapital >= vars.totalAssetReturned)
            position.borrowedCapital -= vars.totalAssetReturned;

        else {
            position.borrowedCapital = 0; 
            // revert if withdraw amount was too large 
            position.suppliedCapital -= vars.totalAssetReturned - position.borrowedCapital; 
        }

        positions[tokenId] = position; 

    }

    function getTokenIds(address _owner) public view returns (uint[] memory) {
        uint[] memory _tokensOfOwner = new uint[](balanceOf(_owner));
        uint i;

        for (i=0;i<balanceOf(_owner);i++){
            _tokensOfOwner[i] =tokenOfOwnerByIndex(_owner, i);
        }
        return (_tokensOfOwner);
    }

    function getPositions(address _owner) public view returns(Position[] memory){
        uint[] memory ids = getTokenIds(_owner); 
        Position[] memory openpositions = new Position[](ids.length); 
        for(uint i=0; i<ids.length; i++){
            openpositions[i] = positions[ids[i]]; 
        }
        return openpositions; 
    }

// 60 c repay-> 70 v remove -> 70 v redeem-> 70c repay-> 80v remove -> 80v redeem 
// 70 + 
    /// @notice when debt is 0, user can claim their endstate balance 
    function deletePosition() public {

    }


    function viewPNL () public {}


    function rewindFull()public{}

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
    function tokenURI(uint256 id) public view override returns (string memory){}


}

// function redeemLeveredPoolLongZCB(
//         uint256 marketId, 
//         uint256 redeemAmount
//         ) external  returns(
//             uint256 collateral_redeem_amount, 
//             uint256 postRepayLeftOver, 
//             uint256 paidDebt){
//         LocalVars memory vars; 
//         LeveredBond memory position = leveragePosition[marketId][msg.sender]; 
//         require(position.amount>redeemAmount, "Amount ERR"); 

//         Vault vault = controller.getVault(marketId); 
//         MarketManager.CoreMarketData memory market = marketManager.getMarket(marketId); 
//         require(market.isPool, "!pool"); 

//         (vars.psu, vars.pju, vars.levFactor) = vault.poolZCBValue(marketId);
//         collateral_redeem_amount = vars.pju.mulWadDown(redeemAmount); 
//         vars.seniorAmount= redeemAmount.mulWadDown(vars.levFactor).mulWadDown(vars.psu); 

//         // Need to check if redeemAmount*levFactor can be withdrawn from the pool. If so, do so. 
//         vault.withdrawFromPoolInstrument(marketId, collateral_redeem_amount, address(this), vars.seniorAmount); 

//         // Need to first pay all of debt 
//         if(position.debt > collateral_redeem_amount){
//             paidDebt = position.debt - collateral_redeem_amount; 
//             position.debt -= collateral_redeem_amount; 
//         } else{
//             paidDebt = position.debt; 
//             position.debt = 0 ; 
//         }

//         position.amount -= redeemAmount; 
//         market.bondPool.trustedBurn(address(this), redeemAmount, true); 

//         if (position.debt==0) {
//             postRepayLeftOver = collateral_redeem_amount - paidDebt; 
//             controller.redeem_transfer(postRepayLeftOver, msg.sender, marketId);
//         }
        
//         // Update reputation 
//         reputationManager.recordPush(msg.sender, marketId, vars.pju, false, redeemAmount); 
//         leveragePosition[marketId][msg.sender] = position; 
//     }

    // /// @notice issue bond to this address, and give trader note
    // function issuePoolBondLevered(
    //     uint256 _marketId, 
    //     uint256 _amountIn, 
    //     uint256 _leverage
    //     ) external  returns(uint256 issueQTY){
    //     LocalVars memory vars; 
    //     require(marketManager.isMarketApproved(_marketId), "Pre Approval"); 
    //     marketManager._canIssue(msg.sender, int256(_amountIn), _marketId); 
    //     MarketManager.CoreMarketData memory market = marketManager.getMarket(_marketId); 

    //     Vault vault = controller.getVault(_marketId); 
    //     ERC20 underlying = ERC20(address(market.bondPool.BaseToken())); 
    //     address instrument = address(vault.Instruments(_marketId)); 

    //     // stack collateral from trader and borrowing from vault 
    //     uint256 amountPulled = _amountIn.divWadDown(_leverage); 
    //     underlying.transferFrom(msg.sender, address(this), amountPulled); 
    //     controller.pullLeverage(_marketId, _amountIn - amountPulled); 

    //     // Get price and sell longZCB with this price
    //     (vars.psu, vars.pju, vars.levFactor) = vault.poolZCBValue(_marketId);

    //     underlying.approve(instrument, _amountIn); 
    //     ERC4626(instrument).deposit(_amountIn, address(vault)); 

    //     issueQTY = _amountIn.divWadUp(vars.pju); //TODO rounding errs
    //     market.bondPool.trustedDiscountedMint(address(this), issueQTY); 

    //     // Need to transfer funds automatically to the instrument, seniorAmount is longZCB * levFactor * psu  
    //     vault.depositIntoInstrument(_marketId, issueQTY.mulWadDown(1e18 + vars.levFactor).mulWadDown(vars.psu), true);

    //     //TODO Need totalAssets and exchange rate to remain same assertion 
    //     //TODO vault always has to have more shares, all shares minted goes to vault 
    //     vars.budget = marketManager.getTraderBudget( _marketId, msg.sender); 
    //     reputationManager.recordPull(msg.sender, _marketId, issueQTY, _amountIn, vars.budget, true); 
    //     leveragePosition[_marketId][msg.sender] = LeveredBond(_amountIn - amountPulled , issueQTY) ;
    // }


