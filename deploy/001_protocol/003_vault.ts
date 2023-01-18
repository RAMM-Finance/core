import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
// import { BigNumber } from "ethers";
import { BigNumber } from "ethers";

const pp = BigNumber.from(10).pow(18);

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  // const cash_addr = (await deployments.get("Collateral")).address;
  // const controller_addr = (await deployments.get("Controller")).address;
  // const args = [controller_addr];
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


  const vault_address = "0xed001bc8974987701f5be2f6c012468a91e8cb11"; 
  const weth_address = "0x6219CC8a3E880053ea0A1398f86E226C37603239"; 
  const _cash = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 
  const _oracle = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 
};
        
func.tags = ["Vault"];
  
export default func;