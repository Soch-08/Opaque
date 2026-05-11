const hre = require("hardhat");

async function main() {
  console.log("Deploying OpaqueCredit...");

  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying with account:", deployer.address);

  const OpaqueCredit = await hre.ethers.getContractFactory(
    "OpaqueCredit",
    deployer
  );

  const opaque = await OpaqueCredit.deploy();

  await opaque.waitForDeployment();

  const address = await opaque.getAddress();

  console.log("OpaqueCredit deployed to:", address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
