// This script tests deposit, borrow, withdraw, repay without delegating
const hre = require("hardhat");
const LP_ABI = require("../artifacts/contracts/LendingPool/LendingPool.sol/LendingPool.json")

const ZERO_ADX = "0x0000000000000000000000000000000000000000"

async function main() {
  const accounts = await hre.ethers.getSigners()

  const Types = await hre.ethers.getContractFactory("Types")
  const types = await Types.deploy()
  await types.deployed()

  const TestOracle = await hre.ethers.getContractFactory("TestAggregatorV3");
  const oracle = await TestOracle.deploy()
  await oracle.deployed()

  const LendingPool = await hre.ethers.getContractFactory("LendingPool", {
    libraries: {
      Types: types.address,
    }
  });
  const lendingPool = await LendingPool.deploy(
    oracle.address, // Make contract according to AggregatorV3Interface
    "80", "85", "110", "65", "10", "100"
  );

  await lendingPool.deployed();

  const provider = lendingPool.provider
  console.log("LendingPool deployed to:", lendingPool.address);

  let depositValue = hre.ethers.utils.parseEther("10")
  await lendingPool.deposit(ZERO_ADX, { value: depositValue })

  console.log("User balance After Deposit:", (await provider.getBalance(accounts[0].address)).toString())
  console.log("Contract balance After Deposit:", (await provider.getBalance(lendingPool.address)).toString(), "\n")

  await lendingPool.borrow(hre.ethers.utils.parseEther("8"), accounts[0].address)
  console.log("User balance After Borrow:", (await provider.getBalance(accounts[0].address)).toString())
  console.log("Contract balance After Borrow:", (await provider.getBalance(lendingPool.address)).toString(), "\n")

  await lendingPool.repay(accounts[0].address, { value: hre.ethers.utils.parseEther("9") })
  console.log("Repayed 9")
  console.log("User balance After Repay:", (await provider.getBalance(accounts[0].address)).toString())
  console.log("Contract balance After Repay:", (await provider.getBalance(lendingPool.address)).toString(), "\n")

  await lendingPool.withdraw(depositValue, ZERO_ADX)

  console.log("User balance:", (await provider.getBalance(accounts[0].address)).toString())
  console.log("Contract balance:", (await provider.getBalance(lendingPool.address)).toString())
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
