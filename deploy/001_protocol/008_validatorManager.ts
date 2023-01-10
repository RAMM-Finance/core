import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  // const controller_addr = (await deployments.get("Controller")).address;

  await deployments.deploy("ValidatorManager", {
    from: deployer,
    args:["0x36c7feB605891E643258B7fFd5c28a41b83D71Aa", "0x18A7D487c5139ff4314Dc6907Dc3c7570E3f6890", "0x2558d5A7475891cA513944328052073f841CaB05"],
    log: true,
  });
};
  
func.tags = ["Leverage"];
  
export default func;