#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { fromWei } = web3.utils;

const chainId = 42;
const deployedContract = "0x4C6de5596a209d9C087C03DE1Fa80bb6a02c27f8";

// Withdraw from OptimisticDepositBox.
const withdraw = async () => {
  const ERC20 = getContract("ERC20");
  const OptimisticDepositBox = getContract("OptimisticDepositBox", chainId);
  const optimisticDepositBox = await OptimisticDepositBox.at(deployedContract);

  const collateralAddress = await optimisticDepositBox.methods.collateralCurrency().call()
  const collateral = new web3.eth.Contract(ERC20.abi, collateralAddress);
  
  const accounts = await web3.eth.getAccounts();
  const [deployer] = accounts;

  console.group("Withdrawing ERC20 from OptimisticDepositBox...");

  // The user can withdraw their requested USD amount.
  await optimisticDepositBox.methods.executeWithdrawal().send({ from: deployer });
  console.log("- Executed withdrawal. This also settles and gets the resolved price within the withdrawal function.");

  // Let's check the token balances. At an exchange rate of (1 ETH = $2000 USD) and given a requested
  // withdrawal amount of $10,000, the OptimisticDepositBox should have withdrawn ($10,000/$2000) 5 wETH.
  const userCollateral = await optimisticDepositBox.methods.getCollateral(accounts[0]).call();
  const totalCollateral = await optimisticDepositBox.methods.totalOptimisticDepositBoxCollateral().call();
  const userBalance = await collateral.methods.balanceOf(accounts[0]).call();

  console.log(`- User's deposit balance: ${fromWei(userCollateral.toString())}`);
  console.log(`- Total deposit balance: ${fromWei(totalCollateral.toString())}`);
  console.log(`- User's wETH balance: ${fromWei(userBalance.toString())}`);

  console.groupEnd();
  return;
};

// Main script.
withdraw()
