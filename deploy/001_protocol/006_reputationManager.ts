import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const controller_addr = (await deployments.get("Controller")).address;
  const market_addr = (await deployments.get("MarketManager")).address;

  // await deployments.deploy("ReputationManager", {
  //   from: deployer,
  //   args:[controller_addr, market_addr],
  //   log: true,
  // });
};
  
func.tags = ["reputation nft"];
  
export default func;