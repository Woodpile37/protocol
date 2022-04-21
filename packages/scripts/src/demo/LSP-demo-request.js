#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { lspAddress } = require("./latest-deployment-details.json");

// Constants to update
const requestTimestamp = Math.floor(Date.now() / 1000) - 100;

// Request a price from the Optimistic Oracle contract
const request = async () => {
  const [deployer] = await web3.eth.getAccounts();
  const LongShortPair = getContract("LongShortPair");
  const lspContract = new web3.eth.Contract(
    LongShortPair.abi,
    lspAddress
  );
  console.log(`Requesting a price from the Optimistic Oracle contract...`);
  await lspContract.methods.requestEarlyExpiration(requestTimestamp).send({ from: deployer });
  console.log("- Called expire and requested a price from the Optimistic Oracle");
};

// Main script.
request()
