const { ethers, run } = require("hardhat");

async function main() {
  console.log("Deploying OpaqueCredit...");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");

  const OpaqueCredit = await ethers.getContractFactory("OpaqueCredit");
  const contract = await OpaqueCredit.deploy();

  await contract.waitForDeployment();

  const address = await contract.getAddress();
  const txHash = contract.deploymentTransaction()?.hash;

  console.log("CONTRACT ADDRESS:", address);
  console.log("TX HASH:", txHash);
  console.log("Etherscan:", "https://sepolia.etherscan.io/address/" + address);

  console.log("Waiting 30s for Etherscan verification...");
  await new Promise((r) => setTimeout(r, 30000));

  try {
    await run("verify:verify", {
      address: address,
      constructorArguments: [],
    });
    console.log("Verified on Etherscan.");
  } catch (e) {
    console.log("Verification note:", e.message);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
