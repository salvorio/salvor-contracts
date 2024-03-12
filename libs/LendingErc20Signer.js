const { ethers } = require("hardhat")

const { v4: uuidv4 } = require('uuid')
// These constants must match the ones used in the smart contract.
const SIGNING_DOMAIN_NAME = "SalvorLendingERC20"
const SIGNING_DOMAIN_VERSION = "1"

class ExchangeSigner {
	constructor({ contract, signer }) {
		this.contract = contract
		this.signer = signer
	}

	async createVoucher(lender, collateralizedAsset, amount = 0, price, rate) {
		const voucher = {
			lender,
			collateralizedAsset,
			salt: uuidv4(),
			amount,
			price,
			startedAt: Number((+new Date() / 1000).toFixed(0)),
			duration: 6 * 30 * 24 * 60 * 60,
			rate
		}
		const domain = await this._signingDomain()
		const types = {
			LoanOffer: [
				{ name: "lender", type: "address" },
				{ name: "collateralizedAsset", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "amount", type: "uint256" },
				{ name: "price", type: "uint256" },
				{ name: "startedAt", type: "uint256" },
				{ name: "duration", type: "uint256" },
				{ name: "rate", type: "uint256" }
			]
		}
		const signature = await this.signer._signTypedData(domain, types, voucher)
		return {
			voucher,
			signature
		}
	}

	async createOfferVoucher(lender, collateralizedAsset, amount = 0, price, rate) {
		const voucher = {
			lender,
			collateralizedAsset,
			salt: uuidv4(),
			amount,
			price,
			startedAt: Number((+new Date() / 1000).toFixed(0)),
			duration: 86400,
			rate
		}
		const domain = await this._signingDomain()
		const types = {
			LoanOffer: [
				{ name: "lender", type: "address" },
				{ name: "collateralizedAsset", type: "address" },
				{ name: "salt", type: "string" },
				{ name: "amount", type: "uint256" },
				{ name: "price", type: "uint256" },
				{ name: "startedAt", type: "uint256" },
				{ name: "duration", type: "uint256" },
				{ name: "rate", type: "uint256" }
			]
		}
		const signature = await this.signer._signTypedData(domain, types, voucher)
		return {
			voucher,
			signature
		}
	}

	async signToken(order, amount, borrower, orderHash) {
		const latestBlockNumber = await ethers.provider.getBlockNumber()
		const voucher = { orderHash, blockNumber: latestBlockNumber, amount, borrower }
		const domain = await this._signingDomain()
		const types = {
			Token: [
				{ name: "orderHash", type: "bytes32" },
				{ name: "blockNumber", type: "uint256" },
				{ name: "amount", type: "uint256" },
				{ name: "borrower", type: "address" }
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