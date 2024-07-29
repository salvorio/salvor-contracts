const { ethers, network, upgrades } = require("hardhat")
const { expect } = require("chai")
const LendingSigner = require("../libs/LendingSigner")

describe("Lending", function () {
	before(async function () {
		// ABIs
		this.lendingCF = await ethers.getContractFactory("SalvorLendingV2")
		this.nftCollectibleCF = await ethers.getContractFactory("NFTCollectible")
		this.assetManagerCF = await ethers.getContractFactory("AssetManager")
		this.salvorGovernanceTokenCF = await ethers.getContractFactory("SalvorGovernanceToken")
		this.veARTCF = await ethers.getContractFactory("VeArt")

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

		this.veART = await upgrades.deployProxy(this.veARTCF, [this.salvorGovernanceToken.address])
		await this.veART.deployed()

		this.assetManager = await upgrades.deployProxy(this.assetManagerCF, [])
		await this.assetManager.deployed()
		await this.assetManager.setVeArtAddress(this.veART.address)

		this.lending = await upgrades.deployProxy(this.lendingCF, [])
		await this.lending.deployed()
		await this.lending.setAssetManager(this.assetManager.address)
		await this.lending.setValidator(this.signers[4].address)

		await this.assetManager.addPlatform(this.lending.address)

		this.nftCollectible = await this.nftCollectibleCF.connect(this.borrower).deploy("Salvor", "SLV", [])
		await this.nftCollectible.deployed()
		await this.nftCollectible.mint("", []) // tokenId: 1
		await this.nftCollectible.mint("", []) // tokenId: 2
		await this.nftCollectible.mint("", []) // tokenId: 3
		// await this.nftCollectible.setApprovalForAll(this.exchange.address, true)
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
		const { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.nftCollectible.address, ethers.utils.parseEther("1"))

		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[4] })
		let tokenResult = await lendingSigner2.signToken(1, voucher.salt + '1', voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)
		await this.lending.pause()
		await expect(this.lending.batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("Pausable: paused")
		await this.lending.unpause()

		await expect(this.lending.connect(this.signers[3]).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("pool is not active")

		await this.lending.setPool(this.nftCollectible.address, 604800, '18493807888372071', true)

		await expect(this.lending.connect(this.signers[3]).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("salt does not match")

		tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)

		await expect(this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("token signature has been expired")
		await this.lending.setBlockRange(40)
		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);

		await expect(this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("Insufficient balance")
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })

		tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.lender.address, this.nftCollectible.address, this.lender.address)
		await expect(this.lending.connect(this.lender).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("signer cannot borrow from own loan offer")

		tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)
		await expect(this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [signature])).to.be.revertedWith("token signature is not valid")

		tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.signers[3].address, this.nftCollectible.address, this.lender.address)
		await expect(this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("token signature does not belong to msg.sender")

		tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)
		const tx3 = await this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)
	})

	it("it should be cleared", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })

		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[4] })

		await this.lending.setBlockRange(40)
		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		await this.lending.setPool(this.nftCollectible.address, 604800, '18493807888372071', true)
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })

		const { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.nftCollectible.address, ethers.utils.parseEther("1"))
		let tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)

		const tx3 = await this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		await expect(this.lending.connect(this.lender).batchClearDebt([this.nftCollectible.address], ["1"])).to.be.revertedWith("auction period is not finished")

		await network.provider.send("evm_increaseTime", [604801])
		await network.provider.send("evm_mine")

		const tx4 = await this.lending.connect(this.lender).batchClearDebt([this.nftCollectible.address], ["1"])
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "ClearDebt").length).to.be.equal(1)
		expect(await this.nftCollectible.ownerOf("1")).to.be.equal(this.lender.address)
	})

	it("it should be repaid", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })

		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[4] })

		await this.lending.setBlockRange(40)
		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		await this.lending.setPool(this.nftCollectible.address, 604800, '18493807888372071', true)
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })
		await this.assetManager.connect(this.borrower)['deposit()']({ value: ethers.utils.parseEther("0.4") })

		const { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.nftCollectible.address, ethers.utils.parseEther("1"))
		let tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)

		const tx3 = await this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		const tx4 = await this.lending.connect(this.borrower).batchRepay([this.nftCollectible.address], ["1"])
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "Repay").length).to.be.equal(1)
		expect(await this.nftCollectible.ownerOf("1")).to.be.equal(this.borrower.address)
		expect(await this.assetManager.biddingWallets(this.lender.address)).to.be.gt(ethers.utils.parseEther("1"))
	})

	it("it should be extended", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })

		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[4] })
		const { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.nftCollectible.address, ethers.utils.parseEther("1"))

		const lendingSigner3 = new LendingSigner({ contract: this.lending, signer: this.signers[5] })
		const { voucher: voucher1, signature: signature1 } = await lendingSigner3.createOfferVoucher(this.signers[5].address, this.nftCollectible.address, ethers.utils.parseEther("1"))


		await this.lending.setBlockRange(40)
		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		await this.lending.setPool(this.nftCollectible.address, 604800, '18493807888372071', true)
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })
		await this.assetManager.connect(this.borrower)['deposit()']({ value: ethers.utils.parseEther("0.4") })
		await this.assetManager.connect(this.signers[5])['deposit()']({ value: ethers.utils.parseEther("1.1") })

		let tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)

		const tx3 = await this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		let tokenResult2 = await lendingSigner2.signToken(1, voucher1.salt, voucher1.traits, this.borrower.address, this.nftCollectible.address, this.signers[5].address)
		const tx4 = await this.lending.connect(this.borrower).batchExtend([voucher1], [signature1], [tokenResult2.voucher], [tokenResult2.signature])
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "Extend").length).to.be.equal(1)
	})

	it("make bid for dutch auction", async function () {
		const lendingSigner = new LendingSigner({ contract: this.lending, signer: this.lender })

		const lendingSigner2 = new LendingSigner({ contract: this.lending, signer: this.signers[4] })

		await this.lending.setBlockRange(40)
		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		await this.lending.setAuctionDuration(86400); // a day
		await this.lending.setDropInterval(1800); // 30 min
		await this.lending.setPool(this.nftCollectible.address, 604800, '18493807888372071', true)
		await this.assetManager.connect(this.lender)['deposit()']({ value: ethers.utils.parseEther("1") })

		const { voucher, signature } = await lendingSigner.createOfferVoucher(this.lender.address, this.nftCollectible.address, ethers.utils.parseEther("1"))
		let tokenResult = await lendingSigner2.signToken(1, voucher.salt, voucher.traits, this.borrower.address, this.nftCollectible.address, this.lender.address)

		const tx3 = await this.lending.connect(this.borrower).batchBorrow([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Borrow").length).to.be.equal(1)

		await network.provider.send("evm_increaseTime", [604801])
		await network.provider.send("evm_mine")

		await expect(this.lending.connect(this.lender).batchClearDebt([this.nftCollectible.address], ["1"])).to.be.revertedWith("auction period is not finished")


		const tx4 = await this.lending.connect(this.lender).makeBidForDutchAuctionETH(this.nftCollectible.address, "1", { value: ethers.utils.parseEther("5") })
		const receipt4 = await tx4.wait()
		expect(receipt4.events.filter(event => event.event === "DutchAuctionMadeBid").length).to.be.equal(1)
	})
})