import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const controller_addr = (await deployments.get("Controller")).address;
  const market_addr = (await deployments.get("MarketManager")).address;
  const reputationManager_addr = (await deployments.get("ReputationManager")).address;

  await deployments.deploy("ValidatorManager", {
    from: deployer,
    args:[ controller_addr, market_addr, reputationManager_addr],
    log: true,
  });
};
  
func.tags = ["Leverage"];
  
export default func;