import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
// import { BigNumber } from "ethers";
import { BigNumber } from "ethers";

const pp = BigNumber.from(10).pow(18);

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const cash_addr = (await deployments.get("Collateral")).address;
  const controller_addr = (await deployments.get("Controller")).address;
  const args = [controller_addr];
  // await deployments.deploy("Vault", {
  //   from: deployer,
  //   args,
  //   log: true,
  // });

  // await deployments.deploy("VaultFactory", {
  //   from: deployer,
  //   args,
  //   log: true, 
  // });
          
  // const cr_args = ["0x88197517e53F3E82a5385339bD41cF65e32ed82F", deployer, 10000, 1000, 100, 11000, 
  // cash_addr, cash_addr, 0,0]
  // await deployments.deploy("CreditLine", {
  //   from: deployer,
  //   args: cr_args,
  //   log: true,
  // });


  const vault_address = "0xdFbE3F77C65f298e93B0286F05446Da1a7DB3415"; 
  const weth_address = "0x6219CC8a3E880053ea0A1398f86E226C37603239"; 
  const _cash = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 
  const _oracle = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 

  const _strikePrice = pp; 
  const _pricePerContract = pp.div(10);
  const _shortCollateral = pp.mul(10); 
  const _longCollateral = _shortCollateral.mul(_pricePerContract).div(pp); 
  const duration = 10000; 

      await deployments.deploy("CoveredCallOTC", {
    from: deployer,
    args:[ vault_address, deployer, weth_address, 
    _strikePrice, _pricePerContract, _shortCollateral, _longCollateral,_cash, _oracle, duration],
    log: true,
  });
};
        
func.tags = ["Vault"];
  
export default func;