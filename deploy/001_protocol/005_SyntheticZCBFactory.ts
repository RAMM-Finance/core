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

  const linear_library = await deployments.deploy("LinearCurve", {
  	from: deployer,
  	log: true
  })
  // const{address:linearcurve_addr} = await deployments.get("LinearCurve"); 

  await deployments.deploy("SyntheticZCBPoolFactory", {
    from: deployer,
    args,
    log: true,
    libraries: {LinearCurve: linear_library.address}
  });
};
        
func.tags = ["SyntheticZCBFactory"];
  
export default func;
// deploying "Controller" (tx: 0x7c74144de0174928c96c546c3e7ec5ac537a211ab39813fca1be45944993a615)...: deployed at 0xFdeE43628CC24e583dEfaB4036aAb0B52eB5FB85 with 5369148 gas
// deploying "ReputationNFT" (tx: 0xf6c506e579dd5f68b22e58ca1e42377c651046125aaf493b68da1c3372c82983)...: deployed at 0x3c33c0125744E282F8302adCdad76376cA80f393 with 1668480 gas
// deploying "MarketManager" (tx: 0xa7baff59e7a87658fd4377d066711f474b82b597e13118fe9a01140fcb1bb7b0)...: deployed at 0x0EC667331F2B58FA78683897eac60357ed9646B3 with 5424504 gas
// deploying "VaultFactory" (tx: 0x9dcc29d31245d41ce98a04c517190577e89d68eb5d29367b7bedafe87a29a508)...: deployed at 0x815F8f7155faa572AF7eDbB76B86894bef9ce315 with 5260416 gas
// deploying "Fetcher" (tx: 0x02ac902df5d674b9330ce324b4e816ed765959b5c2432e98af8a4db91aa33cf6)...: deployed at 0x26F1c66257A981c23632571e4Cca278860F4C9bE with 1967510 gas
// deploying "ZCBFactory" (tx: 0xfe90a46ca00215de8e8a0ee98878e4b6c8a48f7eb0833416dcbacfd369eb3fdb)...: deployed at 0xBd5D6b960F2c1471C5B952086100a30cEcd60904 with 1067965 gas
// deploying "LinearCurve" (tx: 0x2309bebd61cc579444d6e67def394e64885736dd91c9eef49d981f8d55b607d5)...: deployed at 0x88Dcf376A97c2cadDB8cbAf17d0186E2895525E7 with 635832 gas
// deploying "SyntheticZCBPoolFactory" (tx: 0xf4316223e6a5e35b3df27cc19b6e62297ad25f5c2ee86c97d5e70522310c3e00)...: deployed at 0x64bE7206c5fcC5a995ACcfF59d735795325C162B with 5326367 gas
// writting addresses