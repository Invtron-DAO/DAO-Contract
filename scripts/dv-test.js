/* dv-test.js — resilient Sepolia deploy with fee bumps + pending nonce safety */

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
// Load .env first, then constructor.env (overrides for constructor args)

dotenv.config({ path: ".env" });
dotenv.config({ path: "constructor.env", override: true });

async function main() {
  // ---------- Network guard ----------
  if (network.name !== "sepolia") {
    throw new Error("dv-test.js deploys only to sepolia");
  }

  // ---------- Env (injected by your CI/local .env) ----------
  // RPC / keys (Hardhat uses these via config; referenced here for clarity)
  const INFURA_PROJECT_ID = process.env.INFURA_PROJECT_ID || "";
  const INFURA_PROJECT_SECRET = process.env.INFURA_PROJECT_SECRET || "";
  const PRIVATE_KEY = process.env.PRIVATE_KEY || "";
  const Etherscan_API_Key = process.env.Etherscan_API_Key || "";

  // Deployment tuning
  const DEPLOY_CONFIRMATIONS = Math.max(
    1,
    parseInt(process.env.DEPLOY_CONFIRMATIONS || "1", 10)
  );
  const VERIFY_ATTEMPTS = parseInt(process.env.VERIFY_ATTEMPTS || "5", 10);
  const INITIAL_WAIT_MS = parseInt(process.env.INITIAL_WAIT_MS || "20000", 10);
  const BUMP_INTERVAL_MS = parseInt(process.env.BUMP_INTERVAL_MS || "45000", 10);
  const MAX_BUMPS = parseInt(process.env.MAX_BUMPS || "6", 10);
  const DEPLOY_TX_TIMEOUT_MS = parseInt(
    process.env.DEPLOY_TX_TIMEOUT_MS || "600000",
    10
  );

  // Optional pre-deployed addresses
  const WHITELIST_ADDRESS = process.env.WHITELIST_ADDRESS;
  const INVUSD_ADDRESS = process.env.INVUSD_ADDRESS;
  const FUNDING_MANAGER_ADDRESS = process.env.FUNDING_MANAGER_ADDRESS;

  // Constructor args (from constructor.env; can be in .env as fallback)
  const priceFeedAddress = process.env._priceFeedAddress;
  const initialCeo = process.env._initialCeo;
  const initialEndorsers = process.env._initialEndorsers
    ? process.env._initialEndorsers.split(/\s*,\s*/)
    : [];
  const treasuryOwner = process.env._treasuryOwner;

  // ---------- Signer / Provider ----------
  const [deployer] = await ethers.getSigners();
  const provider = deployer.provider;

  console.log("Network:", network.name);
  console.log("Deploying with address:", deployer.address);

  // ---------- Validation ----------
  function isAddr(v) {
    try {
      return !!v && ethers.utils.isAddress(v);
    } catch {
      return false;
    }
  }
  function requireAddr(name, v) {
    if (!isAddr(v)) throw new Error(`Invalid address for ${name}: ${v}`);
  }

  requireAddr("_priceFeedAddress", priceFeedAddress);
  requireAddr("_initialCeo", initialCeo);
  initialEndorsers.forEach((a, i) => requireAddr(`_initialEndorsers[${i}]`, a));
  requireAddr("_treasuryOwner", treasuryOwner);

  const bal = await provider.getBalance(deployer.address);
  if (bal.lt(ethers.utils.parseEther("0.02"))) {
    console.warn(
      "⚠️  Low balance on Sepolia. Consider funding ~0.05 ETH to cover deploy + bumps."
    );
  }

  // ---------- Fee & send helpers (resilient pending handling) ----------
  // Multiplier as (x100 integer) to avoid float math
  function mulBN(bn, times100) {
    return bn.mul(ethers.BigNumber.from(times100)).div(100);
  }

  async function suggestFees(times100 = 200 /* default 2.00x */) {
    const fd = await provider.getFeeData();
    const base = fd.maxFeePerGas || ethers.utils.parseUnits("30", "gwei");
    const tip = fd.maxPriorityFeePerGas || ethers.utils.parseUnits("2", "gwei");
    // On testnets, be generous (miners often ignore tiny tips)
    const maxPriorityFeePerGas = mulBN(tip, Math.max(200, times100)); // ≥2x tip
    // Ensure maxFee >> base to withstand spikes
    const maxFeePerGas = mulBN(base, Math.max(200, times100)).add(
      maxPriorityFeePerGas
    );
    return { maxFeePerGas, maxPriorityFeePerGas };
  }

  // Send a tx and if it lingers, replace with higher-fee tx using SAME nonce
  async function sendAndWait(txRequest, label = "tx") {
    const nonce = await provider.getTransactionCount(
      deployer.address,
      "pending"
    );

    let attempt = 0;
    let lastHash;
    let times100 = 200; // start at 2.00x suggested baseline

    // Ensure EIP-1559 type:2 and attach fees if absent
    let fees = await suggestFees(times100);
    txRequest = {
      type: 2,
      ...txRequest,
      nonce,
      maxFeePerGas: txRequest.maxFeePerGas || fees.maxFeePerGas,
      maxPriorityFeePerGas:
        txRequest.maxPriorityFeePerGas || fees.maxPriorityFeePerGas,
    };

    while (attempt <= MAX_BUMPS) {
      attempt++;
      const txResp = await deployer.sendTransaction(txRequest);
      lastHash = txResp.hash;
      console.log(
        `📤 Sent ${label} (attempt ${attempt}/${MAX_BUMPS + 1}) nonce=${nonce} hash=${lastHash}`
      );

      // First try the normal wait (fast path)
      try {
        const rec = await txResp.wait(DEPLOY_CONFIRMATIONS);
        console.log(
          `✅ Mined ${label} at block ${rec.blockNumber} (nonce=${nonce})`
        );
        return rec;
      } catch (_) {
        // fallthrough to explicit wait with timeout
      }

      // Explicit wait with timeout (covers replacement/edge cases)
      const timeoutMs = INITIAL_WAIT_MS + (attempt - 1) * BUMP_INTERVAL_MS;
      try {
        const mined = await provider.waitForTransaction(
          lastHash,
          DEPLOY_CONFIRMATIONS,
          timeoutMs
        );
        if (mined && mined.blockNumber) {
          console.log(
            `✅ Mined ${label} (post-wait) at block ${mined.blockNumber}`
          );
          return mined;
        }
      } catch {
        // timed out
      }

      if (attempt > MAX_BUMPS) break;

      // Bump ~20–30% each round
      times100 = Math.floor(times100 * 1.25);
      fees = await suggestFees(times100);
      txRequest.maxPriorityFeePerGas = fees.maxPriorityFeePerGas;
      txRequest.maxFeePerGas = fees.maxFeePerGas;
      console.warn(
        `⚠️  ${label} still pending. Replacing with higher fees: tip=${ethers.utils.formatUnits(
          fees.maxPriorityFeePerGas,
          "gwei"
        )} gwei, maxFee=${ethers.utils.formatUnits(fees.maxFeePerGas, "gwei")} gwei`
      );
    }

    const explorer = `https://sepolia.etherscan.io/tx/${lastHash}`;
    throw new Error(
      `Gave up on ${label} after ${MAX_BUMPS + 1} attempts. Check ${explorer}`
    );
  }

  async function robustDeploy(factory, args = [], label = "contract") {
    const deployTx = factory.getDeployTransaction(...args);
    // Estimate gas with cushion
    const estimated = await provider.estimateGas({
      ...deployTx,
      from: deployer.address,
    });
    const gasLimit = estimated.mul(120).div(100); // +20%
    const rec = await sendAndWait({ ...deployTx, gasLimit }, `deploy ${label}`);
    const address = rec.contractAddress;
    if (!address) throw new Error(`No contractAddress in receipt for ${label}`);
    console.log(`🏁 ${label} deployed at ${address}`);
    return { address, receipt: rec };
  }

  // ---------- Show constructor arguments ----------
  console.log("Constructor Arguments:");
  console.log(`  _priceFeedAddress: ${priceFeedAddress}`);
  console.log(`  _initialCeo: ${initialCeo}`);
  console.log(`  _initialEndorsers: [${initialEndorsers.join(", ")}]`);
  console.log(`  _treasuryOwner: ${treasuryOwner}`);

  // ---------- Deploy / attach contracts ----------
  // WhitelistManager
  const Whitelist = await ethers.getContractFactory("WhitelistManager");
  let whitelist;
  if (isAddr(WHITELIST_ADDRESS)) {
    whitelist = Whitelist.attach(WHITELIST_ADDRESS);
    console.log("ℹ️ Using existing WhitelistManager at:", whitelist.address);
  } else {
    console.log("⏳ Deploying WhitelistManager...");
    const { address } = await robustDeploy(Whitelist, [], "WhitelistManager");
    whitelist = Whitelist.attach(address);
  }

  // InvUsdToken
  const InvUsdToken = await ethers.getContractFactory("InvUsdToken");
  let invUsd;
  if (isAddr(INVUSD_ADDRESS)) {
    invUsd = InvUsdToken.attach(INVUSD_ADDRESS);
    console.log("ℹ️ Using existing InvUsdToken at:", invUsd.address);
  } else {
    console.log("⏳ Deploying InvUsdToken...");
    const { address } = await robustDeploy(InvUsdToken, [], "InvUsdToken");
    invUsd = InvUsdToken.attach(address);
  }

  // FundingManagerContract
  const FundingMgr = await ethers.getContractFactory("FundingManagerContract");
  let fundingMgr;
  if (isAddr(FUNDING_MANAGER_ADDRESS)) {
    fundingMgr = FundingMgr.attach(FUNDING_MANAGER_ADDRESS);
    console.log(
      "ℹ️ Using existing FundingManagerContract at:",
      fundingMgr.address
    );
  } else {
    console.log("⏳ Deploying FundingManagerContract...");
    const { address } = await robustDeploy(
      FundingMgr,
      [],
      "FundingManagerContract"
    );
    fundingMgr = FundingMgr.attach(address);
  }

  // INVTRON_DAO
  const DAO = await ethers.getContractFactory("INVTRON_DAO");
  const daoArgs = [
    priceFeedAddress,
    initialCeo,
    initialEndorsers,
    treasuryOwner,
    invUsd.address,
    whitelist.address,
    fundingMgr.address,
  ];
  console.log("⏳ Deploying INVTRON_DAO...");
  const { address: daoAddress } = await robustDeploy(
    DAO,
    daoArgs,
    "INVTRON_DAO"
  );
  const dao = DAO.attach(daoAddress);

  // Wire up DAO relationships (use resilient sender)
  await sendAndWait(
    await whitelist.populateTransaction.setDao(dao.address),
    "WhitelistManager.setDao"
  );
  await sendAndWait(
    await fundingMgr.populateTransaction.setDao(dao.address),
    "FundingManagerContract.setDao"
  );
  try {
    await sendAndWait(
      await invUsd.populateTransaction.transferOwnership(dao.address),
      "InvUsdToken.transferOwnership"
    );
  } catch (e) {
    console.warn("⚠️ transferOwnership skipped or failed:", e.message || e);
  }

  // ---------- Save deployment info ----------
  const infoDir = path.join(__dirname, "..", "info");
  fs.mkdirSync(infoDir, { recursive: true });
  const infoPath = path.join(infoDir, "addressInfo.json");
  const addressInfo = {
    INVTRON_DAO_CONTRACT: dao.address,
    InvUsdToken: invUsd.address,
    WhitelistManager: whitelist.address,
    FundingManager: fundingMgr.address,
  };
  fs.writeFileSync(infoPath, JSON.stringify(addressInfo, null, 2));
  console.log("ℹ️  Saved deployment info to", infoPath);

  // ---------- Write ContractRef.txt (full code for UI devs) ----------
  try {
    const deployedMap = {
      INVTRON_DAO_CONTRACT: dao.address,
      InvUsdToken: invUsd.address,
      WhitelistManager: whitelist.address,
      FundingManager: fundingMgr.address,
    };
    const contractsDir = path.join(__dirname, "..", "contracts");
    const libsDir = path.join(contractsDir, "libraries");
    const items = [];

    // Top-level contracts
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
    const blocks = items
      .map((it) =>
        [
          `${it.kind}: ${it.name}`,
          `Source: ${it.source}`,
          `Address: ${it.address}`,
          `Code:`,
          it.code.trimEnd(),
        ].join("\n")
      )
      .join("\n\n");
    const out = headerLines.join("\n") + "\n\n" + blocks + "\n";
    const refPath = path.join(
      __dirname,
      "..",
      "project-details",
      "ContractRef.txt"
    );
    fs.mkdirSync(path.dirname(refPath), { recursive: true });
    fs.writeFileSync(refPath, out, "utf8");
    console.log("✅ Wrote contract reference to:", refPath);
  } catch (e) {
    console.warn(
      "⚠️  Could not write project-details/ContractRef.txt:",
      e.message || e
    );
  }

  // ---------- Write minimal UI ABIs ----------
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
    const uiAbiJsonPath = path.join(infoDir, "ABI.json");
    fs.writeFileSync(
      uiAbiJsonPath,
      JSON.stringify({ abi: artifact.abi }, null, 2)
    );
    console.log("✅ Updated UI ABI at:", uiAbiJsonPath);

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
    fs.writeFileSync(
      wlJsonPath,
      JSON.stringify({ abi: wlArtifact.abi }, null, 2)
    );
    console.log("✅ Updated UI WL ABI at:", wlJsonPath);

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
    fs.writeFileSync(
      fmJsonPath,
      JSON.stringify({ abi: fmArtifact.abi }, null, 2)
    );
    console.log("✅ Updated UI FR ABI at:", fmJsonPath);

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
    fs.writeFileSync(
      invusdJsonPath,
      JSON.stringify({ abi: invusdArtifact.abi }, null, 2)
    );
    console.log("✅ Updated UI INVUSD ABI at:", invusdJsonPath);
  } catch (e) {
    console.warn("⚠️  Could not write UI ABI:", e.message || e);
  }

  // ---------- Etherscan verify with retries ----------
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  console.log("⏳ Waiting briefly for Etherscan indexing…");
  await sleep(INITIAL_WAIT_MS); // short initial wait; backoff will handle the rest

  async function verifyWithRetry({ address, args = [], contract }) {
    for (let attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++) {
      try {
        const opts = { address, constructorArguments: args };
        if (contract) opts.contract = contract;
        console.log(
          `⏳ Verifying ${contract || address} (attempt ${attempt}/${VERIFY_ATTEMPTS})…`
        );
        await run("verify:verify", opts);
        console.log("✅ Verified:", contract || address);
        return;
      } catch (err) {
        const msg = (err && err.message) ? err.message : String(err);
        if (/already verified/i.test(msg)) {
          console.log("✅ Already verified:", contract || address);
          return;
        }
        if (/does not have bytecode|Unable to locate ContractCode/i.test(msg)) {
          const delay = Math.min(120000, 30000 * attempt);
          console.warn(
            `⚠️  Indexing lag for ${address}. Waiting ${Math.floor(delay / 1000)}s…`
          );
          await sleep(delay);
          continue;
        }
        console.error("❌ Verification error:", msg);
        throw err;
      }
    }
    console.warn(`⚠️  Verification attempts exhausted for ${address}`);
  }

  await verifyWithRetry({
    address: whitelist.address,
    args: [],
    contract: "contracts/WhitelistManager.sol:WhitelistManager",
  });

  await verifyWithRetry({
    address: invUsd.address,
    args: [],
    contract: "contracts/InvUsdToken.sol:InvUsdToken",
  });

  await verifyWithRetry({
    address: fundingMgr.address,
    args: [],
    contract: "contracts/FundingManagerContract.sol:FundingManagerContract",
  });

  await verifyWithRetry({
    address: dao.address,
    args: daoArgs,
    contract: "contracts/INVTRON_DAO.sol:INVTRON_DAO",
  });

  // ---------- Summary ----------
  console.log("✅ INVTRON_DAO deployed at:", dao.address);
  console.log("✅ InvUsdToken at:", invUsd.address);
  console.log("✅ WhitelistManager at:", whitelist.address);
  console.log("✅ FundingManagerContract at:", fundingMgr.address);
}

// Entrypoint
main().catch((err) => {
  console.error("❌ Deployment script failed:", err);
  process.exit(1);
});
