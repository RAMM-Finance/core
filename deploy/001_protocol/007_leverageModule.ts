import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const controller_addr = (await deployments.get("Controller")).address;

  await deployments.deploy("LeverageModule", {
    from: deployer,
    args:[controller_addr],
    log: true,
  });
};
  
func.tags = ["Leverage"];
  
export default func;