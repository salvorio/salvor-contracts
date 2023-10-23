# VeArt.sol Audit Information

For tecnical and functional requirements and more detailed information about the VeArt contract, please refer to the documentation for the VeArt, which can be accessed via the link provided below.

[**VeART Documantaion**](https://docs.google.com/document/d/1wNrZ8olOkYNMOCRqIa-LwWDA3EgKFnE_ryGoomo0Xlw/edit)


The Hacken Team has previously audited the other contracts included in this repository. 
 

# Salvor

This repository contains all contracts for Salvor.

* SalvorGovernanceToken
* VeART
* ArtMarketplace
* Marketplace
* AuctionMarketplace
* DutchAuctionMarketplace
* PaymentManager
* NFTCollectible (template contract)

![](https://cdn.salvor.io/site/images/scheme_3.png)

## Requirements

* Node v14.18.0
* Npm v8.1.3

## Deployment

- Make a copy of `.env.example` and rename it `.env`. Must be filled with the correct values to deploy on fujinet or mainnet. For the local environment it can be set with dummy values.
- `WALLET_PR_KEY` is deployer wallet private key.
- `SNOWTRACE` snowtrace api key to verify contracts.

```
WALLET_PR_KEY='9ef92333bd48e7a927b7cc40c38d5e0b90a669d820e7e39d6cce3ed3eea9f29e'
SNOWTRACE=XYZ
```

```
npm install
```

```
npx hardhat compile
```

In order to organize contracts together the **PaymentManager** must deployed first and received payment contract address must be passed to the other marketplace contracts on deployment as a parameter.
And every marketplace platform must be whitelisted via `addPlatform` on `paymentManager`.
In order to deploy the **ArtMarketplace** contract, the **GovarnanceToken** contract must be deployed first and the address of the **GovarnanceToken** contract must be passed as a parameter to the **ArtMarketplace** contract.

``deploy.js`` configured to handle above explanation.

```
npx hardhat run --network fuji deploy.js
```

It is crucial to acknowledge that the new contract (VeART) requires funding with both ART and AVAX tokens in order to function optimally. For demonstration purposes, we have provided a sample contract named SalvorMini, which can enhance the generation rate through the burnSalvorMiniToBoostVeART function. However, it is important to note that SalvorMini should not be considered as a final version and should not be part of any audit process. In order to deploy the **VeART** contract, the **GovarnanceToken** contract must be deployed first and the address of the **GovarnanceToken** contract must be passed as a parameter to the **VeART** contract.

```
npx hardhat run --network fuji deployVeART.js
```

In order to boost the generation rate by burning SalvorMini, the sample contract should be deployed as indicated below and the resulting address value should be set in the VeART contract using the setSalvorMini function.

```
npx hardhat run --network fuji deploySalvorMini.js
```


```
npx hardhat verify --network fuji PAYMENT_MANAGER_CONTRACT_ADDRESS
npx hardhat verify --network fuji GOVARNANCE_TOKEN_CONTRACT_ADDRESS
npx hardhat verify --network fuji MARKETPLACE_CONTRACT_ADDRESS
npx hardhat verify --network fuji AUCTION_MARKETPLACE_CONTRACT_ADDRESS
npx hardhat verify --network fuji DUTCH_AUCTION_MARKETPLACE_CONTRACT_ADDRESS
npx hardhat verify --network fuji ART_MARKETPLACE_CONTRACT_ADDRESS
npx hardhat verify --network fuji VEART_CONTRACT_ADDRESS
```

### NOTE:
``npx hardhat node`` must be run to deploy on localhost and the process must be kept running, then run the **deploy.js** in a different process.

```
npx hardhat node
```

```
npx hardhat run --network localhost deploy.js
```

## Running tests and coverage
```
npx hardhat test
```
```
npx hardhat coverage
```

**Coverage results:**

| File                        | Statements | Branches |
|-----------------------------|------------|----------|
| ArtMarketplace.sol          | 100%       | 85.33%   |
| AuctionMarketplace.sol      | 97.8%      | 96.08%   |
| DutchAuctionMarketplace.sol | 100%       | 96.15%   |
| Marketplace.sol             | 100%       | 91.51%   |
| PaymentManager.sol          | 100%       | 93.94%   |
| NFTCollectible.sol          | 100%       | 100%     |
| SalvorGovernanceToken.sol          | 100%       | 100%     |
| VeArt.sol          | 98.17%       | 80.33%     |

### NOTE:
**ERC721Dummy.sol** and **SalvorMini** is only for testing purpose. No real use on production.

### The contracts below are example contracts that have been deployed on the Fuji network. They should be used as references for understanding the functionality of the contracts on the Fuji network. However, it is important to note that they are not meant to be used in production and may not have the same level of security and reliability as the contracts deployed on a live network.

[ArtMarketplace](https://testnet.snowtrace.io/address/0x867cb9f79b3a1a283dcf728e68188bd73c0ec00a)

[VeArt](https://testnet.snowtrace.io/address/0xc6CD5ed983729DEa05F2d2bD7E99DC6422bb2912)

[Marketplace](https://testnet.snowtrace.io/address/0xf31d0abb570d33ad2118969442eba7f5c698098a)

[AuctionMarketplace](https://testnet.snowtrace.io/address/0xa76993588c669b4872af7d89c37a1852e55165f5)

[DutchAuctionMarketplace](https://testnet.snowtrace.io/address/0xf1ef5fab1a36ffc69b3cb3e3814686b90f11e80e)

[PaymentManager](https://testnet.snowtrace.io/address/0x8edA2c8837eeBaDC6275dFA33273C446aCC853FA)

[GovernanceToken](https://testnet.snowtrace.io/address/0xC3d64c244D53e743f6CFb72A342DCBF89D267187)


