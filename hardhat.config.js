require("@nomicfoundation/hardhat-toolbox")
require("@nomiclabs/hardhat-etherscan")
require("@openzeppelin/hardhat-upgrades")
require("dotenv").config()
/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  defaultNetwork: "hardhat",
  etherscan: {
    apiKey: {
      avalanche: process.env.SNOWTRACE,
      avalancheFujiTestnet: process.env.SNOWTRACE
    },
    apiUrl: "https://api.snowtrace.io"
  },
  solidity: {
    compilers: [
      {
        version: "0.8.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        },
      }
    ],
    overrides: {
      "contracts/ArtMarketplace/ArtMarketplace.sol": {
        version: "0.8.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 100
          }
        }
      }
    },
    settings: {
      optimizer: {
        enabled: true,
        runs: 8000
      }
    }
  },
  networks: {
    hardhat: {
      chainId: 1337, // We set 1337 to make interacting with MetaMask simpler
      accounts: {
        mnemonic: process.env.WALLET_KEY,
        initialIndex: 0,
        count: 20
      },
      loggingEnabled: false
    },
    development: {
      url: "http://127.0.0.1:8545/ext/bc/C/rpc",     // Localhost (default: none)
      accounts: [process.env.WALLET_PR_KEY],
      chainId: 1337,
      loggingEnabled: true
    },
    fuji: {
      url: `https://api.avax-test.network/ext/bc/C/rpc`,
      accounts: [process.env.WALLET_PR_KEY],
      chainId: 43113,
      loggingEnabled: true
    },
    mainnet: {
      url: `https://api.avax.network/ext/bc/C/rpc`,
      accounts: [process.env.WALLET_PR_KEY],
      chainId: 43114,
      loggingEnabled: true
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test"
  },
  mocha: {
    timeout: 40000
  }
}
