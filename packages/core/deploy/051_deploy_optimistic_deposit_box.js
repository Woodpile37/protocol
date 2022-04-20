const { ZERO_ADDRESS } = require("@uma/common");

const func = async function (hre) {
  const { deployments, getNamedAccounts, web3 } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const Finder = await deployments.get("Finder");
  const Timer = (await deployments.getOrNull("Timer")) || { address: ZERO_ADDRESS };
  const priceIdentifier = "0x4554485553440000000000000000000000000000000000000000000000000000";

  await deploy("OptimisticDepositBox", {
    from: deployer,
    args: ["0xd0A1E359811322d97991E03f863a0C30C2cF029C", Finder.address, priceIdentifier, Timer.address],
    log: true,
    skipIfAlreadyDeployed: false,
  });
};
module.exports = func;
func.tags = ["OptimisticDepositBox"];
func.dependencies = ["Finder", "Timer"];