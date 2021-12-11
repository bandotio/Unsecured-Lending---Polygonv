// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const LP_ABI = require("../artifacts/contracts/LendingPool/LendingPool.sol/LendingPool.json")

const ZERO_ADX = "0x0000000000000000000000000000000000000000"

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy
  const Types = await hre.ethers.getContractFactory("Types")
  const types = await Types.deploy()
  await types.deployed()

  const Token = await hre.ethers.getContractFactory("ERC20Blacklistable")

  const sToken = await Token.deploy("0", "S-Token", "STOKEN", 18)
  const dToken = await Token.deploy("0", "d-Token", "STOKEN", 18)
  await sToken.deployed()
  await dToken.deployed()

  // const TestOracle = await hre.ethers.getContractFactory("TestAggregatorV3");
  // const oracle = await TestOracle.deploy()
  // await oracle.deployed()

  const LendingPool = await hre.ethers.getContractFactory("LendingPool", {
    libraries: {
      Types: types.address,
    }
  });
  const lendingPool = await LendingPool.deploy(
    "0xAB594600376Ec9fD91F8e885dADF0CE036862dE0", // Make contract according to AggregatorV3Interface
    "80", "85", "110", "65", "10", "100"
  );

  await lendingPool.deployed();

  // const LENDING_POOL_ADDRESS = "0x737b8F095E3c575a6Ae5FE1711AdB8F271E20269"
  // const lendingPool = hre.ethers.Contract(LENDING_POOL_ADDRESS, LP_ABI, hre.)
  console.log("LendingPool deployed to:", lendingPool.address);

  let depositValue = hre.ethers.utils.parseEther("10")
  await lendingPool.deposit(ZERO_ADX, { value: depositValue })
  await lendingPool.withdraw(depositValue, ZERO_ADX)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
