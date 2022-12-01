## Brief Developer Docs 

### protocol/Marketmanager.sol
is the entry points for all market participants. It applies constraints for trading and redirects them to the main AMM in bonds/synthetic.sol and bonds/GBC.sol

### bonds/synthetic.sol 
inherits from bonds/GBC.sol, and is the risk pricing AMM. During assessment, liquidity is the inverse slope 1/a of the linear equation

price of longZCB = a * net longZCB bought + b. 

a,b are constant during this period, this makes the amm a simple bonding curve with initial price b. After assessment, the parameters a,b of the bonding curve is different for each Ticks(as in uni v3), and can be changed by the traders providing liquidity and adding tick level limit orders. Default liquidity is set to 0, so a for 0 liquidity would be an infinite a (liq = 1/a) and the tick with 0 liquidity increases price immediately with no longZCB sold. 

ShortZCB logic is in BoundedDerivativesPool in bonds/GBC.sol. Intuitively, imagine that the area under the curve of the equation above is the amount collateral that needs to be given by the trader to purchase longZCB. Then, the 

Maximum Price of longZCB - that same area under the curve 

would be the amount of collateral that needs to be given by the trader to purchase shortZCB. 

### protocol/controller.sol
This is where the high level phase transtion logic takes place

### vaults
Inside this folder _vaults.sol_ is the logic for the VT, and is an erc4626. The base class of instruments is in _instrument.sol_, where the creditline and dov(decentralized options vault) contracts inherit from. 



To run written tests, clone repo, install and initiate foundry and run
```
forge test
```

