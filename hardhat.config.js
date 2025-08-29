require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-etherscan");
require("solidity-coverage");
require("hardhat-contract-sizer");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
        details: {
          yul: true,
          yulDetails: {
            // Helps reduce stack variables and can slightly shrink code size
            stackAllocation: true,
          },
        },
      },
      viaIR: true,
      metadata: {
        // Reduce deployed bytecode size by omitting the metadata hash
        bytecodeHash: "none",
      },
    },
    overrides: {
      "contracts/INVTRON_DAO.sol": {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 75,
            details: {
              yul: true,
              yulDetails: {
                stackAllocation: true,
              },
            },
          },
          viaIR: true,
          metadata: { bytecodeHash: "none" },
        },
      },
    },
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_PROJECT_ID}`,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      httpHeaders: {
        Authorization:
          "Basic " +
          Buffer.from(`${process.env.INFURA_PROJECT_ID}:${process.env.INFURA_PROJECT_SECRET}`).toString("base64")
      }
    }
  },
  etherscan: {
    apiKey: process.env.Etherscan_API_Key,
  },
  contractSizer: {
    runOnCompile: true,
    strict: true,
    except: [],
  },
};
