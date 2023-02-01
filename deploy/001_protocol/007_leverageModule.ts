import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const controller_addr = (await deployments.get("Controller")).address;
  const marketManager_ad = (await deployments.get("MarketManager")).address; 
  const reputationManager_ad = (await deployments.get("ReputationManager")).address; 

  await deployments.deploy("LeverageManager", {
    from: deployer,
    args:[controller_addr, marketManager_ad, reputationManager_ad],
    log: true,
  });
};
  
func.tags = ["Leverage"];
  
export default func;