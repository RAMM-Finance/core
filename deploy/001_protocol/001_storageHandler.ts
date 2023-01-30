import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const controller_addr = (await deployments.get("Controller")).address;
  const args = [controller_addr];

  const linear_library = await deployments.deploy("PerpTranchePricer", {
    from: deployer,
    log: true
  })
  const{address:perpAddr} = await deployments.get("PerpTranchePricer"); 

  await deployments.deploy("StorageHandler", {
    from: deployer,
    log: true,
    libraries: {PerpTranchePricer: perpAddr}
  });
};
  
func.tags = ["reputation nft"];
  
export default func;