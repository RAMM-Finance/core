import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
// import { BigNumber } from "ethers";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const cash_addr = (await deployments.get("Collateral")).address;
  // const controller_addr = (await deployments.get("Controller")).address;
  // const args = [controller_addr];
  // // await deployments.deploy("Vault", {
  // //   from: deployer,
  // //   args,
  // //   log: true,
  // // });

  // await deployments.deploy("VaultFactory", {
  //   from: deployer,
  //   args,
  //   log: true, 
  // });
          
  const cr_args = ["0x88197517e53F3E82a5385339bD41cF65e32ed82F", deployer, 10000, 1000, 100, 11000, 
  cash_addr, cash_addr, 0,0]
  await deployments.deploy("CreditLine", {
    from: deployer,
    args: cr_args,
    log: true,
  });

};
        
func.tags = ["Vault"];
  
export default func;