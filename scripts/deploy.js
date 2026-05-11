const hre = require("hardhat");

async function main() {
  console.log("Deploying OpaqueCredit...");

  const OpaqueCredit = await hre.ethers.getContractFactory("OpaqueCredit");

  const opaque = await OpaqueCredit.deploy();

  await opaque.waitForDeployment();

  const address = await opaque.getAddress();

  console.log("OpaqueCredit deployed to:", address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
