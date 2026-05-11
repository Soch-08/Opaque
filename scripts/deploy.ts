import { ethers, run } from "hardhat";

async function main() {
  console.log("─────────────────────────────────");
  console.log("  Deploying OpaqueCredit contract");
  console.log("─────────────────────────────────");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH. Get Sepolia ETH from sepoliafaucet.com first.");
  }

  console.log("\nDeploying...");
  const OpaqueCredit = await ethers.getContractFactory("OpaqueCredit");
  const contract = await OpaqueCredit.deploy();

  console.log("Waiting for deployment confirmation...");
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  const txHash = contract.deploymentTransaction()?.hash;

  console.log("\n✅ OpaqueCredit deployed successfully!");
  console.log("─────────────────────────────────────────────────────");
  console.log("Contract address :", address);
  console.log("Transaction hash :", txHash);
  console.log("Etherscan link   :", `https://sepolia.etherscan.io/address/${address}`);
  console.log("─────────────────────────────────────────────────────");
  console.log("\n📋 NEXT STEP:");
  console.log(`   Open index.html and replace CONTRACT_ADDRESS with:`);
  console.log(`   "${address}"`);

  // Wait 6 blocks then verify on Etherscan
  console.log("\nWaiting 30 seconds before Etherscan verification...");
  await new Promise((resolve) => setTimeout(resolve, 30000));

  try {
    console.log("Verifying on Etherscan...");
    await run("verify:verify", {
      address: address,
      constructorArguments: [],
    });
    console.log("✅ Contract verified on Etherscan!");
    console.log(`   https://sepolia.etherscan.io/address/${address}#code`);
  } catch (error: any) {
    if (error.message.includes("Already Verified")) {
      console.log("✅ Already verified on Etherscan.");
    } else {
      console.log("⚠️  Verification failed (not critical):", error.message);
    }
  }
}

main().catch((error) => {
  console.error("\n❌ Deployment failed:");
  console.error(error.message);
  process.exit(1);
});
