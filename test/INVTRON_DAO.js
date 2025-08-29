const { ethers } = require("hardhat");
const chai = require("chai");
const { expect } = chai;
chai.use(require("chai-as-promised"));

// Basic deployment test for INVTRON_DAO

describe("INVTRON_DAO", function () {
  async function deployDaoFixture() {
    const signers = await ethers.getSigners();
    const deployer = signers[0];

    // create extra wallets for additional endorsers to reach 26
    const mnemonic = "test test test test test test test test test test test junk";
    const extraEndorsers = [];
    for (let i = 20; i < 26; i++) {
      const wallet = ethers.Wallet.fromMnemonic(mnemonic, `m/44'/60'/0'/0/${i}`).connect(ethers.provider);
      await deployer.sendTransaction({ to: wallet.address, value: ethers.utils.parseEther("1") });
      extraEndorsers.push(wallet);
    }

    const initialEndorsers = signers.map((s) => s.address).concat(extraEndorsers.map((w) => w.address));

    // Deploy a simple mock price feed with 8 decimals
    const MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    const mockFeed = await MockV3Aggregator.deploy(8, 1000n * 10n ** 8n);

      const InvUsd = await ethers.getContractFactory("InvUsdToken");
      const invUsd = await InvUsd.deploy();

    const Whitelist = await ethers.getContractFactory("WhitelistManager");
    const whitelist = await Whitelist.deploy();
    await whitelist.deployed();

    const DAO = await ethers.getContractFactory("INVTRON_DAO");
    const dao = await DAO.deploy(
      mockFeed.address,
      deployer.address,
      initialEndorsers,
      deployer.address,
      invUsd.address,
      whitelist.address,
      deployer.address
    );

    await dao.deployed();
    await whitelist.setDao(dao.address);
    await invUsd.transferOwnership(dao.address);
    await whitelist.makeWhitelisted(deployer.address, true);

    return { dao, invUsd, whitelist, deployer, signers, extraEndorsers };
  }

  it("mints initial supply to deployer", async function () {
    const { dao, deployer } = await deployDaoFixture();
    const totalSupply = await dao.totalSupply();
    const expected = ethers.utils.parseUnits("1000000000", 18);
    expect(totalSupply.toString()).to.equal(expected.toString());
    expect((await dao.balanceOf(deployer.address)).toString()).to.equal(expected.toString());
  });

  it("prevents applying when a CEO is already elected", async function () {
    const { dao, whitelist, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const candidate = signers[1];
    await whitelist.makeWhitelisted(candidate.address, true);
    await dao.transfer(candidate.address, ethers.utils.parseUnits("100", 18));
    const otherCandidate = signers[2];
    await whitelist.makeWhitelisted(otherCandidate.address, true);
    await dao.transfer(otherCandidate.address, ethers.utils.parseUnits("100", 18));

    await dao.connect(candidate).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate).applyForCeo();

    const allEndorsers = signers.concat(extraEndorsers);
    const ceoVotesNeeded = (await dao.ENDORSER_VOTES_FOR_CEO_PASS()).toNumber();
    for (let i = 0; i < ceoVotesNeeded; i++) {
      await dao.connect(allEndorsers[i]).voteOnCeoByEndorser(0);
    }

    await dao.connect(deployer).delegate(deployer.address);
    await dao.connect(deployer).voteOnCeoByUser(0, true, deployer.address);

    await ethers.provider.send("evm_increaseTime", [72 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.finalizeCeoVote(0);

    await dao.connect(otherCandidate).approve(dao.address, ethers.utils.parseUnits("1", 18));

    await expect(dao.connect(otherCandidate).applyForCeo()).to.be.rejected;
  });

  it("allows anyone to activate elected CEO after delay", async function () {
    const { dao, whitelist, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const candidate = signers[1];
    await whitelist.makeWhitelisted(candidate.address, true);
    await dao.transfer(candidate.address, ethers.utils.parseUnits("100", 18));

    await dao.connect(candidate).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate).applyForCeo();

    const allEndorsers = signers.concat(extraEndorsers);
    const ceoVotesNeeded = (await dao.ENDORSER_VOTES_FOR_CEO_PASS()).toNumber();
    for (let i = 0; i < ceoVotesNeeded; i++) {
      await dao.connect(allEndorsers[i]).voteOnCeoByEndorser(0);
    }

    await dao.connect(deployer).delegate(deployer.address);
    await dao.connect(deployer).voteOnCeoByUser(0, true, deployer.address);

    await ethers.provider.send("evm_increaseTime", [72 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.finalizeCeoVote(0);

    await ethers.provider.send("evm_increaseTime", [360 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.activateElectedCeo();

    expect(await dao.currentCeo()).to.equal(candidate.address);
    expect(await dao.ceoStatus(candidate.address)).to.equal(3);
    expect(await dao.ceoStatus(deployer.address)).to.equal(0);
    expect(await dao.electedCeo()).to.equal(ethers.constants.AddressZero);
  });

  it("handles whitelist requests", async function () {
    const { dao, whitelist, signers } = await deployDaoFixture();
    const user = signers[3];
    const tx = await whitelist.connect(user).requestWhitelisting({
      firstName: "John",
      lastName: "Doe",
      mobile: "111",
      zipCode: "00000",
      city: "City",
      state: "ST",
      country: "US",
      bio: "Bio"
    });
    await tx.wait();
    let status = await whitelist.getWhitelistingReqStatus(user.address);
    expect(status).to.equal(0);
    const pending = await whitelist.getWwhitelistReqList();
    expect(pending.length).to.equal(1);
    await whitelist.ceoApproveWhitelisting([user.address], [], true);
    status = await whitelist.getWhitelistingReqStatus(user.address);
    expect(status).to.equal(1);
    expect(await whitelist.isWhitelisted(user.address)).to.be.true;
  });

  it("supports voting delegation via signature", async function () {
    const { dao, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const delegator = signers[1];
    const delegatee = signers[2];

    await dao.transfer(delegator.address, ethers.utils.parseUnits("500", 18));
    await dao.connect(delegator).delegate(delegator.address);

    await dao.connect(deployer).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(deployer).createFundingRequest({
      projectName: "Proj",
      softCapAmount: 1000 * 1e6,
      hardCapAmount: 2000 * 1e6,
      valuation: 10000 * 1e6,
      country: "US",
      websiteUrl: "https://example.com",
      ceoLinkedInUrl: "https://linkedin.com/in/ceo",
      shortDescription: "desc",
      companyRegistrationUrl: "https://example.com/reg"
    });

    const allEndorsers = signers.concat(extraEndorsers);
    const fundingVotesNeeded = (await dao.ENDORSER_VOTES_FOR_FUNDING_PASS()).toNumber();
    for (let i = 0; i < fundingVotesNeeded; i++) {
      await dao.connect(allEndorsers[i]).voteOnFundingByEndorser(0);
    }

    const chainId = (await ethers.provider.getNetwork()).chainId;
    const nonce = await dao.nonces(delegator.address);
    const latest = await ethers.provider.getBlock('latest');
    const deadline = latest.timestamp + 3600;
    const domain = { name: "INVTRON", version: "1", chainId, verifyingContract: dao.address };
    const types = { DelegateVP: [
      { name: "delegatee", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]};
    const signature = await delegator._signTypedData(domain, types, { delegatee: delegatee.address, nonce, deadline });
    const { v, r, s } = ethers.utils.splitSignature(signature);
    await dao.connect(delegatee).delegateVPbySig(delegatee.address, nonce, deadline, v, r, s);

    await dao.connect(delegatee).voteOnFundingByUser(0, true, delegator.address);
    const unlock = await dao.tokenUnlockTime(delegator.address);
    expect(unlock.toNumber()).to.be.gt(Math.floor(Date.now() / 1000));
  });

  it("enforces snapshot-based transfer lock and clears after unlock", async function () {
    const { dao, whitelist, deployer, signers } = await deployDaoFixture();
    const voter = signers[2];
    const candidate1 = signers[3];
    const candidate2 = signers[4];
    const recipient = signers[5];

    // Setup two CEO applications
    await whitelist.makeWhitelisted(candidate1.address, true);
    await dao.transfer(candidate1.address, ethers.utils.parseUnits("100", 18));
    await dao.connect(candidate1).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate1).applyForCeo();
    for (let i = 0; i < 3; i++) {
      await dao.connect(signers[i]).voteOnCeoByEndorser(0);
    }

    await whitelist.makeWhitelisted(candidate2.address, true);
    await dao.transfer(candidate2.address, ethers.utils.parseUnits("100", 18));
    await dao.connect(candidate2).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate2).applyForCeo();
    for (let i = 0; i < 3; i++) {
      await dao.connect(signers[i]).voteOnCeoByEndorser(1);
    }

    // Fund voter and self-delegate
    await dao.transfer(voter.address, ethers.utils.parseUnits("100", 18));
    await dao.connect(voter).delegate(voter.address);

    // First vote locks current balance
    await dao.connect(voter).voteOnCeoByUser(0, true, voter.address);
    expect((await dao.lockedBalanceRequirement(voter.address)).toString()).to.equal(
      ethers.utils.parseUnits("100", 18).toString()
    );

    // Cannot transfer locked portion
    await expect(
      dao.connect(voter).transfer(recipient.address, ethers.utils.parseUnits("100", 18))
    ).to.be.rejected;

    // Receive additional tokens; only excess is spendable
    await dao.transfer(voter.address, ethers.utils.parseUnits("20", 18));
    await expect(
      dao.connect(voter).transfer(recipient.address, ethers.utils.parseUnits("21", 18))
    ).to.be.rejected;
    await dao.connect(voter).transfer(recipient.address, ethers.utils.parseUnits("20", 18));

    // Vote again before unlock with higher balance, requirement increases
    await dao.transfer(voter.address, ethers.utils.parseUnits("50", 18));
    await dao.connect(voter).voteOnCeoByUser(1, true, voter.address);
    expect((await dao.lockedBalanceRequirement(voter.address)).toString()).to.equal(
      ethers.utils.parseUnits("150", 18).toString()
    );

    await expect(
      dao.connect(voter).transfer(recipient.address, ethers.utils.parseUnits("1", 18))
    ).to.be.rejected;

    // After unlock full balance is transferable and requirement clears
    await ethers.provider.send("evm_increaseTime", [73 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.connect(voter).transfer(recipient.address, ethers.utils.parseUnits("150", 18));
    expect((await dao.lockedBalanceRequirement(voter.address)).toNumber()).to.equal(0);
  });

  it("blocks delegation while locked", async function () {
    const { dao, whitelist, deployer, signers } = await deployDaoFixture();
    const voter = signers[2];
    const candidate = signers[3];
    const delegatee = signers[4];

    await whitelist.makeWhitelisted(candidate.address, true);
    await dao.transfer(candidate.address, ethers.utils.parseUnits("100", 18));
    await dao.connect(candidate).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate).applyForCeo();
    for (let i = 0; i < 3; i++) {
      await dao.connect(signers[i]).voteOnCeoByEndorser(0);
    }

    await dao.transfer(voter.address, ethers.utils.parseUnits("100", 18));
    await dao.connect(voter).delegate(voter.address);
    await dao.connect(voter).voteOnCeoByUser(0, true, voter.address);

    await expect(
      dao.connect(voter).delegate(delegatee.address)
    ).to.be.rejected;

    const chainId = (await ethers.provider.getNetwork()).chainId;
    let nonce = await dao.nonces(voter.address);
    let latest = await ethers.provider.getBlock('latest');
    let expiry = latest.timestamp + 10000;
    const domain = { name: "INVTRON", version: "1", chainId, verifyingContract: dao.address };
    const typesDelegation = { Delegation: [
      { name: "delegatee", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "expiry", type: "uint256" }
    ]};
    const typesDelegateVP = { DelegateVP: [
      { name: "delegatee", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" }
    ]};
    let sig = await voter._signTypedData(domain, typesDelegation, { delegatee: delegatee.address, nonce, expiry });
    let { v, r, s } = ethers.utils.splitSignature(sig);
    await expect(
      dao.delegateBySig(delegatee.address, nonce, expiry, v, r, s)
    ).to.be.rejected;

    nonce = await dao.nonces(voter.address);
    latest = await ethers.provider.getBlock('latest');
    let deadline = latest.timestamp + 10000;
    sig = await voter._signTypedData(domain, typesDelegateVP, { delegatee: delegatee.address, nonce, deadline });
    ({ v, r, s } = ethers.utils.splitSignature(sig));
    await expect(
      dao.connect(delegatee).delegateVPbySig(delegatee.address, nonce, deadline, v, r, s)
    ).to.be.rejected;

    await ethers.provider.send("evm_increaseTime", [73 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.connect(voter).delegate(delegatee.address);

    nonce = await dao.nonces(voter.address);
    latest = await ethers.provider.getBlock('latest');
    expiry = latest.timestamp + 10000;
    sig = await voter._signTypedData(domain, typesDelegation, { delegatee: delegatee.address, nonce, expiry });
    ({ v, r, s } = ethers.utils.splitSignature(sig));
    await dao.delegateBySig(delegatee.address, nonce, expiry, v, r, s);

    nonce = await dao.nonces(voter.address);
    latest = await ethers.provider.getBlock('latest');
    deadline = latest.timestamp + 10000;
    sig = await voter._signTypedData(domain, typesDelegateVP, { delegatee: delegatee.address, nonce, deadline });
    ({ v, r, s } = ethers.utils.splitSignature(sig));
    await dao.connect(delegatee).delegateVPbySig(delegatee.address, nonce, deadline, v, r, s);
  });
});
