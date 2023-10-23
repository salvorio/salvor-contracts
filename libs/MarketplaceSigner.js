const { v4: uuidv4 } = require('uuid')
// These constants must match the ones used in the smart contract.
const SIGNING_DOMAIN_NAME = "Salvor"
const SIGNING_DOMAIN_VERSION = "1"

class MarketplaceSigner {
	constructor({ contract, signer }) {
		this.contract = contract
		this.signer = signer
	}

	async createVoucher(nftContractAddress, tokenId, price = 0, shareholders) {
		const voucher = { nftContractAddress, salt: uuidv4(), tokenId, price, shareholders }
		const domain = await this._signingDomain()
		const types = {
			Order: [
				{ name: "nftContractAddress", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "tokenId", type: "uint256" },
				{ name: "price", type: "uint256" },
				{ name: "shareholders", type: "Shareholder[]" }
			],
			Shareholder: [
				{ name: "account", type: "address" },
				{ name: "value", type: "uint96" }
			]
		}
		// console.log(domain, types, voucher)
		const signature = await this.signer._signTypedData(domain, types, voucher)
		return {
			voucher,
			signature,
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

module.exports = MarketplaceSigner