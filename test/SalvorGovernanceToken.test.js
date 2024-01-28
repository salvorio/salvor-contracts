const { ethers, network } = require("hardhat")
const { expect } = require("chai")

const totalToken = "1000000000000000000" // 10

describe("SalvorGovernanceToken", function () {
	before(async function () {
		// ABIs
		this.salvorGovernanceTokenCF = await ethers.getContractFactory("SalvorGovernanceToken")

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

		// Contracts
		this.salvorGovernanceToken = await this.salvorGovernanceTokenCF.deploy("Test Rock", "TROCK")
	})

	it("initial mint", async function() {
		await expect(this.salvorGovernanceToken.initialMint([this.signers[1].address], [])).to.be.revertedWith("Receivers-Values mismatch")
		await expect(this.salvorGovernanceToken.connect(this.signers[1]).initialMint([this.signers[1].address], [])).to.be.revertedWith("Ownable: caller is not the owner")
		await expect(this.salvorGovernanceToken.initialMint([this.signers[1].address], [totalToken])).to.emit(this.salvorGovernanceToken, "SalvorTokenMinted")
		await expect(this.salvorGovernanceToken.initialMint([this.signers[1].address], [totalToken])).to.be.revertedWith("Tokens have already been minted")
	})

	it("snapshot", async function() {
		await expect(this.salvorGovernanceToken.connect(this.signers[1]).snapshot()).to.be.revertedWith("Ownable: caller is not the owner")
		await expect(this.salvorGovernanceToken.snapshot()).to.emit(this.salvorGovernanceToken, "Snapshot").withArgs(1)
	})
})