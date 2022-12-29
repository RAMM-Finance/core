// pragma solidity ^0.8.4; 
// //https://github.com/poap-xyz/poap-contracts/tree/master/contracts
// import {ERC721} from "solmate/tokens/ERC721.sol";
// import {Controller} from "./controller.sol";
// import "forge-std/console.sol";
// import {Vault} from "../vaults/vault.sol";
// import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
// import {PoolInstrument} from "../instruments/poolInstrument.sol"; 
// import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";



// /// @notice borrow from leverageVault to leverage mint vaults
// contract LeverageModule is ERC721{
//   	using FixedPointMathLib for uint256;
//     using SafeCastLib for uint256;

// 	Vault vault; 
// 	address UNDERLYING; 
// 	uint256 constant precision =1e18; 
// 	/// param leverageVault is where the capital is for borrowing
// 	constructor(
// 		address controller, 
// 		address leverageVault_ad
// 		)ERC721("LeverageVaultPosition", "RAMMLV") {
// 		controller = Controller(_controller); 
// 		UNDERLYING = leverageVault.UNDERLYING(); 
// 	}

// 	mapping(uint256=> _positions) Position; 
// 	mapping(uint256=> address)  leveragePools; 

// 	struct Position{
// 		address vaultAd; 
// 		uint256 totalShares; 

// 		uint256 suppliedCapital; 
// 		uint256 borrowedCapital; 

// 		uint32 borrowTimeStamp;
// 		uint192 endStateBalance; 
// 	}

//     /// @dev The ID of the next token that will be minted. Skips 0
//     uint176 private _nextId = 1;
//     /// @dev The ID of the next pool that is used for the first time. Skips 0
//     uint80 private _nextPoolId = 1;

//     function addLeveragePool(uint256 vaultId, address pool) public 
//     //onlyowner
//     {
//     	leveragePools[vaultId] = pool; 
//     }
// 	/// @notice Allow people to borrow from leverageVault and use that to
// 	/// create leveraged Vault positions 
// 	/// @dev Step is 1. borrow to this address, 2. mint vault(invest) to this address
// 	/// 3. mint position nft for the caller 
// 	/// param leverageFactor in WAD is percentage of suppliedCapital 
// 	// 0. transfer to this address
// 	// 1. mint vault to this address
// 	// 2. borrow to this address,
// 	// 3. mint new vault to this address 
// 	// 4. borrow new vault to this 
// 	function _mintWithLeverage(
// 		uint256 vaultId, 
// 		uint256 borrowAmount, 
// 		uint256 collateralAmount, 
// 		Vault vault) 
// 		internal returns(
// 			uint256 shares, 
// 			uint256 maxBorrowAmount, 
// 			bool noMoreLiq
// 		){
// 		PoolInstrument leveragePool = PoolInstrument(leveragePools[vaultId]); 
// 		ERC20 underlying = vault.UNDERLYING(); 

// 		// TODO add collateral

// 		uint256 maxBorrowableAmount_ = min(
// 			borrowAmount, 
// 			leveragePool.collateralData(address(vault),0).maxBorrowAmount.mulWadDown(collateralAmount) 
// 			); 

// 		maxBorrowableAmount = min(
// 			maxBorrowableAmount_, 
// 			leveragePool.totalAssetAvailable()
// 			); 

// 		noMoreLiq = maxBorrowAmount < maxBorrowableAmount_; 

// 		vault.approve(address(leveragePool), collateralAmount); 

// 		leveragePool.borrow(
// 			maxBorrowableAmount, address(vault), 
// 			0, collateralAmount, address(this) 
// 			); 

// 		shares = vault.deposit(suppliedCapital, address(this)); 		
// 	}

// 	struct MintLocalVars{
// 		Vault vault; 
// 		uint256 totalBorrowAmount; 
// 		uint256 maxBorrowAmount; 
// 		bool noMoreLiq; 
// 		uint256 shares, 
// 		uint256 mintedShares; 
// 		uint256 borrowedAmount; 
// 	}

