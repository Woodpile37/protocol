#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { toWei, fromWei } = web3.utils;
const { lspAddress } = require("./latest-deployment-details.json");

// Constants to update
const longTokensToSettle = toWei("1");
const shortTokensToSettle = toWei("1");

// The LSP contract allocates collateral based on the proposed price after the liveness period is complete.
const settle = async () => {
  const [deployer] = await web3.eth.getAccounts();
  const LongShortPair = getContract("LongShortPair");
  const lspContract = new web3.eth.Contract(
    LongShortPair.abi,
    lspAddress
  );

  console.log("Calling settle on the LSP contract...");
  await lspContract.methods.settle(longTokensToSettle, shortTokensToSettle).send({ from: deployer });
  console.log(`- Settled ${fromWei(longTokensToSettle)} long tokens and ${fromWei(shortTokensToSettle)} short token`);
};

// Run script.
settle()
