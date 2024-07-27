const { ethers } = require("hardhat")

const { v4: uuidv4 } = require('uuid')
// These constants must match the ones used in the smart contract.
const SIGNING_DOMAIN_NAME = "SalvorLending"
const SIGNING_DOMAIN_VERSION = "2"

class ExchangeSigner {
	constructor({ contract, signer }) {
		this.contract = contract
		this.signer = signer
	}

	async createOfferVoucher(lender, nftContractAddress, amount = 0) {
		const voucher = {
			nftContractAddress,
			lender,
			salt: uuidv4(),
			traits: 'allItems',
			duration: 6 * 30 * 24 * 60 * 60,
			amount,
			size: 1,
			startedAt: 1635826550
		}
		const domain = await this._signingDomain()
		const types = {
			LoanOffer: [
				{ name: "nftContractAddress", type: "address" },
				{ name: "lender", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "traits", type: "string" },
				{ name: "duration", type: "uint256" },
				{ name: "amount", type: "uint256" },
				{ name: "size", type: "uint256" },
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

	async signToken(tokenId, salt, traits, borrower, nftContractAddress, lender) {
		const latestBlockNumber = await ethers.provider.getBlockNumber()
		const voucher = { tokenId, salt, traits, blockNumber: latestBlockNumber, owner: borrower, nftContractAddress, lender }
		const domain = await this._signingDomain()
		const types = {
			Token: [
				{ name: "tokenId", type: "uint256" },
				{ name: "salt", type: "string" },
				{ name: "traits", type: "string" },
				{ name: "blockNumber", type: "uint256" },
				{ name: "owner", type: "address" },
				{ name: "nftContractAddress", type: "address" },
				{ name: "lender", type: "address" }
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