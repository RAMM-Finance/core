import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import 'hardhat-deploy';
import 'hardhat-deploy-ethers';
import "hardhat-preprocessor"; 
import fs from "fs";
import '@typechain/hardhat'
import '@nomiclabs/hardhat-ethers'

function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split("="));
}

function mapOverObject<V1, V2>(
  o: { [k: string]: V1 },
  fn: (k: string, v: V1) => [string, V2] | void
): { [k: string]: V2 } {
  const o2: { [k: string]: V2 } = {};
  for (const key in o) {
    const value = o[key];
    const kv = fn(key, value);
    if (kv === undefined) continue;
    const [k, v] = kv;
    if (k !== undefined) {
      o2[k] = v;
    }
  }
  return o2;
}

const ETHERSCAN_API_KEY = process.env["ETHERSCAN_API_KEY"] || "CH7M2ATCZABP2GIHEF3FREWWQPDFQBSH8G";

export const NULL_ADDRESS = "0x0000000000000000000000000000000000000000";
export const NO_OWNER = "0x0000000000000000000000000000000000000001";

const config: HardhatUserConfig = {
	preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          for (const [from, to] of getRemappings()) {
            if (line.includes(from)) {
              line = line.replace(from, to);
              break;
            }
          }
        }
        return line;
      },
    }),
  },
  paths: {
    sources: "./contracts",
    cache: "./cache_hardhat",
  },
  solidity: "0.8.12",
  namedAccounts: {
    deployer: {
      default: 0, // here this will by default take the first account as deployer
    },
    timelock: {
      default: 1,
      maticMainnet: NO_OWNER,
    },
    interep: {
      default: 1 // testing only. => deploy from separate account.
    },
    protocol: {
      default: 0,
      maticMainnet: NULL_ADDRESS,
    },
    linkNode: {
      default: 0,
      maticMainnet: "0x6FBD37365bac1fC61EAb2b35ba4024B32b136be6",
    },
    // This exists for tests.
    plebeian: {
      default: 1,
      maticMainnet: NULL_ADDRESS,
    },
  },
  networks: {
    localhost: {
      live: false,
      saveDeployments: true,
      tags: ["local"],
      gas: 20_000_000, // hardcoded because ganache ignores the per-tx gasLimit override
      chainId:137, 
      allowUnlimitedContractSize: true,
    },
    hardhat: {
      live: false,
      saveDeployments: true,
      chainId:137,

      tags: ["test", "local"],
      blockGasLimit: 20_000_000, // polygon limit
      gas: 20_000_000, // hardcoded because ganache ignores the per-tx gasLimit override
            allowUnlimitedContractSize: true

    },
    // kovan: {
    //   url: "https://kovan.infura.io/v3/595111ad66e2410784d484708624f7b1",
    //   gas: 9000000, // to fit createPool calls, which fails to estimate gas correctly
    // },
    // arbitrumKovan4: {
    //   url: "https://kovan4.arbitrum.io/rpc",
    //   chainId: 212984383488152,
    //   gas: 200000000, // arbitrum has as higher gas limit and cost for contract deploys from contracts
    //   gasPrice: 1,
    // },
    maticMumbai: {
      live: true,
      url: "https://rpc-mumbai.maticvigil.com/v1/d955b11199dbfd5871c21bdc750c994edfa52abd",
      chainId: 80001,
     /// confirmations: 2,
      accounts: ['5505f9ddf81b3aa83661c849fe8d56ea7a02dd3ede636f47296d85a7fc4e3bd6',
      'f7c11910f42a6cab4436bffea7dca20fed310bd794b7c37a930cc013ae6392d2'
      ],
      gas: 10000000000,
      gasPrice: 100000000000,
            allowUnlimitedContractSize: true

    },
    // maticMainnet: {
    //   live: true,
    //   url: "https://rpc-mainnet.maticvigil.com/",
    //   chainId: 137,
    //   gas: 10000000, // to fit createPool calls, which fails to estimate gas correctly
    //   gasPrice: 20000000000,
    // },
  },
};


export default config;
