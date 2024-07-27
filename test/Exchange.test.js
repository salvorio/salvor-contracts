const { ethers, network, upgrades } = require("hardhat")
const { expect } = require("chai")
const ExchangeSigner = require("../libs/ExchangeSigner")

describe("Exchange", function () {
	before(async function () {
		// ABIs
		this.exchangeCF = await ethers.getContractFactory("SalvorExchangeV2")
		this.nftCollectibleCF = await ethers.getContractFactory("NFTCollectible")
		this.assetManagerCF = await ethers.getContractFactory("AssetManager")
		this.salvorGovernanceTokenCF = await ethers.getContractFactory("SalvorGovernanceToken")
		this.veARTCF = await ethers.getContractFactory("VeArt")

		// Accounts
		this.signers = await ethers.getSigners()
		this.owner = this.signers[0]
		this.seller = this.signers[1]
		this.buyer = this.signers[2]
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

		this.exchange = await upgrades.deployProxy(this.exchangeCF, [])
		await this.exchange.deployed()
		await this.exchange.setAssetManager(this.assetManager.address)
		await this.exchange.setValidator(this.signers[4].address)

		await this.assetManager.addPlatform(this.exchange.address)

		this.nftCollectible = await this.nftCollectibleCF.connect(this.seller).deploy("Salvor", "SLV", [])
		await this.nftCollectible.deployed()
		await this.nftCollectible.mint("", []) // tokenId: 1
		await this.nftCollectible.mint("", []) // tokenId: 2
		await this.nftCollectible.mint("", []) // tokenId: 3
		// await this.nftCollectible.setApprovalForAll(this.exchange.address, true)
	})

	it("prevent initialize multiple times", async function () {
		await expect(this.exchange.initialize()).to.be.revertedWith("Initializable: contract is already initialized")
	})

	it("it should set the assetManager", async function () {
		await this.exchange.setAssetManager(this.externalWallet.address)
		expect(await this.exchange.assetManager()).to.be.equal(this.externalWallet.address)

		await expect(this.exchange.connect(this.signers[1]).setAssetManager(this.assetManager.address)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.exchange.connect(this.owner).setAssetManager("0x0000000000000000000000000000000000000000")).to.be.revertedWith("Given address must be a non-zero address")
	})

	it("it should set the validator", async function () {
		await this.exchange.setValidator(this.externalWallet.address)
		expect(await this.exchange.validator()).to.be.equal(this.externalWallet.address)

		await expect(this.exchange.connect(this.signers[1]).setValidator(this.assetManager.address)).to.be.revertedWith("Ownable: caller is not the owner")

		await expect(this.exchange.connect(this.owner).setValidator("0x0000000000000000000000000000000000000000")).to.be.revertedWith("Given address must be a non-zero address")
	})

	it("pause should set paused true and unpause should set false", async function () {
		expect(await this.exchange.paused()).to.be.equal(false)
		await this.exchange.pause()
		expect(await this.exchange.paused()).to.be.equal(true)
		await this.exchange.unpause()
		expect(await this.exchange.paused()).to.be.equal(false)

		await expect(this.exchange.connect(this.signers[1]).pause()).to.be.revertedWith("Ownable: caller is not the owner")
		await expect(this.exchange.connect(this.signers[1]).unpause()).to.be.revertedWith("Ownable: caller is not the owner")
	})

	it("it should set blockRange", async function () {
		const minimumPriceLimit = 40
		await this.exchange.setBlockRange(minimumPriceLimit)
		expect(await this.exchange.blockRange()).to.be.equal(minimumPriceLimit)

		await expect(this.exchange.connect(this.signers[1]).setBlockRange(minimumPriceLimit)).to.be.revertedWith("Ownable: caller is not the owner")
	})

	it("it should get the chain id", async function () {
		expect(await this.exchange.getChainId()).to.be.equal(1337)
	})

	it("it should cancel listing", async function () {
		const exchangeSigner = new ExchangeSigner({ contract: this.exchange, signer: this.seller })
		const { voucher, signature } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))
		await this.exchange.setBlockRange(40)

		await this.exchange.pause()
		await expect(this.exchange.batchCancelOrder([voucher], [signature], [0])).to.be.revertedWith("Pausable: paused")
		await this.exchange.unpause()

		await expect(this.exchange.connect(this.signers[3]).batchCancelOrder([voucher], [signature], [0])).to.be.revertedWith("only signer")

		const tx = await this.exchange.connect(this.seller).batchCancelOrder([voucher], [signature], [0])
		const receipt = await tx.wait()
		expect(receipt.events.filter(event => event.event === "CancelOrder").length).to.be.equal(1)
		await expect(this.exchange.connect(this.seller).batchCancelOrder([voucher], [signature], [0])).to.be.revertedWith("order has already redeemed or cancelled")
	})

	it("it should buy", async function () {
		const exchangeSigner = new ExchangeSigner({ contract: this.exchange, signer: this.seller })
		const { voucher, signature } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))
		await this.exchange.pause()
		await expect(this.exchange.connect(this.buyer).batchBuy([voucher], [signature], [0])).to.be.revertedWith("Pausable: paused")
		await this.exchange.unpause()

		await this.exchange.setBlockRange(40)
		await this.exchange.connect(this.seller).batchCancelOrder([voucher], [signature], [0])
		// const blockNumBefore = await ethers.provider.getBlockNumber();
		// const blockBefore = await ethers.provider.getBlock(blockNumBefore);
		// const timestampBefore = blockBefore.timestamp;
		await expect(this.exchange.connect(this.buyer).batchBuy([voucher], [signature], [0])).to.be.revertedWith("order has already redeemed or cancelled")

		const { voucher: voucher2, signature: signature2 } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 1, ethers.utils.parseEther("0"))
		await expect(this.exchange.connect(this.buyer).batchBuy([voucher2], [signature2], [0])).to.be.revertedWith("non existent order")

		const { voucher: voucher3, signature: signature3 } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))
		await expect(this.exchange.connect(this.seller).batchBuy([voucher3], [signature3], [0])).to.be.revertedWith("signer cannot redeem own coupon")
		const exchangeSigner2 = new ExchangeSigner({ contract: this.exchange, signer: this.signers[3] })
		const { voucher: voucher4, signature: signature4 } = await exchangeSigner2.createVoucher(this.signers[3].address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))
		await expect(this.exchange.connect(this.buyer).batchBuyETH([voucher4], [signature4], [0], { value: ethers.utils.parseEther("1") })).to.be.revertedWith("ERC721: transfer caller is not owner nor approved")

		const { voucher: voucher5, signature: signature5 } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))
		await expect(this.exchange.connect(this.buyer).batchBuy([voucher5], [signature5], [0])).to.be.revertedWith("Insufficient balance")

		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		const { voucher: voucher7, signature: signature7 } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 2, ethers.utils.parseEther("1"))
		const tx2 = await this.exchange.connect(this.buyer).batchBuyETH([voucher7], [signature7], [0], { value: ethers.utils.parseEther("1") })
		const receipt2 = await tx2.wait()
		expect(receipt2.events.filter(event => event.event === "Redeem").length).to.be.equal(1)

		// function overloading
		await this.assetManager.connect(this.buyer)['deposit()']({ value: ethers.utils.parseEther("1") })
		const { voucher: voucher8, signature: signature8 } = await exchangeSigner.createVoucher(this.seller.address, this.nftCollectible.address, 3, ethers.utils.parseEther("1"))
		const tx3 = await this.exchange.connect(this.buyer).batchBuy([voucher8], [signature8], [0])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "Redeem").length).to.be.equal(1)
	})

	it("it should accept offer", async function () {
		const exchangeSigner = new ExchangeSigner({ contract: this.exchange, signer: this.buyer })
		const { voucher, signature } = await exchangeSigner.createOfferVoucher(this.buyer.address, this.nftCollectible.address, 1, ethers.utils.parseEther("1"))

		const exchangeSigner2 = new ExchangeSigner({ contract: this.exchange, signer: this.signers[4] })
		let tokenResult = await exchangeSigner2.signToken(1, voucher.salt + '1', voucher.traits, this.seller.address, this.nftCollectible.address)

		await this.exchange.pause()
		await expect(this.exchange.acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("Pausable: paused")
		await this.exchange.unpause()


		await expect(this.exchange.connect(this.signers[3]).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("salt does not match")

		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, voucher.traits, this.seller.address, this.nftCollectible.address)

		await expect(this.exchange.connect(this.buyer).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("signer cannot redeem own coupon")

		const { voucher: voucher1, signature: signature1 } = await exchangeSigner.createOfferVoucher(this.buyer.address, this.nftCollectible.address, 1, ethers.utils.parseEther("0"))
		tokenResult = await exchangeSigner2.signToken(1, voucher1.salt, voucher1.traits, this.seller.address, this.buyer.address, this.nftCollectible.address)
		await expect(this.exchange.connect(this.seller).acceptOfferBatch([voucher1], [signature1], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("non existent offer")

		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, voucher.traits, this.seller.address, this.nftCollectible.address)
		await expect(this.exchange.connect(this.seller).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [signature])).to.be.revertedWith("token signature is not valid")

		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, voucher.traits, this.signers[3].address, this.nftCollectible.address)
		await expect(this.exchange.connect(this.seller).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("token signature does not belong to msg.sender")

		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, voucher.traits, this.seller.address, this.nftCollectible.address)
		await expect(this.exchange.connect(this.seller).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("token signature has been expired")

		await this.exchange.setBlockRange(40)
		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, "test_trait", this.seller.address, this.nftCollectible.address)
		await expect(this.exchange.connect(this.seller).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])).to.be.revertedWith("traits does not match")


		await this.nftCollectible.setApprovalForAll(this.assetManager.address, true);
		await this.assetManager.connect(this.buyer)['deposit()']({ value: ethers.utils.parseEther("1") })
		tokenResult = await exchangeSigner2.signToken(1, voucher.salt, voucher.traits, this.seller.address, this.nftCollectible.address)
		const tx3 = await this.exchange.connect(this.seller).acceptOfferBatch([voucher], [signature], [tokenResult.voucher], [tokenResult.signature])
		const receipt3 = await tx3.wait()
		expect(receipt3.events.filter(event => event.event === "AcceptOffer").length).to.be.equal(1)
	})
})