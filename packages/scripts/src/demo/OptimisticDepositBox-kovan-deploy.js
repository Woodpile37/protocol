#!/usr/bin/env node

// Helper modules
const { getContract, web3 } = require("hardhat");
const { utf8ToHex, padRight, toWei, toBN, fromWei } = web3.utils;
const { getAddress } = require("@uma/contracts-node");

const collateralAddress = "0x489Bf230d4Ab5c2083556E394a28276C22c3B580";
const priceFeedIdentifier = padRight(utf8ToHex("UMAUSD"), 64);

// Constants
const chainId = 42;
const OptimisticDepositBox = getContract("OptimisticDepositBox", chainId);
const Timer = "0x0000000000000000000000000000000000000000";
const amountOfTokenToMint = toWei(toBN(1));

// Deploy contract and return its address.
const deploy = async () => {
  const finder = await getAddress("Finder", chainId);
  const ERC20 = getContract("ERC20");
  const collateralContract = new web3.eth.Contract(ERC20.abi, collateralAddress);
  const [deployer] = await web3.eth.getAccounts();

  const optimisticDepositBox = await OptimisticDepositBox.new(
    collateralAddress,
    finder,
    priceFeedIdentifier,
    Timer
  ).send({ from: deployer, gas: 4000000, gasPrice: 2000000000 });
  console.log("Deployed a new OptimisticDepositBox: " + optimisticDepositBox.options.address);
  
// OptimisticDepositBox needs to be able to transfer collateral on behalf of user.
await collateralContract.methods.approve(optimisticDepositBox.options.address, amountOfTokenToMint).send({ from: deployer });
console.log("- Increased OptimisticDepositBox allowance to spend collateral");

// Collateral allowance for the contract address.
const postAllowance = await collateralContract.methods.allowance(deployer, optimisticDepositBox.options.address).call();
console.log(`- Contract's collateral allowance: ${fromWei(postAllowance.toString())}`);
};

// Run script.
deploy()