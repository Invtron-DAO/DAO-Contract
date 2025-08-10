require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-etherscan"); // ✅ ADD THIS
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
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
    apiKey: process.env.Etherscan_API_Key, // ✅ ADD THIS
  },
};