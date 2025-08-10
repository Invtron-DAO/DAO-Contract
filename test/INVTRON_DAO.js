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

    const DAO = await ethers.getContractFactory("INVTRON_DAO");
    const dao = await DAO.deploy(
      mockFeed.address,
      deployer.address,
      initialEndorsers,
      deployer.address
    );

    await dao.deployed();
    await dao.makeWhitelisted(deployer.address, true);

    return { dao, deployer, signers, extraEndorsers };
  }

  it("mints initial supply to deployer", async function () {
    const { dao, deployer } = await deployDaoFixture();
    const totalSupply = await dao.totalSupply();
    const expected = ethers.utils.parseUnits("1000000000", 18);
    expect(totalSupply.toString()).to.equal(expected.toString());
    expect((await dao.balanceOf(deployer.address)).toString()).to.equal(expected.toString());
  });

  it("prevents applying when a CEO is already elected", async function () {
    const { dao, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const candidate = signers[1];

    await dao.makeWhitelisted(candidate.address, true);
    await dao.transfer(candidate.address, ethers.utils.parseUnits("100", 18));
    const otherCandidate = signers[2];
    await dao.makeWhitelisted(otherCandidate.address, true);
    await dao.transfer(otherCandidate.address, ethers.utils.parseUnits("100", 18));

    await dao.connect(candidate).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate).applyForCeo({
      firstName: "Alice",
      lastName: "Smith",
      mobile: "123",
      zipCode: "12345",
      city: "Town",
      state: "TS",
      country: "US",
      bio: "CEO"
    });

    const allEndorsers = signers.concat(extraEndorsers);
    for (let i = 0; i < 26; i++) {
      await dao.connect(allEndorsers[i]).voteOnCeoByEndorser(0);
    }

    await dao.connect(deployer).delegate(deployer.address);
    await dao.connect(deployer).voteOnCeoByUser(0, true, deployer.address);

    await ethers.provider.send("evm_increaseTime", [72 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    await dao.finalizeCeoVote(0);

    await dao.connect(otherCandidate).approve(dao.address, ethers.utils.parseUnits("1", 18));

    await expect(
      dao.connect(otherCandidate).applyForCeo({
        firstName: "Bob",
        lastName: "Brown",
        mobile: "456",
        zipCode: "67890",
        city: "City",
        state: "ST",
        country: "US",
        bio: "Other"
      })
    ).to.be.rejected;
  });

  it("allows anyone to activate elected CEO after delay", async function () {
    const { dao, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const candidate = signers[1];

    await dao.makeWhitelisted(candidate.address, true);
    await dao.transfer(candidate.address, ethers.utils.parseUnits("100", 18));

    await dao.connect(candidate).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(candidate).applyForCeo({
      firstName: "Alice",
      lastName: "Smith",
      mobile: "123",
      zipCode: "12345",
      city: "Town",
      state: "TS",
      country: "US",
      bio: "CEO"
    });

    const allEndorsers = signers.concat(extraEndorsers);
    for (let i = 0; i < 26; i++) {
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

  it("supports voting delegation via signature", async function () {
    const { dao, deployer, signers, extraEndorsers } = await deployDaoFixture();
    const delegator = signers[1];
    const delegatee = signers[2];

    await dao.transfer(delegator.address, ethers.utils.parseUnits("500", 18));
    await dao.connect(delegator).delegate(delegator.address);

    await dao.connect(deployer).approve(dao.address, ethers.utils.parseUnits("1", 18));
    await dao.connect(deployer).createFundingRequest({
      projectName: "Proj",
      softCapAmount: 1000,
      hardCapAmount: 2000,
      valuation: 10000,
      country: "US",
      websiteUrl: "https://example.com",
      ceoLinkedInUrl: "https://linkedin.com/in/ceo",
      shortDescription: "desc",
      companyRegistrationUrl: "https://example.com/reg"
    });

    const allEndorsers = signers.concat(extraEndorsers);
    for (let i = 0; i < 26; i++) {
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
});
