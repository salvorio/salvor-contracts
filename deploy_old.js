const { ethers, upgrades } = require("hardhat")
const hre = require("hardhat")

async function main() {
	const [deployer] = await ethers.getSigners()

	console.log("Deploying contracts with the account:", deployer.address)

	console.log("Account balance:", (await deployer.getBalance()).toString())

	const ArtMarketplaceFC = await ethers.getContractFactory("ArtMarketplace")
	const MarketplaceFC = await ethers.getContractFactory("Marketplace")
	const AuctionMarketplaceFC = await ethers.getContractFactory("AuctionMarketplace")
	const DutchAuctionMarketplaceFC = await ethers.getContractFactory("DutchAuctionMarketplace")
	const PaymentManagerFC = await ethers.getContractFactory("PaymentManager")
	const SalvorGovernanceTokenFC = await ethers.getContractFactory("SalvorGovernanceToken")

	// naming will be change on production usage
	const erc20 = await SalvorGovernanceTokenFC.deploy("Test Rock", "TROCK")
	await erc20.deployed()
	console.log(`deployed contract --> erc20: ${erc20.address}`)

	await verify(erc20.address, ["Test Rock", "TROCK"])

	console.log(`verified contract --> erc20: ${erc20.address}`)

	const paymentManager = await upgrades.deployProxy(PaymentManagerFC, [])
	await paymentManager.deployed()
	console.log(`deployed contract --> paymentManager: ${paymentManager.address}`)
	const paymentImplementationAddress = await upgrades.erc1967.getImplementationAddress(paymentManager.address)
	console.log("payment implementation --> ", paymentImplementationAddress)
	const paymentAdminAddress = await upgrades.erc1967.getAdminAddress(paymentManager.address)
	console.log("payment admin --> ", paymentAdminAddress)

	const implementationAddress = await upgrades.erc1967.getImplementationAddress(paymentManager.address)
	await verify(implementationAddress, [])

	const tx1 = await paymentManager.setCompanyWallet(deployer.address)
	await tx1.wait()

	const marketplace = await upgrades.deployProxy(MarketplaceFC, [paymentManager.address])
	await marketplace.deployed()
	console.log(`deployed contract --> marketplace: ${marketplace.address}`)
	const marketplaceImplementationAddress = await upgrades.erc1967.getImplementationAddress(marketplace.address)
	console.log("marketplace implementation --> ", marketplaceImplementationAddress)
	const marketplaceAdminAddress = await upgrades.erc1967.getAdminAddress(marketplace.address)
	console.log("marketplace admin --> ", marketplaceAdminAddress)

	await verify(marketplace.address, [])

	const tx2 = await paymentManager.addPlatform(marketplace.address)
	await tx2.wait()

	const auctionMarketplace = await upgrades.deployProxy(AuctionMarketplaceFC, [paymentManager.address])
	await auctionMarketplace.deployed()
	console.log(`deployed contract --> British Auction Marketplace: ${auctionMarketplace.address}`)
	const auctionMarketplaceImplementationAddress = await upgrades.erc1967.getImplementationAddress(auctionMarketplace.address)
	console.log("auctionMarketplace implementation --> ", auctionMarketplaceImplementationAddress)
	const auctionMarketplaceAdminAddress = await upgrades.erc1967.getAdminAddress(auctionMarketplace.address)
	console.log("auctionMarketplace admin --> ", auctionMarketplaceAdminAddress)

	const txDefaultBid = await auctionMarketplace.setDefaultAuctionBidPeriod(180)
	await txDefaultBid.wait()
	console.log("default bid updated")

	await verify(auctionMarketplace.address, [])

	const tx3 = await paymentManager.addPlatform(auctionMarketplace.address)
	await tx3.wait()

	const dutchAuctionMarketplace = await upgrades.deployProxy(DutchAuctionMarketplaceFC, [paymentManager.address])
	await dutchAuctionMarketplace.deployed()
	console.log(`deployed contract --> Dutch Auction Marketplace: ${dutchAuctionMarketplace.address}`)
	const dutchAuctionMarketplaceImplementationAddress = await upgrades.erc1967.getImplementationAddress(dutchAuctionMarketplace.address)
	console.log("dutchAuctionMarketplace implementation --> ", dutchAuctionMarketplaceImplementationAddress)
	const dutchAuctionMarketplaceAdminAddress = await upgrades.erc1967.getAdminAddress(dutchAuctionMarketplace.address)
	console.log("dutchAuctionMarketplace admin --> ", dutchAuctionMarketplaceAdminAddress)

	await verify(dutchAuctionMarketplace.address, [])

	const tx4 = await paymentManager.addPlatform(dutchAuctionMarketplace.address)
	await tx4.wait()

	const artMarketplace = await upgrades.deployProxy(ArtMarketplaceFC, [erc20.address, paymentManager.address])
	await artMarketplace.deployed()
	console.log(`deployed contract --> artMarketplace: ${artMarketplace.address}`)
	const artMarketplaceImplementationAddress = await upgrades.erc1967.getImplementationAddress(artMarketplace.address)
	console.log("artMarketplace implementation --> ", artMarketplaceImplementationAddress)
	const artMarketplaceAdminAddress = await upgrades.erc1967.getAdminAddress(artMarketplace.address)
	console.log("artMarketplace admin --> ", artMarketplaceAdminAddress)

	await verify(artMarketplace.address, [])

	const tx5 = await paymentManager.addPlatform(artMarketplace.address)
	await tx5.wait()

}

main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	})

async function verify(address, constructorArguments) {
	if (['fuji', 'mainnet'].includes(process.env.HARDHAT_NETWORK)) {
		try {
			await hre.run("verify:verify", {
				address,
				constructorArguments
			});
		} catch (e) {
			if (!e._stack.includes('Reason: Already Verified')) {
				console.log(e)
				process.exit()
			}
		}
	}
}