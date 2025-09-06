const { ethers, run, network } = require("hardhat");
const dotenv = require("dotenv");
const fs = require("fs");
const path = require("path");

// Deployment script for INVTRON_DAO with INV-denominated voter rewards.
// Exchange state can now be queried with getExchangeState(requestId).
// Funding votes now lock only the token amount needed for the capped voting power.
// Locked tokens are excluded from subsequent voting power calculations.
// Voting power scales from 0.05% to 0.5% based on the weighted-average balance age and self-voting is disallowed for proposers and candidates.
// Voting rewards equal 22% of the vote amount registered at submission time rather than raw voting power.

// Load constructor arguments from constructor.env
dotenv.config({ path: ".env" });
dotenv.config({ path: "constructor.env", override: true });

async function main() {
  if (network.name !== "mainnet") {
    throw new Error("dv-main.js deploys only to mainnet");
  }
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with address:", deployer.address);

  const priceFeedAddress = process.env._priceFeedAddress;
  const initialCeo = process.env._initialCeo;
  const initialEndorsers = process.env._initialEndorsers
    ? process.env._initialEndorsers.split(/\s*,\s*/)
    : [];
  const treasuryOwner = process.env._treasuryOwner;

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
  // _swapContract removed from constructor

  const CONFIRMATIONS = parseInt(process.env.DEPLOY_CONFIRMATIONS || "1", 10);
  const DEPLOY_TIMEOUT = parseInt(
    process.env.DEPLOY_TX_TIMEOUT_MS || "600000",
    10
  );

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

  // Deploy or attach FundingManagerContract
  const FundingMgr = await ethers.getContractFactory("FundingManagerContract");
  let fundingMgr;
  if (process.env.FUNDING_MANAGER_ADDRESS && ethers.utils.isAddress(process.env.FUNDING_MANAGER_ADDRESS)) {
    fundingMgr = FundingMgr.attach(process.env.FUNDING_MANAGER_ADDRESS);
    console.log("\u2139\uFE0F Using existing FundingManagerContract at:", fundingMgr.address);
  } else {
    console.log("\u23F3 Deploying FundingManagerContract...");
    fundingMgr = await FundingMgr.deploy();
    console.log("   tx:", fundingMgr.deployTransaction.hash);
    await fundingMgr.deployTransaction.wait(CONFIRMATIONS);
    console.log("\u2705 FundingManagerContract deployed at:", fundingMgr.address);
  }

  // Mirror dv-test.js: Print constructor arguments for debugging
  console.log("Constructor Arguments:");
  console.log(`  _priceFeedAddress: ${priceFeedAddress}`);
  console.log(`  _initialCeo: ${initialCeo}`);
  console.log(`  _initialEndorsers: [${initialEndorsers.join(', ')}]`);
  console.log(`  _treasuryOwner: ${treasuryOwner}`);
  console.log(`  _invUsdToken: ${invUsd.address}`);
  console.log(`  _whitelistManager: ${whitelist.address}`);
  console.log(`  _fundingManager: ${fundingMgr.address}`);

  const DAO = await ethers.getContractFactory("INVTRON_DAO");
  console.log("\u23F3 Deploying INVTRON_DAO...");
  const daoTx = await DAO.getDeployTransaction(
    priceFeedAddress,
    initialCeo,
    initialEndorsers,
    treasuryOwner,
    invUsd.address,
    whitelist.address,
    fundingMgr.address
  );
  const daoSent = await deployer.sendTransaction(daoTx);
  console.log("   tx:", daoSent.hash);
  let daoReceipt;
  try {
    daoReceipt = await deployer.provider.waitForTransaction(
      daoSent.hash,
      CONFIRMATIONS,
      DEPLOY_TIMEOUT
    );
  } catch (err) {
    if (err && err.code === "TIMEOUT") {
      const explorer = `https://etherscan.io/tx/${daoSent.hash}`;
      console.warn(
        `\u26A0\uFE0F waitForTransaction timed out after ${DEPLOY_TIMEOUT}ms.\n   Check status: ${explorer}\n   Increase DEPLOY_TX_TIMEOUT_MS to wait longer.`
      );
      daoReceipt = await deployer.provider.getTransactionReceipt(daoSent.hash);
    } else {
      throw err;
    }
  }
  if (!daoReceipt || !daoReceipt.contractAddress) {
    throw new Error("INVTRON_DAO deployment failed or timed out");
  }
  const dao = DAO.attach(daoReceipt.contractAddress);
  await whitelist.setDao(dao.address);
  await fundingMgr.setDao(dao.address);

  try {
    await invUsd.transferOwnership(dao.address);
  } catch (e) {
    console.warn("\u26A0\uFE0F transferOwnership skipped or failed:", e.message || e);
  }
  const infoPath = path.join(__dirname, "..", "info", "addressInfo.json");
  const addressInfo = {
    INVTRON_DAO: dao.address,
    InvUsdToken: invUsd.address,
    WhitelistManager: whitelist.address,
    FundingManager: fundingMgr.address,
  };
  fs.writeFileSync(infoPath, JSON.stringify(addressInfo, null, 2));
  console.log("\u2139\uFE0F Saved deployment info to", infoPath);
  console.log("\u2705 INVTRON DAO deployed at:", dao.address);
  console.log("\u2705 INV-USD Token at:", invUsd.address);
  console.log("\u2705 WhitelistManager at:", whitelist.address);
  console.log("\u2705 FundingManagerContract at:", fundingMgr.address);

  // Update project-details/ContractRef.txt for UI developers (include full code)
  try {
    const deployedMap = {
      INVTRON_DAO: dao.address,
      InvUsdToken: invUsd.address,
      WhitelistManager: whitelist.address,
      FundingManager: fundingMgr.address,
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
      `Generated by dv-main.js on ${new Date().toISOString()}`,
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
    const infoDir = path.join(__dirname, "..", "info");
    const uiAbiJsonPath = path.join(infoDir, "ABI.json");
    // Keep the UI artifact light: ABI only
    fs.writeFileSync(uiAbiJsonPath, JSON.stringify({ abi: artifact.abi }, null, 2));
    console.log("\u2705 Updated UI ABI at:", uiAbiJsonPath);

    // WhitelistManager ABI
    const wlArtifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "WhitelistManager.sol",
      "WhitelistManager.json"
    );
    const wlArtifact = JSON.parse(fs.readFileSync(wlArtifactPath, "utf8"));
    const wlJsonPath = path.join(infoDir, "WL-ABI.json");
    fs.writeFileSync(wlJsonPath, JSON.stringify({ abi: wlArtifact.abi }, null, 2));
    console.log("\u2705 Updated UI WL ABI at:", wlJsonPath);

    // FundingManagerContract ABI
    const fmArtifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "FundingManagerContract.sol",
      "FundingManagerContract.json"
    );
    const fmArtifact = JSON.parse(fs.readFileSync(fmArtifactPath, "utf8"));
    const fmJsonPath = path.join(infoDir, "FM-ABI.json");
    fs.writeFileSync(fmJsonPath, JSON.stringify({ abi: fmArtifact.abi }, null, 2));
    console.log("\u2705 Updated UI FR ABI at:", fmJsonPath);

    // InvUsdToken ABI
    const invusdArtifactPath = path.join(
      __dirname,
      "..",
      "artifacts",
      "contracts",
      "InvUsdToken.sol",
      "InvUsdToken.json"
    );
    const invusdArtifact = JSON.parse(fs.readFileSync(invusdArtifactPath, "utf8"));
    const invusdJsonPath = path.join(infoDir, "INVUSD-ABI.json");
    fs.writeFileSync(invusdJsonPath, JSON.stringify({ abi: invusdArtifact.abi }, null, 2));
    console.log("\u2705 Updated UI INVUSD ABI at:", invusdJsonPath);
  } catch (e) {
    console.warn("\u26A0\uFE0F Could not write UI ABI:", e.message || e);
  }

  console.log("\u23F3 Waiting for Etherscan to index...");
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await sleep(parseInt(process.env.VERIFY_INITIAL_WAIT_MS || "60000", 10));

  async function verifyWithRetry({ address, args = [], contract }) {
    const maxAttempts = parseInt(process.env.VERIFY_ATTEMPTS || "5", 10);
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const opts = { address, constructorArguments: args };
        if (contract) opts.contract = contract;
        console.log(`\u23F3 Verifying ${contract || address} (attempt ${attempt}/${maxAttempts})...`);
        await run("verify:verify", opts);
        console.log("\u2705 Verified:", contract || address);
        return;
      } catch (err) {
        const msg = (err && err.message) ? err.message : String(err);
        if (/already verified/i.test(msg)) {
          console.log("\u2705 Already verified:", contract || address);
          return;
        }
        if (/does not have bytecode|Unable to locate ContractCode/i.test(msg)) {
          const delay = Math.min(120000, 30000 * attempt);
          console.warn(`\u26A0\uFE0F Indexing lag for ${address}. Waiting ${Math.floor(delay/1000)}s...`);
          await sleep(delay);
          continue;
        }
        console.error("\u274C Verification error:", msg);
        throw err;
      }
    }
  }

  await verifyWithRetry({ address: whitelist.address, args: [], contract: "contracts/WhitelistManager.sol:WhitelistManager" });
  await verifyWithRetry({ address: invUsd.address, args: [], contract: "contracts/InvUsdToken.sol:InvUsdToken" });
  await verifyWithRetry({ address: fundingMgr.address, args: [], contract: "contracts/FundingManagerContract.sol:FundingManagerContract" });
  await verifyWithRetry({
    address: dao.address,
    args: [
      priceFeedAddress,
      initialCeo,
      initialEndorsers,
      treasuryOwner,
      invUsd.address,
      whitelist.address,
      fundingMgr.address,
    ],
    contract: "contracts/INVTRON_DAO.sol:INVTRON_DAO",
  });
}

main().catch((err) => {
  console.error("\u274C Deployment script failed:", err);
  process.exit(1);
});
