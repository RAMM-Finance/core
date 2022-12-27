pragma solidity ^0.8.16;
import {ERC721} from "solmate/tokens/ERC721.sol";


contract TestNFT is ERC721 {

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC721(_name, _symbol) {
    }

    function freeMint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }

    function tokenURI(uint256 id) public view override virtual returns (string memory) {
        return "tokenURI";
    }
}