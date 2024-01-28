const { ethers, upgrades } = require("hardhat")
const hre = require("hardhat")

async function main() {
	const [deployer] = await ethers.getSigners()

	console.log("Deploying contracts with the account:", deployer.address)

	console.log("Account balance:", (await deployer.getBalance()).toString())

	const VeArtCF = await ethers.getContractFactory("VeArt")
	const erc20ArtTokenAddress = "0xC3d64c244D53e743f6CFb72A342DCBF89D267187"

	const veArt = await upgrades.deployProxy(VeArtCF, [erc20ArtTokenAddress])
	await veArt.deployed()
	console.log(`deployed contract --> veArt: ${veArt.address}`)
	const veArtImplementationAddress = await upgrades.erc1967.getImplementationAddress(veArt.address)
	console.log("veArt implementation --> ", veArtImplementationAddress)
	const veArtAdminAddress = await upgrades.erc1967.getAdminAddress(veArt.address)
	console.log("veArt admin --> ", veArtAdminAddress)

	await verify(veArt.address, [])

	console.log(`verified contract --> veArt: ${veArt.address}`)
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
			console.log(e)
			if (!e._stack.includes('Reason: Already Verified')) {
				console.log(e)
				process.exit()
			}
		}
	}
}