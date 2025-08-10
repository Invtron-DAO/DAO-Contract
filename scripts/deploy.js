const { ethers } = require("hardhat");
const dotenv = require("dotenv");

// Load constructor arguments from constructor.env
dotenv.config({ path: "constructor.env" });

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
  console.log("✅ INVTRON DAO deployed at:", dao.address);
  console.log("✅ INV-USD Token deployed at:", invUsdAddress);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
