const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  const daoAddress = "0x83463ef9efE0ee0B350176E7088fF7CbA5730421";
  const dao = await ethers.getContractAt("INVTRON_DAO", daoAddress);

  const name = await dao.name();
  const symbol = await dao.symbol();
  const invUsdAddress = await dao.invUsdToken();

  console.log("Token:", name, "(", symbol, ")");
  console.log("INV-USD Token Address:", invUsdAddress);

  // Example: Fetch price directly from the configured feed
  const feedAddr = await dao.priceFeed();
  const feed = await ethers.getContractAt("AggregatorV3Interface", feedAddr);
  const latest = await feed.latestRoundData();
  console.log("Chainlink Price:", latest.answer.toString());

  // Example: Request whitelisting
  // const reqTx = await dao.requestWhitelisting({
  //   firstName: "Alice",
  //   lastName: "Smith",
  //   mobile: "123",
  //   zipCode: "12345",
  //   city: "Town",
  //   state: "TS",
  //   country: "US",
  //   bio: "Bio"
  // });
  // await reqTx.wait();

  // Example: Apply for CEO (must be whitelisted and have tokens)
  // const tx = await dao.applyForCeo();
  // await tx.wait();
  // console.log("Applied for CEO");
}

main().catch(console.error);
