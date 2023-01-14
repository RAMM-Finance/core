import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';
import { getChainId } from "hardhat";
import { updateAddressConfig } from '../src/addressesConfigUpdater';
import path from "path";
import { Addresses } from '../constants';
import { BigNumber } from "ethers";
const pp = BigNumber.from(10).pow(18);

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
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const vault_address = "0xdFbE3F77C65f298e93B0286F05446Da1a7DB3415"; 
  const weth_address = "0x6219CC8a3E880053ea0A1398f86E226C37603239"; 
  const _cash = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 
  const _oracle = "0xd6A5640De726a89A54ca724ac12BCc5E89600720"; 

  const _strikePrice = pp; 
  const _pricePerContract = pp.div(10);
  const _shortCollateral = pp.mul(10); 
  const _longCollateral = _shortCollateral.mul(_pricePerContract).div(pp); 
  const duration = 10000; 

      await deployments.deploy("CoveredCallOTC", {
    from: deployer,
    args:[ vault_address, deployer, weth_address, 
    _strikePrice, _pricePerContract, _shortCollateral, _longCollateral,_cash, _oracle, duration],
    log: true,
  });

  const add = (await deployments.get("CoveredCallOTC")).address;
  console.log('add', add); 
};
func.tags = ["misc "];

export default func;