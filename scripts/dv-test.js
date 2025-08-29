const { ethers, run, network } = require("hardhat");
const dotenv = require("dotenv");
const fs = require("fs");
const path = require("path");

// Deployment script for INVTRON_DAO with INV-denominated voter rewards.
// Exchange state can now be queried with getExchangeState(requestId).

// Load constructor arguments from constructor.env
dotenv.config({ path: ".env" });
dotenv.config({ path: "constructor.env", override: true });

async function main() {
  if (network.name !== "sepolia") {
    throw new Error("dv-test.js deploys only to sepolia");
  }
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with address:", deployer.address);

  const priceFeedAddress = process.env._priceFeedAddress;
  const initialCeo = process.env._initialCeo;
  const initialEndorsers = process.env._initialEndorsers
    ? process.env._initialEndorsers.split(/\s*,\s*/)
    : [];
  const treasuryOwner = process.env._treasuryOwner;
  const swapContract = process.env._swapContract;

  function validateAddress(name, value) {
    if (!value || !ethers.utils.isAddress(value)) {
      throw new Error(`Invalid address for ${name}`);
    }
  }

  validateAddress("_priceFeedAddress", priceFeedAddress);
  validateAddress("_initialCeo", initialCeo);
  initialEndorsers.forEach((addr, i) =>
    validateAddress(`_initialEndorsers[${i}]`, addr)
  );
  validateAddress("_treasuryOwner", treasuryOwner);
  validateAddress("_swapContract", swapContract);

  const CONFIRMATIONS = parseInt(process.env.DEPLOY_CONFIRMATIONS || "1", 10);

  const Whitelist = await ethers.getContractFactory("WhitelistManager");
  let whitelist;
  if (process.env.WHITELIST_ADDRESS && ethers.utils.isAddress(process.env.WHITELIST_ADDRESS)) {
    whitelist = Whitelist.attach(process.env.WHITELIST_ADDRESS);
    console.log("\u2139\uFE0F Using existing WhitelistManager at:", whitelist.address);
  } else {
    console.log("\u23F3 Deploying WhitelistManager...");
    whitelist = await Whitelist.deploy();
    console.log("   tx:", whitelist.deployTransaction.hash);
    await whitelist.deployTransaction.wait(CONFIRMATIONS);
    console.log("\u2705 WhitelistManager deployed at:", whitelist.address);
  }

  const InvUsdToken = await ethers.getContractFactory("InvUsdToken");
  let invUsd;
  if (process.env.INVUSD_ADDRESS && ethers.utils.isAddress(process.env.INVUSD_ADDRESS)) {
    invUsd = InvUsdToken.attach(process.env.INVUSD_ADDRESS);
    console.log("\u2139\uFE0F Using existing InvUsdToken at:", invUsd.address);
  } else {
    console.log("\u23F3 Deploying InvUsdToken...");
    invUsd = await InvUsdToken.deploy();
    console.log("   tx:", invUsd.deployTransaction.hash);
    await invUsd.deployTransaction.wait(CONFIRMATIONS);
    console.log("\u2705 INV-USD Token deployed at:", invUsd.address);
  }

  const invUsdAddress = invUsd.address;
  const whitelistAddress = whitelist.address;

  console.log("Constructor Arguments:");
  console.log(`  _priceFeedAddress: ${priceFeedAddress}`);
  console.log(`  _initialCeo: ${initialCeo}`);
  console.log(`  _initialEndorsers: [${initialEndorsers.join(', ')}]`);
  console.log(`  _treasuryOwner: ${treasuryOwner}`);
  console.log(`  _invUsdToken: ${invUsdAddress}`);
  console.log(`  _whitelistManager: ${whitelistAddress}`);
  console.log(`  _swapContract: ${swapContract}`);

  const DAO = await ethers.getContractFactory("INVTRON_DAO");
  console.log("\u23F3 Deploying INVTRON_DAO...");
  const dao = await DAO.deploy(
    priceFeedAddress,
    initialCeo,
    initialEndorsers,
    treasuryOwner,
    invUsdAddress,
    whitelistAddress,
    swapContract
  );
  console.log("   tx:", dao.deployTransaction.hash);
  await dao.deployTransaction.wait(CONFIRMATIONS);
  await whitelist.setDao(dao.address);

  try {
    await invUsd.transferOwnership(dao.address);
  } catch (e) {
    console.warn("\u26A0\uFE0F transferOwnership skipped or failed:", e.message || e);
  }
  const infoPath = path.join(__dirname, "..", "ui", "deployInfo.json");
  fs.writeFileSync(infoPath, JSON.stringify({ address: dao.address }, null, 2));
  console.log("\u2139\uFE0F Saved deployment info to", infoPath);
  console.log("\u2705 INVTRON DAO deployed at:", dao.address);
  console.log("\u2705 INV-USD Token at:", invUsd.address);
  console.log("\u2705 WhitelistManager at:", whitelist.address);

  // Update project-details/ContractRef.txt for UI developers (include full code)
  try {
    const deployedMap = {
      INVTRON_DAO: dao.address,
      InvUsdToken: invUsd.address,
      WhitelistManager: whitelist.address,
    };
    const contractsDir = path.join(__dirname, "..", "contracts");
    const libsDir = path.join(contractsDir, "libraries");
    const items = [];
    // Top-level contracts (exclude interfaces and libraries subfolders)
    fs.readdirSync(contractsDir)
      .filter((f) => f.endsWith(".sol"))
      .sort()
      .forEach((file) => {
        const name = file.replace(/\.sol$/, "");
        const fullPath = path.join(contractsDir, file);
        const code = fs.readFileSync(fullPath, "utf8");
        items.push({
          kind: "Contract",
          name,
          source: path.posix.join("contracts", file),
          address: deployedMap[name] || "N/A",
          code,
        });
      });
    // Libraries
    if (fs.existsSync(libsDir)) {
      fs.readdirSync(libsDir)
        .filter((f) => f.endsWith(".sol"))
        .sort()
        .forEach((file) => {
          const name = file.replace(/\.sol$/, "");
          const fullPath = path.join(libsDir, file);
          const code = fs.readFileSync(fullPath, "utf8");
          items.push({
            kind: "Library",
            name,
            source: path.posix.join("contracts", "libraries", file),
            address: "N/A",
            code,
          });
        });
    }
    const headerLines = [
      "Generated Contract & Library Reference",
      `Generated by dv-test.js on ${new Date().toISOString()}`,
      `Network: ${network.name}`,
      `Deployer: ${deployer.address}`,
    ];
    const blocks = items.map((it) => [
      `${it.kind}: ${it.name}`,
      `Source: ${it.source}`,
      `Address: ${it.address}`,
      `Code:`,
      it.code.trimEnd(),
    ].join("\n"));
    const out = headerLines.join("\n") + "\n\n" + blocks.join("\n\n") + "\n";
    const refPath = path.join(__dirname, "..", "project-details", "ContractRef.txt");
    fs.writeFileSync(refPath, out, "utf8");
    console.log("\u2705 Wrote contract reference to:", refPath);
  } catch (e) {
    console.warn("\u26A0\uFE0F Could not write project-details/ContractRef.txt:", e.message || e);
  }

  // Write ABI artifacts for the UI
  try {
    const artifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "INVTRON_DAO.sol",
      "INVTRON_DAO.json"
    );
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
    const uiDir = path.join(__dirname, "..", "ui");
    const uiAbiJsonPath = path.join(uiDir, "INVTRON_DAO.json");
    const uiAbiJsPath = path.join(uiDir, "ABI.js");
    // Keep the UI artifact light: ABI only
    fs.writeFileSync(uiAbiJsonPath, JSON.stringify({ abi: artifact.abi }, null, 2));
    const header = `// Auto-generated ABI. Updated by dv-test.js on ${new Date().toISOString()}\n`;
    const jsBody = `${header}window.INVTRON_DAO_ABI = ${JSON.stringify(artifact.abi, null, 2)};\n` +
      `if (typeof module !== 'undefined') { module.exports = { INVTRON_DAO_ABI: window.INVTRON_DAO_ABI }; }\n`;
    fs.writeFileSync(uiAbiJsPath, jsBody);
    console.log("\u2705 Updated UI ABI at:", uiAbiJsonPath, "and", uiAbiJsPath);

    // WhitelistManager ABI (WL-ABI.js and WhitelistManager.json)
    const wlArtifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "WhitelistManager.sol",
      "WhitelistManager.json"
    );
    const wlArtifact = JSON.parse(fs.readFileSync(wlArtifactPath, "utf8"));
    const wlJsonPath = path.join(uiDir, "WhitelistManager.json");
    const wlJsPath = path.join(uiDir, "WL-ABI.js");
    fs.writeFileSync(wlJsonPath, JSON.stringify({ abi: wlArtifact.abi }, null, 2));
    const wlHeader = `// Auto-generated WhitelistManager ABI. Updated by dv-test.js on ${new Date().toISOString()}\n`;
    const wlJsBody = `${wlHeader}window.WHITELIST_MANAGER_ABI = ${JSON.stringify(wlArtifact.abi, null, 2)};\n` +
      `if (typeof module !== 'undefined') { module.exports = { WHITELIST_MANAGER_ABI: window.WHITELIST_MANAGER_ABI }; }\n`;
    fs.writeFileSync(wlJsPath, wlJsBody);
    console.log("\u2705 Updated UI WL ABI at:", wlJsonPath, "and", wlJsPath);

    // InvUsdToken ABI (INVUSD-ABI.js and InvUsdToken.json)
    const invusdArtifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "InvUsdToken.sol",
      "InvUsdToken.json"
    );
    const invusdArtifact = JSON.parse(fs.readFileSync(invusdArtifactPath, "utf8"));
    const invusdJsonPath = path.join(uiDir, "InvUsdToken.json");
    const invusdJsPath = path.join(uiDir, "INVUSD-ABI.js");
    fs.writeFileSync(invusdJsonPath, JSON.stringify({ abi: invusdArtifact.abi }, null, 2));
    const invusdHeader = `// Auto-generated InvUsdToken ABI. Updated by dv-test.js on ${new Date().toISOString()}\n`;
    const invusdJsBody = `${invusdHeader}window.INVUSD_ABI = ${JSON.stringify(invusdArtifact.abi, null, 2)};\n` +
      `if (typeof module !== 'undefined') { module.exports = { INVUSD_ABI: window.INVUSD_ABI }; }\n`;
    fs.writeFileSync(invusdJsPath, invusdJsBody);
    console.log("\u2705 Updated UI INVUSD ABI at:", invusdJsonPath, "and", invusdJsPath);
  } catch (e) {
    console.warn("\u26A0\uFE0F Could not write UI ABI:", e.message || e);
  }

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
        invUsd.address,
        whitelist.address,
        swapContract,
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
