const { ethers, network } = require("hardhat")
const { expect } = require("chai")

describe("NftCollectible and Royalty", function () {
	before(async function () {
		// ABIs
		this.nftCollectibleCF = await ethers.getContractFactory("NFTCollectible")
		this.royaltyCF = await ethers.getContractFactory("Royalty")

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
		this.nftCollectible = await this.nftCollectibleCF.deploy("Salvor", "SLV", [[this.signers[1].address, 1000]])
		await this.nftCollectible.deployed()

		// normally we don't plan to use it as seperated contract. In here we try to cover every functions on this contract.
		this.royalty = await this.royaltyCF.deploy([[this.signers[1].address, 1000]], 2500)
	})

	it("it should returns the balance of contract", async function () {
		const balance = await this.nftCollectible.balance()
		const expectedBalance = ethers.utils.formatEther(ethers.utils.parseEther("0"))
		expect(ethers.utils.formatEther(balance)).to.be.equal(expectedBalance)
	})

	it("it set base token uri", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).setBaseTokenURI("")).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.setBaseTokenURI("salvor")
		expect(await this.nftCollectible.baseTokenURI()).to.be.equal("salvor")
	})

	it("it set base extension", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).setBaseExtension("")).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.setBaseExtension("com")
		expect(await this.nftCollectible.baseExtension()).to.be.equal("com")
	})

	it("it set token uri", async function () {
		await expect(this.nftCollectible.setTokenURI(1, "salvor")).to.be.revertedWith("ERC721URIStorage: URI set of nonexistent token")
		await expect(this.nftCollectible.connect(this.signers[1]).setTokenURI(1, "salvor")).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.mint("", []) // tokenId 1
		await this.nftCollectible.setTokenURI(1, "salvor")
		expect(await this.nftCollectible.tokenURI(1)).to.be.equal("salvor")
	})

	it("it checks supports interface", async function () {
		expect(await this.nftCollectible.supportsInterface("0x2a55205a")).to.be.equal(true)
		expect(await this.nftCollectible.supportsInterface("0x3a44205a")).to.be.equal(false)
	})

	it("it should mint nft", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).mint("", [])).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.mint("", []) // tokenId 1
		expect(await this.nftCollectible.ownerOf(1)).to.be.equal(this.owner.address)
		expect(await this.nftCollectible.tokenURI(1)).to.be.equal("")

		await this.nftCollectible.mint("salvor", []) // tokenId 2
		expect(await this.nftCollectible.tokenURI(2)).to.be.equal("salvor")

		await this.nftCollectible.mint("salvor", [[this.signers[3].address, 1000]]) // tokenId 3
		const royalties = await this.nftCollectible.getTokenRoyalties(3)
		expect(royalties.length).to.be.equal(1)
		expect(royalties[0][0]).to.be.equal(this.signers[3].address)
		expect(royalties[0][1]).to.be.equal(1000)

		await expect(this.nftCollectible.tokenURI(4)).to.be.revertedWith("ERC721Metadata: URI query for nonexistent token")

		await this.nftCollectible.setBaseTokenURI("salvorbase")
		// salvorbase + tokenId
		expect(await this.nftCollectible.tokenURI(1)).to.be.equal("salvorbase1")
	})

	it("it should set defaultRoyaltyReceiver", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).setDefaultRoyaltyReceiver(this.signers[2].address)).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.setDefaultRoyaltyReceiver(this.signers[2].address)
		expect(await this.nftCollectible.defaultRoyaltyReceiver()).to.be.equal(this.signers[2].address)
		expect((await this.nftCollectible.getDefaultRoyalties()).length).to.be.equal(1)

		await this.nftCollectible.setDefaultRoyaltyReceiver("0x0000000000000000000000000000000000000000")
		expect((await this.nftCollectible.getDefaultRoyalties()).length).to.be.equal(0)
	})

	it("it should save royalties", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).saveRoyalties(1, [])).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.mint("", []) // tokenId 1
		await this.nftCollectible["safeTransferFrom(address,address,uint256)"](this.owner.address, this.signers[1].address, 1)
		await expect(this.nftCollectible.saveRoyalties(1, [])).to.be.revertedWith("token does not belongs to contract owner")
		await this.nftCollectible.mint("", []) // tokenId 2
		await this.nftCollectible.saveRoyalties(2, [[this.signers[2].address, 1000], ["0x0000000000000000000000000000000000000000", 0]])
		await expect((await this.nftCollectible.getTokenRoyalties(2)).length).to.be.equal(1)

		await expect(this.nftCollectible.saveRoyalties(2, [[this.signers[2].address, 1000], [this.signers[2].address, 2000]])).to.be.revertedWith("Royalty total value should be <= maxPercentage")
	})

	it("it should save default royalties", async function () {
		await expect(this.nftCollectible.connect(this.signers[1]).setDefaultRoyalties([])).to.be.revertedWith("Ownable: caller is not the owner")

		await this.nftCollectible.mint("", []) // tokenId 1
		await this.nftCollectible.setDefaultRoyalties([[this.signers[2].address, 1000], ["0x0000000000000000000000000000000000000000", 0]])
		await expect((await this.nftCollectible.getDefaultRoyalties()).length).to.be.equal(1)

		await expect(this.nftCollectible.setDefaultRoyalties([[this.signers[2].address, 1000], [this.signers[2].address, 2000]])).to.be.revertedWith("Royalty total value should be <= maxPercentage")
	})

	it("it should return royalty info", async function () {
		await this.nftCollectible.mint("", []) // tokenId 1
		await this.nftCollectible.setDefaultRoyalties([[this.signers[2].address, 1000], ["0x0000000000000000000000000000000000000000", 0]])
		const royaltyInfo1 = await this.nftCollectible.royaltyInfo(1, ethers.utils.parseEther("1"))
		await expect(royaltyInfo1.receiver).to.be.equal(await this.nftCollectible.defaultRoyaltyReceiver())
		await expect(royaltyInfo1.royaltyAmount).to.be.equal(ethers.utils.parseEther("0.1"))

		await this.nftCollectible.setDefaultRoyalties([])
		const royaltyInfo2 = await this.nftCollectible.royaltyInfo(1, ethers.utils.parseEther("1"))
		await expect(royaltyInfo2.receiver).to.be.equal("0x0000000000000000000000000000000000000000")
		await expect(royaltyInfo2.royaltyAmount).to.be.equal(ethers.utils.parseEther("0"))

		await this.nftCollectible.saveRoyalties(1, [[this.signers[2].address, 1000], [this.signers[3].address, 500]])
		const royaltyInfo3 = await this.nftCollectible.royaltyInfo(1, ethers.utils.parseEther("1"))
		await expect(royaltyInfo3.receiver).to.be.equal(await this.nftCollectible.defaultRoyaltyReceiver())
		await expect(royaltyInfo3.royaltyAmount).to.be.equal(ethers.utils.parseEther("0.15"))
	})

	it("it should return multi royalty info", async function () {
		await this.nftCollectible.mint("", []) // tokenId 1
		await this.nftCollectible.saveRoyalties(1, [[this.signers[2].address, 1000], [this.signers[3].address, 500]])
		const royaltyInfo = await this.nftCollectible.multiRoyaltyInfo(1, ethers.utils.parseEther("1"))

		await expect(royaltyInfo.length).to.be.equal(2)
		await expect(royaltyInfo[0].account).to.be.equal(this.signers[2].address)
		await expect(royaltyInfo[0].value).to.be.equal(ethers.utils.parseEther("0.1"))
		await expect(royaltyInfo[1].account).to.be.equal(this.signers[3].address)
		await expect(royaltyInfo[1].value).to.be.equal(ethers.utils.parseEther("0.05"))
	})

	it("it should save royalties for seperated royalty contract", async function () {
		await this.royalty.saveRoyalties(1, [[this.signers[2].address, 1000], ["0x0000000000000000000000000000000000000000", 0]])
		await expect((await this.royalty.getTokenRoyalties(1)).length).to.be.equal(1)

		await expect(this.royalty.saveRoyalties(1, [[this.signers[2].address, 1000], [this.signers[2].address, 2000]])).to.be.revertedWith("Royalty total value should be <= maxPercentage")
	})

	it("it should set defaultRoyaltyReceiver for seperated royalty contract", async function () {

		await this.royalty.setDefaultRoyaltyReceiver(this.signers[2].address)
		expect(await this.royalty.defaultRoyaltyReceiver()).to.be.equal(this.signers[2].address)
		expect((await this.royalty.getDefaultRoyalties()).length).to.be.equal(1)

		await this.royalty.setDefaultRoyaltyReceiver("0x0000000000000000000000000000000000000000")
		expect((await this.royalty.getDefaultRoyalties()).length).to.be.equal(0)
	})

	it("it should save default royalties for seperated royalty contract", async function () {

		await this.royalty.setDefaultRoyalties([[this.signers[2].address, 1000], ["0x0000000000000000000000000000000000000000", 0]])
		await expect((await this.royalty.getDefaultRoyalties()).length).to.be.equal(1)

		await expect(this.royalty.setDefaultRoyalties([[this.signers[2].address, 1000], [this.signers[2].address, 2000]])).to.be.revertedWith("Royalty total value should be <= maxPercentage")
	})

	it("it should check interfaceId for seperated royalty contract", async function () {
		// checks erc165 interfaceId
		expect(await this.royalty.supportsInterface("0x01ffc9a7")).to.be.equal(true)
	})
})