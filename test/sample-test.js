const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Greeter", function () {
  it("Should deposit 10 ETH and then withdraw", async function () {
    const LendingPool = await ethers.getContractFactory(
      "0xAB594600376Ec9fD91F8e885dADF0CE036862dE0", // Make contract according to AggregatorV3Interface
      "80", "85", "110", "65", "10", "100"
    );
    const greeter = await Greeter.deploy("Hello, world!");
    await greeter.deployed();

    expect(await greeter.greet()).to.equal("Hello, world!");

    const setGreetingTx = await greeter.setGreeting("Hola, mundo!");

    // wait until the transaction is mined
    await setGreetingTx.wait();

    expect(await greeter.greet()).to.equal("Hola, mundo!");
  });
});
