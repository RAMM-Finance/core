pragma solidity ^0.8.16;
import {PoolInstrument} from "./poolInstrument.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

contract Auctioneer {
    using FixedPointMathLib for uint256;
        /// @notice dutch auction
    struct Auction { // linearDecrease for beta only.
        address borrower;
        address collateral;
        uint256 tokenId;
        uint256 creationTimestamp; // auction start
        bool alive; // delete auction.
    }

    mapping(bytes32=>Auction) public auctions; // auction id => auction data, auction id is in order of creation.
    mapping(address=>bytes32[]) public userAuctionIds; // user => auction ids, if 0 then no auction, corresponds to active auctions.
    
    bytes32[] public activeAuctionIds;

    event AuctionCreated(bytes32 indexed id, address indexed borrower, address indexed collateral, uint256 tokenId);
    event AuctionClosed(bytes32 indexed id, address indexed borrower, address indexed collateral, uint256 tokenId);
    event CollateralPurchased(bytes32 indexed id, address indexed buyer, address indexed collateral, uint256 tokenId, uint256 amount);
    
    PoolInstrument pool;

    modifier onlyPool() {
        require(msg.sender == address(pool), "!pool");
        _;
    }

    constructor (address _pool) {
        pool = PoolInstrument(_pool);
    }

    function computeAuctionId(address _borrower, address _collateral, uint256 _tokenId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_borrower, _collateral, _tokenId));
    }

    function createAuction(address _borrower, address _collateral, uint256 _tokenId) external onlyPool returns (bytes32 auctionId) {
        auctionId = computeAuctionId(_borrower, _collateral, _tokenId);
        bytes32 collateralId = pool.computeId(_collateral, _tokenId);

        require(!auctions[auctionId].alive, "!auction");
        require(pool.enabledCollateral(_borrower, collateralId), "!enabled");
        
        // must have balance for auction.
        if (pool.getCollateralConfig(collateralId).isERC20) {
            require(pool.userERC20s(collateralId,_borrower) > 0, "!balance");
        } else {
            require(pool.userERC721s(collateralId) == _borrower, "!balance");
        }

        auctions[auctionId] = Auction({
            borrower: _borrower,
            collateral: _collateral,
            tokenId: _tokenId,
            creationTimestamp: block.timestamp,
            alive: true
        });

        activeAuctionIds.push(auctionId);
        userAuctionIds[_borrower].push(auctionId);

        emit AuctionCreated(auctionId, _borrower, _collateral, _tokenId);
    }

    function resetAuction(address _borrower, address _collateral, uint256 _tokenId) external onlyPool {
        require(auctions[computeAuctionId(_borrower, _collateral, _tokenId)].alive, "!auction");
        auctions[computeAuctionId(_borrower, _collateral, _tokenId)].creationTimestamp = block.timestamp;
    }

    function closeAuction(address _borrower, address _collateral, uint256 _tokenId) external onlyPool {
        _closeAuction(computeAuctionId(_borrower, _collateral, _tokenId), _borrower);
    }

    function _closeAuction(bytes32 _auctionId, address _borrower) internal {
        auctions[_auctionId].alive = false;

        bytes32[] memory _activeAuctionIds = activeAuctionIds;
        bytes32[] memory _userAuctionIds = userAuctionIds[_borrower];



        for (uint256 i = 0; i < _activeAuctionIds.length; i++) {
            if (_activeAuctionIds[i] == _auctionId) {
                activeAuctionIds[i] = _activeAuctionIds[_activeAuctionIds.length - 1];
                activeAuctionIds.pop();
                break;
            }
        }

        for (uint256 i = 0; i < _userAuctionIds.length; i++) {
            if (_userAuctionIds[i] == _auctionId) {
                userAuctionIds[_borrower][i] = _userAuctionIds[_userAuctionIds.length - 1];
                userAuctionIds[_borrower].pop();
                break;
            }
        }

        console.log("closing auction");
    }

    function getActiveUserAuctions(address _user) external view returns (bytes32[] memory) {
        return userAuctionIds[_user];
    }

    function closeAllAuctions(address _borrower) external onlyPool {
        bytes32[] memory _userAuctionIds = userAuctionIds[_borrower];
        for (uint256 i = 0; i < _userAuctionIds.length; i++) {
            _closeAuction(_userAuctionIds[i], _borrower);
        }
    }

    /**
     doesn't check whether tau has passed.
     */
    function purchasePrice(address _borrower, address _collateral, uint256 _tokenId) public view returns (uint256 currentPrice) {
        
        bytes32 auctionId = computeAuctionId(_borrower, _collateral, _tokenId);
        bytes32 collateralId = pool.computeId(_collateral, _tokenId);

        Auction memory auction = auctions[auctionId];
        PoolInstrument.Config memory config = pool.getCollateralConfig(collateralId);
        require(auction.alive, "auction is not alive");

        /**
         slope is (top - 0) / (0 - tau), pf = pi + slope * (t - ti)
         */
        uint256 top = config.buf.mulWadDown(config.maxAmount);
        uint256 t = block.timestamp - auction.creationTimestamp;

        if (t > config.tau) {
            currentPrice = 0;
        } else {
            currentPrice = top  - (top / config.tau) * t;
        }
    }

    function getAuction(address _borrower, address _collateral, uint256 _tokenId) external view returns (Auction memory) {
        return auctions[computeAuctionId(_borrower, _collateral, _tokenId)];
    }

    function getAuctionWithId(bytes32 _auctionId) external view returns (Auction memory) {
        return auctions[_auctionId];
    }

}
