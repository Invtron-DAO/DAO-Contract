const { ethers, run } = require("hardhat");
const dotenv = require("dotenv");
const fs = require("fs");
const path = require("path");

// Load constructor arguments from constructor.env
dotenv.config({ path: ".env" });
dotenv.config({ path: "constructor.env", override: true });

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with address:", deployer.address);

  const priceFeedAddress = process.env._priceFeedAddress;
  const initialCeo = process.env._initialCeo;
  const initialEndorsers = process.env._initialEndorsers
    ? process.env._initialEndorsers.split(/\s*,\s*/)
    : [];
  const treasuryOwner = process.env._treasuryOwner;

  const DAO = await ethers.getContractFactory("INVTRON_DAO");
  const dao = await DAO.deploy(
    priceFeedAddress,
    initialCeo,
    initialEndorsers,
    treasuryOwner
  );
  await dao.deployed();

  const invUsdAddress = await dao.invUsdToken();
  const infoPath = path.join(__dirname, "..", "ui", "deployInfo.json");
  fs.writeFileSync(infoPath, JSON.stringify({ address: dao.address }, null, 2));
  console.log("\u2139\uFE0F Saved deployment info to", infoPath);
  console.log("\u2705 INVTRON DAO deployed at:", dao.address);
  console.log("\u2705 INV-USD Token deployed at:", invUsdAddress);

  console.log("\u23F3 Waiting for Etherscan to index...");
  await new Promise((resolve) => setTimeout(resolve, 60000)); // wait 60 seconds

  try {
    await run("verify:verify", {
      address: dao.address,
      constructorArguments: [
        priceFeedAddress,
        initialCeo,
        initialEndorsers,
        treasuryOwner,
      ],
    });
    console.log("\u2705 Contract verified on Etherscan");
  } catch (err) {
    console.error("\u274C Verification failed:", err.message || err);
  }
}

main().catch((err) => {
  console.error("\u274C Deployment script failed:", err);
  process.exit(1);
});