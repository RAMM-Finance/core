import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';
import { getChainId } from "hardhat";
import { updateAddressConfig } from '../src/addressesConfigUpdater';
import path from "path";
import { Addresses } from '../constants';

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
    // // retrieve addresses from contracts
    // const {deployments, getNamedAccounts} = hre;
    // console.log("generating addresses...");

    // const chainId = parseInt(await getChainId());

    // const { address: controller} = await deployments.get("Controller");
    // const { address: marketManager} = await deployments.get("MarketManager");
    // const { address: syntheticZCBFactory} = await deployments.get("SyntheticZCBPoolFactory");
    // const { address: vaultFactory } = await deployments.get("VaultFactory");
    // const { address: reputationToken } = await deployments.get("ReputationNFT");
    // const { address: fetcher } = await deployments.get("Fetcher");
    // const filePath = path.resolve(__dirname, "../addresses.ts");

    // const addresses: Addresses = {
    //     controller,
    //     marketManager,
    //     syntheticZCBFactory,
    //     vaultFactory,
    //     reputationToken,
    //     fetcher
    // }
    // //TODO, not working rn.
    // updateAddressConfig(filePath, chainId, addresses);
    console.log("writting addresses");
    
};
export default func;