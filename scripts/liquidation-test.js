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

  await lendingPool.borrow(hre.ethers.utils.parseEther("8.5"), accounts[0].address)
  console.log("User balance After Borrow:", (await provider.getBalance(accounts[0].address)).toString())
  console.log("Contract balance After Borrow:", (await provider.getBalance(lendingPool.address)).toString(), "\n")

  setTimeout(async () => {
    const lendingPool1 = lendingPool.connect(accounts[1])

    console.log("Account 1 balance before liquidation:", (await provider.getBalance(accounts[1].address)).toString())
    await lendingPool1.liquidationCall(accounts[0].address, hre.ethers.utils.parseEther("8.5"), true)
    console.log("Account 1 balance after liquidation:", (await provider.getBalance(accounts[1].address)).toString())
  }, 2000)
}

main()
  .then(() => { })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
