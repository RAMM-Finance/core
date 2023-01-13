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



/// @notice borrow from leverageVault to leverage mint vaults
contract LeverageModule is ERC721Enumerable{
  	using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

	uint256 constant precision =1e18; 
	Controller controller; 
	/// param leverageVault is where the capital is for borrowing
	constructor(
		address controller_ad 
		)ERC721Enumerable() ERC721("RAMM lv", "RammLV") {
		controller = Controller(controller_ad); 
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
			0, collateralAmount, address(this) 
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
		(,,vars.collateralPower,) = vars.leveragePool.collateralData(address(vars.vault),0); 

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


