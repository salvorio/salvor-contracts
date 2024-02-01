# Salvor

This repository contains all contracts for Salvor.

* SalvorGovernanceToken
* VeART
* NFTCollectible (template ERC721 contract)
* SalvorLending
* SalvorExchange
* AssetManager

# Docs

For technical and functional requirements and more detailed information about the VeArt, AssetManager, SalvorExchange and SalvorLending contracts, please refer to the documentation for the contracts, which can be accessed via the link provided below.

[**VeART Documantaion**](https://docs.google.com/document/d/1wNrZ8olOkYNMOCRqIa-LwWDA3EgKFnE_ryGoomo0Xlw)

[**Asset Manager**](https://docs.google.com/document/d/1dWBhrruURxBSgsTaF0S3rRverXHSJmauH0oUiwNlaJk/edit#heading=h.ehvdfv9zxvvd)

[**Salvor Exchange**](https://docs.google.com/document/d/1pHO9dltzR0vf7tzkupcysuT1oQQ59dHOsXrG95VbRkE/edit#heading=h.ehvdfv9zxvvd)

[**Salvor Lending**](https://docs.google.com/document/d/1zXyk2OYSyE8Aci3b8yZ6IkQBIUyYKV9N2cmEXakoEgA/edit#heading=h.ehvdfv9zxvvd)


![](https://cdn.salvor.io/site/images/l_schema.png)

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

In order to properly organize the contracts, the **AssetManager** contract must be deployed first.
Once deployed, the obtained **AssetManager** address needs to be set in the exchange and lending contracts using their respective `setAssetManager` function.
Additionally, the deployed **SalvorExchange** and **SalvorLending** contracts' addresses must be whitelisted on the AssetManager contract using the `addPlatform` function.

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
npx hardhat verify --network fuji ASSET_MANAGER_CONTRACT_ADDRESS
npx hardhat verify --network fuji GOVARNANCE_TOKEN_CONTRACT_ADDRESS
npx hardhat verify --network fuji EXCHANGE_CONTRACT_ADDRESS
npx hardhat verify --network fuji LENDING_CONTRACT_ADDRESS
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

### NOTE:
**ERC721Dummy.sol** and **SalvorMini** is only for testing purpose. No real use on production.

**CancelLoans** in **SalvorLending.sol** and  **batchCancelOffer** in **SalvorExchange.sol** is not used anymore.

### The contracts below are example contracts that have been deployed on the Fuji network. They should be used as references for understanding the functionality of the contracts on the Fuji network. However, it is important to note that they are not meant to be used in production and may not have the same level of security and reliability as the contracts deployed on a live network.

[VeArt](https://testnet.snowtrace.io/address/0xc6CD5ed983729DEa05F2d2bD7E99DC6422bb2912)

[AssetManager](https://testnet.snowtrace.io/address/0xd54a09cc48098acf67a82c68fb637f892f886591)

[Exchange](https://testnet.snowtrace.io/address/0xc2ab35b30127cfac1ea55228ddabfdc6040a3cec)

[Lending](https://testnet.snowtrace.io/address/0xff971acb9e9a8dc8951cc6a184103cad85e3f1ea)

[GovernanceToken](https://testnet.snowtrace.io/address/0xC3d64c244D53e743f6CFb72A342DCBF89D267187)

