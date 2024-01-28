const { ethers, network, upgrades } = require("hardhat")
const { expect } = require("chai")

const totalToken = "1000000000000000000000000" // 1M


describe("Art Staking", function () {
	before(async function () {
		// ABIs
		this.salvorGovernanceTokenCF = await ethers.getContractFactory("SalvorGovernanceToken")
		this.veARTCF = await ethers.getContractFactory("VeArt")
		this.erc721CollectibleCF = await ethers.getContractFactory("ERC721Dummy")
		this.erc721SalvorMiniCF = await ethers.getContractFactory("SalvorMini")

		// Accounts
		this.signers = await ethers.getSigners()
		this.owner = this.signers[0]
	})
	beforeEach(async function () {
		await network.provider.request({
			method: "hardhat_reset",
			params: [
				{
					forking: {
						jsonRpcUrl: "https://api.avax.network/ext/bc/C/rpc",
						blockNumber: 6413723,
					},
					live: false,
					saveDeployments: true,
					tags: ["test", "local"],
				},
			],
		})

		this.salvorGovernanceToken = await this.salvorGovernanceTokenCF.deploy("Test Rock", "TROCK")

		this.veART = await upgrades.deployProxy(this.veARTCF, [this.salvorGovernanceToken.address])
		await this.veART.deployed()

	
		const receivers = [this.salvorGovernanceToken.address, this.owner.address, this.signers[2].address, this.veART.address]
		await this.salvorGovernanceToken.initialMint(receivers, [totalToken, totalToken, totalToken, totalToken])

		this.erc721Collectible = await this.erc721CollectibleCF.deploy("S", "s")
		await this.erc721Collectible.deployed()

		this.erc721SalvorMini = await this.erc721SalvorMiniCF.deploy(this.owner.address)

	})

	it("deploy", async function() {
		const tempVeART = await upgrades.deployProxy(this.veARTCF, [this.salvorGovernanceToken.address])
		await expect(tempVeART.initialize(this.salvorGovernanceToken.address)).to.be.revertedWith("Initializable: contract is already initialized")
	})

	it("pause should set paused true and unpause should set false", async function () {
		expect(await this.veART.paused()).to.be.equal(false)
		await this.veART.pause()
		expect(await this.veART.paused()).to.be.equal(true)
		await this.veART.unpause()
		expect(await this.veART.paused()).to.be.equal(false)

		await expect(this.veART.connect(this.signers[1]).pause()).to.be.revertedWith("Ownable: caller is not the owner")
		await expect(this.veART.connect(this.signers[1]).unpause()).to.be.revertedWith("Ownable: caller is not the owner")
	})


	it("set max cap", async function() {
		await expect(this.veART.connect(this.signers[1]).setMaxCap(10)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.veART.setMaxCap(10)).to.emit(this.veART, "MaxCapUpdated")
	})

	it("set art reward generation rate", async function() {
		await expect(this.veART.connect(this.signers[1]).setARTGenerationRate(10)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.veART.setARTGenerationRate(10)).to.emit(this.veART, "ArtGenerationRateUpdated")
	})

	it("total supply", async function() {
		expect(await this.veART.totalSupply()).to.be.equal(0)
	})

	it("balance of", async function() {
		expect(await this.veART.balanceOf(this.signers[1].address)).to.be.equal(0)
	})

	it("Get Boosted Generation Rate", async function() {
		expect(await this.veART.getBoostedGenerationRate(this.signers[1].address)).to.be.equal(await this.veART.veARTgenerationRate())
	})

	it("name", async function() {
		expect(await this.veART.name()).to.be.equal("SalvorVeArt")
	})

	it("symbol", async function() {
		expect(await this.veART.symbol()).to.be.equal("veART")
	})

	it("decimals", async function() {
		expect(await this.veART.decimals()).to.be.equal(18)
	})

	it("ether balance", async function() {
		expect(await this.veART.getBalance()).to.be.equal(ethers.utils.parseEther("0"))
	})

	it("deposit art", async function() {
		await this.erc721Collectible.setVeART(this.veART.address);
		await this.veART.pause()
		await expect(this.veART.depositART(0)).to.be.revertedWith("Pausable: paused")
		await this.veART.unpause()

		// ensures that the call is not made from a smart contract, unless it is on the whitelist.
		await expect(this.erc721Collectible.depositART(0)).to.be.revertedWith('Error: Unauthorized smart contract access')

		await this.veART.addPlatform(this.erc721Collectible.address);

		await expect(this.erc721Collectible.depositART(0)).to.be.revertedWith('Error: Deposit amount must be greater than zero')

		await expect(this.veART.depositART(0)).to.be.revertedWith('Error: Deposit amount must be greater than zero')
		await expect(this.veART.depositART('2000000000000000000000000')).to.be.revertedWith('Error: Insufficient balance to deposit the specified amount')

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")
		await this.salvorGovernanceToken.approve(this.veART.address, '900000000000000000000000')
		expect(this.veART.depositART('900000000000000000000000')).to.emit(this.veART, 'DepositART')
	})

	it("withdraw art", async function() {
		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});
		await this.veART.pause()
		await expect(this.veART.withdrawART(0)).to.be.revertedWith("Pausable: paused")
		await this.veART.unpause()

		await expect(this.veART.withdrawART(0)).to.be.revertedWith('Error: amount to withdraw cannot be zero')
		await expect(this.veART.withdrawART('2000000000000000000000000')).to.be.revertedWith('Error: not enough balance')

		await this.salvorGovernanceToken.approve(this.veART.address, '98000000000000000000000')
		await this.veART.depositART('98000000000000000000000')

		await this.salvorGovernanceToken.connect(this.signers[2]).approve(this.veART.address, '99000000000000000000000')
		await this.veART.connect(this.signers[2]).depositART('99000000000000000000000')

		await network.provider.send("evm_increaseTime", [132])
		await network.provider.send("evm_mine")

		await this.veART.harvestVeART(this.owner.address)

		await network.provider.send("evm_increaseTime", [137])
		await network.provider.send("evm_mine")
		await this.veART.harvestVeART(this.signers[2].address)

		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});
		await expect(this.veART.withdrawART('98000000000000000000000')).to.emit(this.veART, 'WithdrawART')

		await expect(this.veART.connect(this.signers[2]).withdrawART('99000000000000000000000')).to.emit(this.veART, 'WithdrawART')
	})

	it("withdraw all art", async function() {
		await this.veART.pause()
		await expect(this.veART.withdrawAllART()).to.be.revertedWith("Pausable: paused")
		await this.veART.unpause()

		await expect(this.veART.withdrawAllART()).to.be.revertedWith('Error: amount to withdraw cannot be zero')

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await expect(this.veART.withdrawAllART()).to.emit(this.veART, 'WithdrawART')

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.veART.harvestVeART(this.owner.address)
		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.veART.withdrawAllART()
	})

	it("harvest veART", async function() {
		await this.veART.pause()
		await expect(this.veART.harvestVeART(this.owner.address)).to.be.revertedWith("Pausable: paused")
		await this.veART.unpause()

		await expect(this.veART.harvestVeART(this.owner.address)).to.be.revertedWith('Error: user has no stake')

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await expect(this.veART.harvestVeART(this.owner.address)).to.emit(this.veART, 'ClaimedVeART')
	})

	it("claimable veART", async function() {
		expect(await this.veART.claimableVeART(this.owner.address)).to.be.eq(0)

		await this.veART.setMaxCap(1)

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')
		// to reach max cap
		await network.provider.send("evm_increaseTime", [1000000000000000])
		await network.provider.send("evm_mine")

		expect(await this.veART.claimableVeART(this.owner.address)).to.be.gt(0)
	})

	it("pending reward", async function() {
		await this.salvorGovernanceToken.approve(this.veART.address, '100000000000000000000000')
		await this.veART.depositART('100000000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.veART.harvestVeART(this.owner.address)
		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		expect(Number((await this.veART.pendingRewards(this.owner.address)).toString())).to.be.gt(0)
	})

	it("pending art reward", async function() {
		expect(Number((await this.veART.pendingARTRewards(this.owner.address)).toString())).to.be.eq(0)

		await this.salvorGovernanceToken.approve(this.veART.address, '10000000000000000000')
		await this.veART.depositART('10000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		await this.veART.harvestVeART(this.owner.address)
		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});

		await this.salvorGovernanceToken.approve(this.veART.address, '10000000000000000000')
		await this.veART.depositART('10000000000000000000')

		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")

		expect(Number((await this.veART.pendingARTRewards(this.owner.address)).toString())).to.be.gt(0)

		await this.veART.setARTGenerationRate(0)

		await this.veART.claimEarnings(this.owner.address)
		await network.provider.send("evm_increaseTime", [100])
		await network.provider.send("evm_mine")
		expect(Number((await this.veART.pendingARTRewards(this.owner.address)).toString())).to.be.eq(0)
	})

	it("claim earnings", async function() {
		await this.veART.pause()
		await expect(this.veART.claimEarnings(this.owner.address)).to.be.revertedWith("Pausable: paused")
		await this.veART.unpause()

		await this.salvorGovernanceToken.approve(this.veART.address, '10000000000000000000')
		await this.veART.depositART('10000000000000000000')

		await network.provider.send("evm_increaseTime", [1])
		await network.provider.send("evm_mine")

		await this.veART.harvestVeART(this.owner.address)
		await this.owner.sendTransaction({
			to: this.veART.address,
			value: ethers.utils.parseEther("10"),
		});

		await network.provider.send("evm_increaseTime", [1])
		await network.provider.send("evm_mine")

		await expect(this.veART.claimEarnings(this.owner.address))
			.to.emit(this.veART, 'ClaimReward')
			.and
			.to.emit(this.veART, 'ClaimARTReward')


		await this.veART.setARTGenerationRate("1000000000000000000000000") // 1m/sec

		await network.provider.send("evm_increaseTime", [10])
		await network.provider.send("evm_mine")

		await this.veART.claimEarnings(this.owner.address)

		await this.veART.setARTGenerationRate("0")

		await network.provider.send("evm_increaseTime", [10])
		await network.provider.send("evm_mine")

		await this.veART.claimEarnings(this.owner.address)
	})
})