require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const {
  PRIVATE_KEY,
  INFURA_API_KEY,
  ETHERSCAN_API_KEY,
} = process.env;

function must(value, name) {
  if (!value) throw new Error(`Missing env: ${name}`);
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
      url: `https://sepolia.infura.io/v3/${must(INFURA_API_KEY, "INFURA_API_KEY")}`,
      accounts: PRIVATE_KEY
        ? [PRIVATE_KEY.startsWith("0x") ? PRIVATE_KEY : `0x${PRIVATE_KEY}`]
        : [],
    },
  },

  etherscan: {
    apiKey: must(ETHERSCAN_API_KEY, "ETHERSCAN_API_KEY"),
  },
};
