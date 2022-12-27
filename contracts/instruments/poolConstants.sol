pragma solidity ^0.8.16;

// taken from https://github.com/FraxFinance/fraxlend
abstract contract PoolConstants {
    uint256 internal constant LTV_PRECISION = 1e5; // 5 decimals
    uint256 internal constant LIQ_PRECISION = 1e5;
    uint256 internal constant UTIL_PREC = 1e5;
    uint256 internal constant FEE_PRECISION = 1e5;
    uint256 internal constant EXCHANGE_PRECISION = 1e18;
    uint64 internal constant DEFAULT_INT = 158049988; // 0.5% annual rate 1e18 precision
}