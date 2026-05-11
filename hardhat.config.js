require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const {
  PRIVATE_KEY,
  INFURA_API_KEY,
  ETHERSCAN_API_KEY,
} = process.env;

function mustExist(value, name) {
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  networks: {
    sepolia: {
      url: `https://sepolia.infura.io/v3/${mustExist(INFURA_API_KEY, "INFURA_API_KEY")}`,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },

  etherscan: {
    apiKey: mustExist(ETHERSCAN_API_KEY, "ETHERSCAN_API_KEY"),
  },
};
