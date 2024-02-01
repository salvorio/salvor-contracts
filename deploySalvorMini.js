const { ethers } = require("hardhat")
const hre = require("hardhat")

async function main() {
	const [deployer] = await ethers.getSigners()

	console.log("Deploying contracts with the account:", deployer.address)

	console.log("Account balance:", (await deployer.getBalance()).toString())

	const SalvorMiniCF = await ethers.getContractFactory("SalvorMini")

	const erc721SalvorMini = await SalvorMiniCF.deploy("SalvorMini", "sm")
	await erc721SalvorMini.deployed()
	console.log(`deployed contract --> erc721SalvorMini: ${erc721SalvorMini.address}`)

	await verify(erc721SalvorMini.address, ["SalvorMini", "sm"])

	console.log(`verified contract --> erc721SalvorMini: ${erc721SalvorMini.address}`)
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