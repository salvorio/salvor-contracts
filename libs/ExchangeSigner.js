const { ethers } = require("hardhat")

const { v4: uuidv4 } = require('uuid')
// These constants must match the ones used in the smart contract.
const SIGNING_DOMAIN_NAME = "Salvor"
const SIGNING_DOMAIN_VERSION = "2"

class ExchangeSigner {
	constructor({ contract, signer }) {
		this.contract = contract
		this.signer = signer
	}

	async createVoucher(nftContractAddress, tokenId, price = 0) {
		const voucher = {
			salt: uuidv4(),
			orders: [{
				nftContractAddress,
				salt: uuidv4(),
				tokenId,
				price,
				duration: 6 * 30 * 24 * 60 * 60,
				// startedAt: Number((+new Date() / 1000).toFixed(0))
				startedAt: 1635826550
			}],
		}
		const domain = await this._signingDomain()
		const types = {
			BatchOrder: [
				{ name: "salt", type: "string" },
				{ name: "orders", type: "Order[]" }
			],
			Order: [
				{ name: "nftContractAddress", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "tokenId", type: "uint256" },
				{ name: "price", type: "uint256" },
				{ name: "duration", type: "uint256" },
				{ name: "startedAt", type: "uint256" }
			]
		}
		// console.log(domain, types, voucher)
		const signature = await this.signer._signTypedData(domain, types, voucher)
		return {
			voucher,
			signature,
		}
	}

	async createOfferVoucher(nftContractAddress, tokenId, bid = 0) {
		const voucher = {
			nftContractAddress,
			salt: uuidv4(),
			traits: 'allItems',
			tokenId,
			bid,
			duration: 6 * 30 * 24 * 60 * 60,
			size: 1,
			// startedAt: Number((+new Date() / 1000).toFixed(0)),
			startedAt: 1635826550,
			isCollectionOffer: true
		}
		const domain = await this._signingDomain()
		const types = {
			Offer: [
				{ name: "nftContractAddress", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "traits", type: "string" },
				{ name: "tokenId", type: "uint256" },
				{ name: "bid", type: "uint256" },
				{ name: "duration", type: "uint256" },
				{ name: "size", type: "uint256" },
				{ name: "startedAt", type: "uint256" },
				{ name: "isCollectionOffer", type: "bool" }
			]
		}
		// console.log(domain, types, voucher)
		const signature = await this.signer._signTypedData(domain, types, voucher)
		return {
			voucher,
			signature,
		}
	}

	async signToken(tokenId, salt, traits, sender, offerOwner, nftContractAddress) {
		const latestBlockNumber = await ethers.provider.getBlockNumber()
		const voucher = { tokenId, salt, traits, blockNumber: latestBlockNumber, sender, offerOwner, nftContractAddress }
		const domain = await this._signingDomain()
		const types = {
			Token: [
				{ name: "tokenId", type: "uint256" },
				{ name: "salt", type: "string" },
				{ name: "traits", type: "string" },
				{ name: "blockNumber", type: "uint256" },
				{ name: "sender", type: "address" },
				{ name: "offerOwner", type: "address" },
				{ name: "nftContractAddress", type: "address" }
			]
		}

		return {
			signature: await this.signer._signTypedData(domain, types, voucher),
			voucher
		}
	}

	async signCancelOrder(nftContractAddress, salt, sender, tokenId) {
		const latestBlockNumber = await ethers.provider.getBlockNumber()
		const voucher = { nftContractAddress, sender, salt, blockNumber: latestBlockNumber, tokenId }
		const domain = await this._signingDomain()
		const types = {
			CancelOrder: [
				{ name: "nftContractAddress", type: "address" },
				{ name: "sender", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "blockNumber", type: "uint256" },
				{ name: "tokenId", type: "uint256" }
			]
		}

		return {
			signature: await this.signer._signTypedData(domain, types, voucher),
			voucher
		}
	}
	async _signingDomain() {
		if (this._domain != null) {
			return this._domain
		}
		const chainId = await this.contract.getChainId()
		this._domain = {
			name: SIGNING_DOMAIN_NAME,
			version: SIGNING_DOMAIN_VERSION,
			chainId: Number(chainId),
			verifyingContract: this.contract.address,
		}
		return this._domain
	}
}

module.exports = ExchangeSigner