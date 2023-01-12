import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  // const { deployments, getNamedAccounts } = hre;
  // const { deployer } = await getNamedAccounts();

  // const linear_library = await deployments.deploy("LinearCurve", {
  // 	from: deployer,
  // 	log: true
  // })
  // const{address:linearcurve_addr} = await deployments.get("LinearCurve"); 

  // await deployments.deploy("Fetcher", {
  //   from: deployer,
  //   args: [],
  //   log: true,
  //   libraries: {LinearCurve: linearcurve_addr}
  // });
};
        
func.tags = ["Fetcher"];
  
export default func;