// 	/// @notice Implements a leverage loop 
// 	// TODO implement with flash minting, maybe more gas efficient 
// 	function mintWithLeverage(
// 		uint256 vaultId, 
// 		uint256 suppliedCapital, 
// 		uint256 leverageFactor) public returns(uint256 tokenId) {
// 		MintLocalVars memory vars; 
// 		vars.vault = controller.vaults(vaultId); 

// 		underlying.tranferFrom(msg.sender, address(this), suppliedCapital); 
// 		underlying.approve(address(vault), suppliedCapital.mulWadDown(precision + leverageFactor)); 

// 		// Initial minting 
// 		vars.shares = vault.deposit(suppliedCapital, address(this));

// 		// borrow until leverage is met, 
// 		vars.totalBorrowAmount = suppliedCapital.mulWadDown(leverageFactor); 

// 		while(vars.totalBorrowAmount != 0 || !vars.noMoreLiq){
// 			vars.mintedShares += vars.shares; 

// 			(vars.shares, vars.maxBorrowAmount, vars.noMoreLiq) 
// 				= _mintWithLeverage(
// 					vaultId, 
// 					vars.totalBorrowAmount, 
// 					vars.shares,
// 					vars.vault
// 					); 

// 			vars.borrowedAmount += vars.maxBorrowAmount; 

// 			if(vars.totalBorrowAmount>= vars.maxBorrowAmount)
// 				(vars.totalBorrowAmount) -= vars.maxBorrowAmount;

// 			else vars.totalBorrowAmount = 0; 
// 		}

// 		_mint(to,  (tokenId = _nextId++)); 

// 		_positions[tokenId] = Position(
// 			address(vault),
// 			vars.mintedShares, 
// 			suppliedCapital, 
// 			borrowedAmount, 
// 			block.timestamp, 
// 			vars.shares.safeCastTo192(); 

// 		); // everything is minted to 
// 	}

// 	struct RewindLocalVars{

// 	}
// 		address vaultAd; 
// 		uint256 totalShares; 

// 		uint256 suppliedCapital; 
// 		uint256 borrowedCapital; 

// 		uint32 borrowTimeStamp;
// 		uint192 endStateBalance; 
// 	/// @notice Allows leverage minters to close their positions, and share profit with the leverageVault
// 	/// @dev step goes 1. repay to instrument,  
// 	function rewindPartialLeverage(
// 		uint256 vaultId, 
// 		uint256 tokenId, 
// 		uint256 withdrawAmount) public{
// 		//0. redeem 
// 		//1. repay to leverage pool
// 		//2. get vault collateral back 
// 		//3. redeem
// 		//4. repay to leverage pool 
// 		RewindLocalVars memory vars; 

// 		Positions memory position = _positions[tokenId]; 
// 		require(position.totalShares >= withdrawAmount, "larger than position"); 

// 		ERC20 underlying = vault.UNDERLYING(); 
// 		Vault vault = controller.vaults(vaultId); 
// 		PoolInstrument leveragePool = PoolInstrument(leveragePools[vaultId]); 

// 		vars.withdrawAmount = withdrawAmount; 

// 		// Begin with initial redeem 
// 		vars.assetReturned = vault.redeem(position.endStateBalance, address(this), address(this)); 
//     	// vars.redeemedShares = position.endStateBalance; 

// 		while(vars.withdrawAmount!=0 ){

// 			leveragePool.repayWithAmount(vars.assetReturned, address(this)); 

// 			vars.removed = leveragePool.removeAvailableCollateral(address(vault), 0, address(this)); 

// 			vars.assetReturned = vault.redeem(vars.removed, address(this), address(this)); 

// 			if(vars.withdrawAmount> vars.removed) vars.withdrawAmount -= vars.removed; 
//         	else vars.withdrawAmount = vars.removed; 

//         	vars.totalAssetReturned += vars.assetReturned; 

// 		}
// 		position.totalShares -= withdrawAmount; 
// 		if(position.borrowedCapital >= vars.totalAssetReturned)
// 			position.borrowedCapital -= vars.totalAssetReturned;

// 		else position.borrowedAmount == 0; 


// 	}
	

// 	function rewindFull(

// 		)public{}
// 	function min() internal pure returns(bool){

// 	}
// 	function max() internal pure returns(bool){

// 	}


