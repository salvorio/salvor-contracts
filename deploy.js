const { ethers, upgrades } = require("hardhat")
const hre = require("hardhat")

async function main() {
	const [deployer] = await ethers.getSigners()

	console.log("Deploying contracts with the account:", deployer.address)

	console.log("Account balance:", (await deployer.getBalance()).toString())

	const ExchangeFC = await ethers.getContractFactory("SalvorExchange")
	const LendingFC = await ethers.getContractFactory("SalvorLending")
	const AssetManagerFC = await ethers.getContractFactory("AssetManager")

	const assetManager = await upgrades.deployProxy(AssetManagerFC, [])
	await assetManager.deployed()
	console.log(`deployed contract --> paymentManager: ${assetManager.address}`)
	const paymentImplementationAddress = await upgrades.erc1967.getImplementationAddress(assetManager.address)
	console.log("payment implementation --> ", paymentImplementationAddress)
	const paymentAdminAddress = await upgrades.erc1967.getAdminAddress(assetManager.address)
	console.log("payment admin --> ", paymentAdminAddress)

	await verify(assetManager, [])

	const salvorExchange = await upgrades.deployProxy(ExchangeFC, [])
	await salvorExchange.deployed()
	console.log(`deployed contract --> marketplace: ${salvorExchange.address}`)
	const exchangeImplementationAddress = await upgrades.erc1967.getImplementationAddress(salvorExchange.address)
	console.log("marketplace implementation --> ", exchangeImplementationAddress)
	const exchangeAdminAddress = await upgrades.erc1967.getAdminAddress(salvorExchange.address)
	console.log("marketplace admin --> ", exchangeAdminAddress)

	await verify(salvorExchange.address, [])

	const tx1 = await assetManager.addPlatform(salvorExchange.address)
	await tx1.wait()

	const tx2 = await salvorExchange.setAssetManager(assetManager.address)
	await tx2.wait()

	const salvorLending = await upgrades.deployProxy(LendingFC, [])
	await salvorLending.deployed()
	console.log(`deployed contract --> lending: ${salvorLending.address}`)
	const lendingImplementationAddress = await upgrades.erc1967.getImplementationAddress(salvorLending.address)
	console.log("lending implementation --> ", lendingImplementationAddress)
	const lendingAdminAddress = await upgrades.erc1967.getAdminAddress(salvorLending.address)
	console.log("lending admin --> ", lendingAdminAddress)

	await verify(salvorLending.address, [])

	const tx3 = await assetManager.addPlatform(salvorLending.address)
	await tx3.wait()

	const tx4 = await salvorLending.setAssetManager(assetManager.address)
	await tx4.wait()
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