#!/usr/bin/env node

// Helper modules
const { getAddress } = require("@uma/contracts-node");
const { getContract, web3 } = require("hardhat");
const { toBN, toWei, utf8ToHex, padRight } = web3.utils;

// Constants to update
const chainId = 42
const deployedContract = "0x4C6de5596a209d9C087C03DE1Fa80bb6a02c27f8";
const requestTimestamp = "1650467120";
const priceFeedIdentifier = padRight(utf8ToHex("UMAUSD"), 64);
const ancillaryData = "0x";
const exchangeRate = toWei(toBN(20)); // 1 ETH = $2000

// Propose a price for OptimisticDepositBox request.
const propose = async () => {
  const accounts = await web3.eth.getAccounts();
  const [deployer] = accounts;
  const optimisticOracleContract = await getContract("OptimisticOracle");
  const oracleAddress = await getAddress("OptimisticOracle", chainId);
  const optimisticOracle = new web3.eth.Contract(optimisticOracleContract.abi, oracleAddress);

  console.group("Proposing a price request from OptimisticDepositBox...");
  // Propose a price to the Optimistic Oracle for the OptimisticDepositBox contract. This price must be a
  // positive integer.
  await optimisticOracle.methods
    .proposePriceFor(
      accounts[0],
      deployedContract,
      priceFeedIdentifier,
      requestTimestamp,
      ancillaryData,
      exchangeRate
    )
    .send({ from: deployer });
  console.log(`- Proposed a price of ${exchangeRate}`);

  console.groupEnd();
  return;
};

// Main script.
propose()
