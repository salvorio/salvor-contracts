const { ethers, network, upgrades } = require("hardhat")
const { expect } = require("chai")
const LendingSigner = require("../libs/LendingErc20Signer")
const totalToken = "10000000000000000000" // 100

describe("Lending Erc20", function () {
	before(async function () {
		// ABIs
		this.lendingCF = await ethers.getContractFactory("SalvorLendingERC20")
		this.assetManagerCF = await ethers.getContractFactory("AssetManager")
		this.salvorGovernanceTokenCF = await ethers.getContractFactory("SalvorGovernanceToken")

		// Accounts
		this.signers = await ethers.getSigners()
		this.owner = this.signers[0]
		this.lender = this.signers[1]
		this.borrower = this.signers[2]
		this.externalWallet = this.signers[3]
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
		this.salvorGovernanceToken.initialMint([this.borrower.address], [totalToken])
		this.assetManager = await upgrades.deployProxy(this.assetManagerCF, [])
		await this.assetManager.deployed()

		this.lending = await upgrades.deployProxy(this.lendingCF, [])
		await this.lending.deployed()
		await this.lending.setAssetManager(this.assetManager.address)
		await this.lending.setValidator(this.signers[6].address)

		await this.assetManager.addPlatform(this.lending.address)
	})

	it("prevent initialize multiple times", async function () {
		await expect(this.lending.initialize()).to.be.revertedWith("Initializable: contract is already initialized")
	})

	it("it should set the assetManager", async function () {
		await this.lending.setAssetManager(this.externalWallet.address)
		expect(await this.lending.assetManager()).to.be.equal(this.externalWallet.address)

		await expect(this.lending.connect(this.signers[1]).setAssetManager(this.assetManager.address)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.lending.connect(this.owner).setAssetManager("0x0000000000000000000000000000000000000000")).to.be.revertedWith("Given address must be a non-zero address")
	})

	it("it should set the validator", async function () {
		await this.lending.setValidator(this.externalWallet.address)
		expect(await this.lending.validator()).to.be.equal(this.externalWallet.address)

		await expect(this.lending.connect(this.signers[1]).setValidator(this.assetManager.address)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.lending.connect(this.owner).setValidator("0x0000000000000000000000000000000000000000")).to.be.revertedWith("Given address must be a non-zero address")
	})

	it("pause should set paused true and unpause should set false", async function () {
		expect(await this.lending.paused()).to.be.equal(false)
		await this.lending.pause()
		expect(await this.lending.paused()).to.be.equal(true)
		await this.lending.unpause()
		expect(await this.lending.paused()).to.be.equal(false)

		await expect(this.lending.connect(this.signers[1]).pause()).to.be.revertedWith("Ownable: caller is not the owner")
		await expect(this.lending.connect(this.signers[1]).unpause()).to.be.revertedWith("Ownable: caller is not the owner")
	})

	it("it should set blockRange", async function () {
		const minimumPriceLimit = 40
		await this.lending.setBlockRange(minimumPriceLimit)
		expect(await this.lending.blockRange()).to.be.equal(minimumPriceLimit)

		await expect(this.lending.connect(this.signers[1]).setBlockRange(minimumPriceLimit)).to.be.revertedWith("Ownable: caller is not the owner")
	})

	it("it should get the chain id", async function () {
		expect(await this.lending.getChainId()).to.be.equal(1337)
	})

	it("it should be borrowed", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })
		let { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.salvorGovernanceToken.address, ethers.utils.parseEther("0"), ethers.utils.parseEther("0.1"), ethers.utils.parseEther("0.01"))

		let hash = await this.lending.hashOffer(Object.values(voucher))
		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[6] })
		let tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("0.1"), this.borrower.address, hash)
		await this.lending.pause()
		await expect(this.lending.borrow(voucher, signature, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("Pausable: paused")
		await this.lending.unpause()

		await expect(this.lending.connect(this.signers[3]).borrow(voucher, signature, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("collateralized asset is not allowed")

		await this.lending.setAllowedAsset(this.salvorGovernanceToken.address, true)

		await expect(this.lending.connect(this.signers[3]).borrow(voucher, signature, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("insufficient lent amount")

		let { voucher: voucher1, signature: signature1 } = await lendingSigner.createOfferVoucher(this.lender.address, this.salvorGovernanceToken.address, ethers.utils.parseEther("1"), ethers.utils.parseEther("0.1"), ethers.utils.parseEther("0.01"))
		await expect(this.lending.connect(this.signers[3]).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("insufficient amount requested")
		let invalidVoucher = JSON.parse(JSON.stringify(voucher1))
		invalidVoucher.salt = 'asdasdasd-12123'
		hash = await this.lending.hashOffer(Object.values(voucher1))

		tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)
		await expect(this.lending.connect(this.signers[3]).borrow(invalidVoucher, signature, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("hash does not match")
		await expect(this.lending.connect(this.lender).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("signer cannot borrow from own loan offer")

		let { voucher: voucher2, signature: signature2 } = await lendingSigner.createOfferVoucher(this.signers[6].address, this.salvorGovernanceToken.address, ethers.utils.parseEther("1"), ethers.utils.parseEther("0.1"), ethers.utils.parseEther("0.01"))
		hash = await this.lending.hashOffer(Object.values(voucher2))
		tokenResult = await lendingSigner2.signToken(voucher2, ethers.utils.parseEther("1"), this.borrower.address, hash)
		await expect(this.lending.connect(this.signers[3]).borrow(voucher2, signature2, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("lender does not match")

		hash = await this.lending.hashOffer(Object.values(voucher1))
		tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)
		await expect(this.lending.connect(this.signers[5]).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("token and borrower does not match")

		const lendingSigner3 = new LendingSigner({ contract: this.lending, signer: this.signers[7] })
		tokenResult = await lendingSigner3.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)
		await expect(this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("token signature is not valid")

		tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)
		await expect(this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("token signature has been expired")
		await this.lending.setBlockRange(40)

		await expect(this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("ERC20: insufficient allowance")

		await this.salvorGovernanceToken.connect(this.borrower).approve(this.lending.address, ethers.utils.parseEther("1000"))

		await expect(this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("Insufficient balance")
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })

		const tx3 = await this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		await expect(this.lending.connect(this.borrower).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("has been already borrowed")

		tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.signers[5].address, hash)

		await expect(this.lending.connect(this.signers[5]).borrow(voucher1, signature1, tokenResult.voucher, tokenResult.signature)).to.be.revertedWith("size is filled")
	})

	it("it should be cleared", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })
		let { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.salvorGovernanceToken.address, ethers.utils.parseEther("1"), ethers.utils.parseEther("0.1"), ethers.utils.parseEther("0.01"))
		let hash = await this.lending.hashOffer(Object.values(voucher))
		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[6] })

		await this.lending.setBlockRange(40)
		await this.lending.setAllowedAsset(this.salvorGovernanceToken.address, true)

		await this.salvorGovernanceToken.connect(this.borrower).approve(this.lending.address, ethers.utils.parseEther("1000"))
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })

		let tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)

		await expect(this.lending.connect(this.lender).clearDebt(this.salvorGovernanceToken.address, this.borrower.address, voucher.salt)).to.be.revertedWith("there is not any active loan")

		const tx3 = await this.lending.connect(this.borrower).borrow(voucher, signature, tokenResult.voucher, tokenResult.signature)
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		await expect(this.lending.connect(this.lender).clearDebt(this.salvorGovernanceToken.address, this.borrower.address, voucher.salt)).to.be.revertedWith("loan period is not finished")

		await network.provider.send("evm_increaseTime", [604801])
		await network.provider.send("evm_mine")

		const tx4 = await this.lending.connect(this.lender).clearDebt(this.salvorGovernanceToken.address, this.borrower.address, voucher.salt)
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "ClearDebt").length).to.be.equal(1)

		expect(await this.salvorGovernanceToken.balanceOf(this.lender.address)).to.be.gte(0)
	})

	it("it should be repaid", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })
		let { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.salvorGovernanceToken.address, ethers.utils.parseEther("1"), ethers.utils.parseEther("0.1"), ethers.utils.parseEther("0.01"))
		let hash = await this.lending.hashOffer(Object.values(voucher))
		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[6] })

		await this.lending.setBlockRange(40)
		await this.lending.setAllowedAsset(this.salvorGovernanceToken.address, true)

		await this.salvorGovernanceToken.connect(this.borrower).approve(this.lending.address, ethers.utils.parseEther("1000"))
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })
		await this.assetManager.connect(this.borrower)['deposit()']({ value: ethers.utils.parseEther("2") })

		let tokenResult = await lendingSigner2.signToken(voucher, ethers.utils.parseEther("1"), this.borrower.address, hash)

		await expect(this.lending.connect(this.lender).repay(this.salvorGovernanceToken.address, this.lender.address, voucher.salt)).to.be.revertedWith("there is not any active loan")

		const tx3 = await this.lending.connect(this.borrower).borrow(voucher, signature, tokenResult.voucher, tokenResult.signature)
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		await network.provider.send("evm_increaseTime", [604801])
		await network.provider.send("evm_mine")

		const tx4 = await this.lending.connect(this.borrower).repay(this.salvorGovernanceToken.address, this.lender.address, voucher.salt)
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "Repay").length).to.be.equal(1)
	})
})