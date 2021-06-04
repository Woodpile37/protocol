// Grabbed from official Polygon docs
// https://docs.matic.network/docs/develop/l1-l2-communication/state-transfer/#pre-requisite
const ADDRESSES_FOR_NETWORK = {
  5: {
    checkpointManager: "0x2890bA17EfE978480615e330ecB65333b880928e",
    fxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA",
  },
  1: {
    checkpointManager: "0x86e4dc95c7fbdbf52e33d563bbdb00823894c287",
    fxRoot: "0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2",
  },
};
const func = async function (hre) {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const chainId = await getChainId();
  const Finder = await deployments.get("Finder");

  const args = [
    ADDRESSES_FOR_NETWORK[chainId].checkpointManager,
    ADDRESSES_FOR_NETWORK[chainId].fxRoot,
    Finder.address,
  ];
  await deploy("OracleRootTunnel", {
    from: deployer,
    args,
    log: true,
  });
};
module.exports = func;
func.tags = ["OracleRootTunnel", "l1-polygon"];
