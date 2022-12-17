import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

   await deployments.deploy("ZCBFactory", {
    from: deployer,
    args: [],
    log: true,
  	});

  const { address: controller_addr} = await deployments.get("Controller");
  const {address : zcb_addr} = await deployments.get("ZCBFactory"); 
  const args = [controller_addr, zcb_addr];

  await deployments.deploy("SyntheticZCBPoolFactory", {
    from: deployer,
    args,
    log: true,
  });
};
        
func.tags = ["SyntheticZCBFactory"];
  
export default func;