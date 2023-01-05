pragma solidity ^0.8.16;
import "@prb/math/SD59x18.sol";

contract PRBTest {

    function test() public pure returns (int256) {
        return SD59x18.unwrap(toSD59x18(1));
    }
}