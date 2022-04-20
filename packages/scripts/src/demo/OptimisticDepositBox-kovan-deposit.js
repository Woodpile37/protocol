#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { toBN, toWei, fromWei } = web3.utils;

// Constants to update
const chainId = 42;
const deployedContract = "0x4C6de5596a209d9C087C03DE1Fa80bb6a02c27f8";
const amountOfTokenToDeposit = toWei(toBN(1));

// Deposit collateral into the OptimisticDepositBox.
const deposit = async () => {
  const OptimisticDepositBox = getContract("OptimisticDepositBox", chainId);
  const ERC20 = getContract("ERC20");
  const [deployer] = await web3.eth.getAccounts();

  const optimisticDepositBox = await OptimisticDepositBox.at(deployedContract);
  const collateralAddress = await optimisticDepositBox.methods.collateralCurrency().call()
  const collateral = new web3.eth.Contract(ERC20.abi, collateralAddress);

  console.group("Depositing ERC20 into the OptimisticDepositBox...");
  await optimisticDepositBox.methods.deposit(amountOfTokenToDeposit).send({ from: deployer });
  console.log(`- Deposited ${fromWei(amountOfTokenToDeposit)} collateral into the OptimisticDepositBox`);

  // Checking the deposited balance and the "total collateral" in the OptimisticDepositBox.
  const userCollateral = await optimisticDepositBox.methods.getCollateral(deployer).call();
  const totalCollateral = await optimisticDepositBox.methods.totalOptimisticDepositBoxCollateral().call();
  const userBalance = await collateral.methods.balanceOf(deployer).call();

  console.log(`- User's deposit balance: ${fromWei(userCollateral.toString())}`);
  console.log(`- Total deposit balance: ${fromWei(totalCollateral.toString())}`);
  console.log(`- User's collateral balance: ${fromWei(userBalance.toString())}`);

  console.groupEnd();
};

// Main script.
deposit()
