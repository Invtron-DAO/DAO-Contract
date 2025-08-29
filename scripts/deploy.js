const { ethers } = require("hardhat");
const dotenv = require("dotenv");

// Load constructor arguments from constructor.env
dotenv.config({ path: "constructor.env" });

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable ${name}`);
  }
  return value;
}

function validateAddress(address, name) {
  try {
    return ethers.utils.getAddress(address);
  } catch {
    throw new Error(`Invalid address for ${name}: ${address}`);
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with address:", deployer.address);

  const priceFeedAddress = validateAddress(requireEnv("_priceFeedAddress"), "_priceFeedAddress");
  const initialCeo = validateAddress(requireEnv("_initialCeo"), "_initialCeo");
  const initialEndorsers = process.env._initialEndorsers
    ? process.env._initialEndorsers.split(/\s*,\s*/).map((addr, i) =>
        validateAddress(addr, `_initialEndorsers[${i}]`)
      )
    : [];
  const treasuryOwner = validateAddress(requireEnv("_treasuryOwner"), "_treasuryOwner");
  const invUsdAddress = validateAddress(requireEnv("_invUsdToken"), "_invUsdToken");
  const swapContract = validateAddress(requireEnv("_swapContract"), "_swapContract");

  const Whitelist = await ethers.getContractFactory("WhitelistManager");
  const whitelist = await Whitelist.deploy();
  await whitelist.deployed();

  const DAO = await ethers.getContractFactory("INVTRON_DAO");
  const dao = await DAO.deploy(
    priceFeedAddress,
    initialCeo,
    initialEndorsers,
    treasuryOwner,
    invUsdAddress,
    whitelist.address,
    swapContract
  );
  await dao.deployed();
  await whitelist.setDao(dao.address);

  const invUsd = await ethers.getContractAt("InvUsdToken", invUsdAddress);
  await invUsd.transferOwnership(dao.address);
  console.log("✅ INVTRON DAO deployed at:", dao.address);
  console.log("✅ INV-USD Token at:", invUsdAddress);
  console.log("✅ WhitelistManager at:", whitelist.address);
  }

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
