#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { toBN, toWei, fromWei } = web3.utils;

// Constants to update
const chainId = 42;
const deployedContract = "0x4C6de5596a209d9C087C03DE1Fa80bb6a02c27f8";
const amountInUsdToWithdraw = toWei(toBN(100)); // Withdraw USD denominated collateral ($100)

// Withdraw from OptimisticDepositBox.
const request = async () => {
  const OptimisticDepositBox = getContract("OptimisticDepositBox", chainId);
  const optimisticDepositBox = await OptimisticDepositBox.at(deployedContract);
  const [deployer] = await web3.eth.getAccounts();

  console.group("Requesting ERC20 withdraw from OptimisticDepositBox");

  await optimisticDepositBox.methods.requestWithdrawal(amountInUsdToWithdraw).send({ from: deployer });
  console.log(`- Submitted a withdrawal request for ${fromWei(amountInUsdToWithdraw)} USD of collateral`);

  console.groupEnd();
  return;
};

// Run script.
request()
