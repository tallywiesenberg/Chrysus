require("@nomiclabs/hardhat-waffle");
require("hardhat-interface-generator");
require("@nomiclabs/hardhat-etherscan");
require('dotenv').config()

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: "0.8.4",
  networks: {
    hardhat: {
      forking: {
        url: "https://eth-mainnet.alchemyapi.io/v2/7dW8KCqWwKa1vdaitq-SxmKfxWZ4yPG6"
      },
    },
    rinkeby: {
      accounts: {
        mnemonic: "miss swift penalty skate expose today own stuff crew fold glare pond energy abuse cup"
      },
      url: process.env.NODE_URL
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_KEY
  }
};
