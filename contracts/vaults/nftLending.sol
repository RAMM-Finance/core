pragma solidity ^0.8.16;

import "./vault.sol";
// import {ERC20} from "./tokens/ERC20.sol";
// import {ERC4626} from "./mixins/ERC4626.sol"; 
import "openzeppelin-contracts/utils/math/Math.sol";
// import {FixedPointMathLib} from "./utils/FixedPointMathLib.sol";
import "forge-std/console.sol";
import {Instrument} from "./instrument.sol";
import {ERC721} from "./tokens/ERC721.sol"; 

// Need to be 
// 1. quick to borrow
// 2. can add new nft to borrow through longZCB governance 
// 3. managers underwrite and absorb loss 
// 4. liquidatation thorugh auctions or managers buy 
// 5. 
// THINK of a system where managers approve a criterion and profit
// from all investment from these criterion. 
// Instance generated for a new ERC721 

/// @notice people can submit an NFT collateral
/// from a predtermined set
contract SimpleNFTPool is Instrument, ERC4626{

    using FixedPointMathLib for uint256; 

    constructor(
        address _vault,
        address _utilizer, 
        address _underlying 
        
        ) Instrument(_vault, _utilizer) ERC4626(ERC20(_underlying),"Mock", "Mock" ){
        utilizer = _utilizer; 
        underlying = ERC20(_underlying); // already specified 
        
    }

    mapping(bytes32=> bool )public  accepted; 
    bytes32[] acceptedList; 
    address public utilizer;  

    function borrowAllowed() public returns(bool){
        return true; 
    }
    function totalAssets() public view override returns (uint256){
        return asset.balanceOf(address(this)); 
    }
    function borrow(
        address tokenAddress,
        uint256 tokenId, 
        uint256 borrowAmount) external{
        borrowAllowed();
        require(accepted[keccak256(abi.encodePacked(tokenAddress, tokenId))], "Unaccepted"); 

        ERC721(tokenAddress).transferFrom(msg.sender, address(this), tokenId); 
        ERC20(underlying).transfer(msg.sender, borrowAmount ); 

    }

    function repay(
        address tokenAddress,
        uint256 tokenId, 
        uint256 repayAmount
        ) external{
        require(accepted[keccak256(abi.encodePacked(tokenAddress, tokenId))], "Unaccepted"); 
        ERC20(underlying).transferFrom(msg.sender, address(this), repayAmount); 
        ERC721(tokenAddress).transferFrom(address(this), msg.sender, tokenId); 
    }

    function addAcceptableCollateral(address tokenAddress, uint256 tokenId) external{
        bytes32 key = keccak256(abi.encodePacked(tokenAddress, tokenId)); 
        accepted[key] = true;
        acceptedList.push(key); 
    }

    function instrumentApprovalCondition() public override view returns(bool){
        return true; 
    }
    function assetOracle(uint256 supply) public view override returns(uint256){
        return supply; 
    }



    

}  










