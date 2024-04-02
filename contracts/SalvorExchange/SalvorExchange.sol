//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
// Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
// These functions can be used to verify that a message was signed by the holder of the private keys of a given address.
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
// is a standard for hashing and signing of typed structured data.
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "../AssetManager/IAssetManager.sol";
import "./lib/LibOrder.sol";

/**
 * @title SalvorExchange Contract
 * @notice This contract enables users to accept offers and execute purchases of ERC721 NFTs.
 */
contract SalvorExchange is Initializable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    string private constant SIGNING_DOMAIN = "Salvor";
    string private constant SIGNATURE_VERSION = "2";
    using ECDSAUpgradeable for bytes32;

    mapping(bytes32 => uint256) public sizes;

    mapping(bytes32 => bool) public fills;

    mapping(bytes32 => bool) public offerFills;

    address public assetManager;

    address public validator;

    uint256 public blockRange;

    uint256 public version2timestamp;

    // events
    event Cancel(address indexed collection, uint256 indexed tokenId, string salt);
    event Redeem(address indexed collection, uint256 indexed tokenId, string salt, uint256 value);
    event CancelOffer(address indexed collection, uint256 indexed tokenId, string salt, bool isCollectionOffer);
    event AcceptOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer, string salt, uint256 bid);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __EIP712_init_unchained(SIGNING_DOMAIN, SIGNATURE_VERSION);
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /**
    * @notice Sets a new asset manager address. Only the contract owner can perform this action.
    * @param _assetManager The address to be appointed as the new asset manager, must not be the zero address.
    */
    function setAssetManager(address _assetManager) external onlyOwner addressIsNotZero(_assetManager) {
        assetManager = _assetManager;
    }

    /**
    * @notice Assigns a new validator address. Restricted to actions by the contract owner.
    * @param _validator The new validator's address, which cannot be the zero address.
    */
    function setValidator(address _validator) external onlyOwner addressIsNotZero(_validator) {
        validator = _validator;
    }

    /**
    * @notice Updates the block range parameter within the contract. This action can only be performed by the contract owner.
    * @param _blockRange The new block range value to be set.
    */
    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
    }

    /**
    * @dev pause contract, restricting certain operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
    * @dev unpause contract, enabling certain operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
    * @dev Initializes the contract for version 2
     */
    function initializeV2() external onlyOwner {
        if (version2timestamp == 0) {
            version2timestamp = block.timestamp;
        }
    }

    function getRemainingAmount(LibOrder.Offer memory offer) external view returns (uint256) {
        bytes32 offerKeyHash = LibOrder.hashOfferKey(offer);
        if (offer.startedAt > version2timestamp && version2timestamp > 0) {
            offerKeyHash = LibOrder.hashOffer(offer);
        }
        return offer.size - sizes[offerKeyHash];
    }

    /**
    * @notice Accepts a batch of offers for tokens in a single transaction.
    * @param offers Array of offers to be accepted.
    * @param signatures Array of signatures corresponding to each offer.
    * @param tokens Array of tokens for which the offers are made.
    * @param tokenSignatures Array of signatures corresponding to each token.
    */
    function acceptOfferBatch(LibOrder.Offer[] calldata offers, bytes[] calldata signatures, LibOrder.Token[] calldata tokens, bytes[] calldata tokenSignatures) external whenNotPaused nonReentrant {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        uint64 i;
        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (; i < len; ++i) {
            payments[i] = acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }

        IAssetManager(assetManager).payMPBatch(payments);
    }

    /**
    * @notice Executes a batch purchase of multiple orders in a single transaction.
    * @param batchOrders Array of batch orders to be executed.
    * @param signatures Array of signatures corresponding to each batch order.
    * @param positions Array of positions indicating the specific item in each batch order.
    */
    function batchBuy(LibOrder.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        uint64 i;
        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (; i < len; ++i) {
            payments[i] = buy(batchOrders[i], signatures[i], positions[i]);
        }

        IAssetManager(assetManager).payMPBatch(payments);
    }

    /**
    * @notice Executes a batch purchase of multiple orders with Ether payment in a single transaction.
    * @param batchOrders Array of batch orders to be executed.
    * @param signatures Array of signatures corresponding to each batch order.
    * @param positions Array of positions indicating the specific item in each batch order.
    */
    function batchBuyETH(LibOrder.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external payable
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        uint64 i;
        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (; i < len; ++i) {
            payments[i] = buy(batchOrders[i], signatures[i], positions[i]);
        }

        IAssetManager(assetManager).payMPBatch(payments);
    }

    /**
    * @notice Cancels a batch of orders in a single transaction.
    * @param batchOrders Array of batch orders to be cancelled.
    * @param signatures Array of signatures corresponding to each batch order.
    * @param positions Array of positions indicating the specific item in each batch order.
    */
    function batchCancelOrder(LibOrder.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions, LibOrder.CancelOrder[] calldata cancelOrderInfos, bytes[] calldata cancelOrderSignatures) external
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        uint64 i;
        for (; i < len; ++i) {
            cancelOrder(batchOrders[i], signatures[i], positions[i], cancelOrderInfos[i], cancelOrderSignatures[i]);
        }
    }

    /**
    * @notice Accepts an individual offer.
    * @param offer The offer to be accepted.
    * @param signature The signature corresponding to the offer.
    * @param token The token associated with the offer.
    * @param tokenSignature The signature of the token.
    */
    function acceptOffer(LibOrder.Offer memory offer, bytes memory signature, LibOrder.Token memory token, bytes memory tokenSignature) internal returns (IAssetManager.PaymentInfo memory) {
        require(keccak256(abi.encodePacked(offer.salt)) == keccak256(abi.encodePacked(token.salt)), "salt does not match");
        address buyer = _validateOffer(offer, signature);
        address seller = msg.sender;
        require(buyer != seller, "signer cannot redeem own coupon");
        require(token.offerOwner == buyer, "offer owner and buyer does not match");
        require(token.sender == msg.sender, "token signature does not belong to msg.sender");

        require(offer.bid > 0, "non existent offer");
        require((block.timestamp - offer.startedAt) < offer.duration, "offer has expired");

        bytes32 offerKeyHash = LibOrder.hashOfferKey(offer);
        if (offer.startedAt > version2timestamp && version2timestamp > 0) {
            offerKeyHash = LibOrder.hashOffer(offer);
        }
        require(offer.size > sizes[offerKeyHash], "size is filled");
        require(_hashTypedDataV4(LibOrder.hashToken(token)).recover(tokenSignature) == validator, "token signature is not valid");
        require(offer.nftContractAddress == token.nftContractAddress, "contract address does not match");
        require(token.blockNumber + blockRange > block.number, "token signature has been expired");

        if (!offer.isCollectionOffer) {
            require(token.tokenId == offer.tokenId, "token id does not match");
        } else {
            require(keccak256(abi.encodePacked(offer.traits)) == keccak256(abi.encodePacked(token.traits)), "traits does not match");
        }

        sizes[offerKeyHash] += 1;

        emit AcceptOffer(offer.nftContractAddress, token.tokenId, buyer, offer.salt, offer.bid);

        return IAssetManager.PaymentInfo({
            buyer: buyer,
            seller: seller,
            collection: offer.nftContractAddress,
            tokenId: token.tokenId,
            price: offer.bid
        });
    }

    /**
    * @notice Executes a purchase for a specific order within a batch order.
    * @param batchOrder The batch order containing the specific order to be executed.
    * @param signature The signature corresponding to the batch order.
    * @param position The position of the specific order within the batch order.
    */
    function buy(LibOrder.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal returns (IAssetManager.PaymentInfo memory) {
        address seller = _validate(batchOrder, signature);
        address buyer = msg.sender;
        require(buyer != seller, "signer cannot redeem own coupon");


        LibOrder.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require((block.timestamp - order.startedAt) < order.duration, "order has expired");

        bytes32 orderKeyHash = LibOrder.hashKey(order);
        if (order.startedAt > version2timestamp && version2timestamp > 0) {
            orderKeyHash = LibOrder._hashOrderItem(order);
        }
        require(!fills[orderKeyHash], "order has already redeemed or cancelled");
        fills[orderKeyHash] = true;

        emit Redeem(order.nftContractAddress, order.tokenId, order.salt, order.price);
        return IAssetManager.PaymentInfo({
            buyer: buyer,
            seller: seller,
            collection: order.nftContractAddress,
            tokenId: order.tokenId,
            price: order.price
        });
    }

    /**
    * @notice Cancels a specific order within a batch order.
    * @param batchOrder The batch order containing the specific order to be cancelled.
    * @param signature The signature corresponding to the batch order.
    * @param position The position of the specific order within the batch order.
    * @param cancelOrderInfo associated with the order.
    * @param cancelOrderSignature The signature corresponding to the cancellation request, ensuring the authenticity of the request.
    */
    function cancelOrder(LibOrder.BatchOrder memory batchOrder, bytes memory signature, uint256 position, LibOrder.CancelOrder memory cancelOrderInfo, bytes memory cancelOrderSignature) internal {
        LibOrder.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require(msg.sender == _validate(batchOrder, signature), "only signer");
        require(_hashTypedDataV4(LibOrder.hashCancelOrder(cancelOrderInfo)).recover(cancelOrderSignature) == validator, "validator signature is not valid");
        require(msg.sender == cancelOrderInfo.sender, "Only the original sender can cancel this order.");
        require(cancelOrderInfo.blockNumber + blockRange > block.number, "cancel order signature has been expired");
        require(keccak256(abi.encodePacked(batchOrder.salt)) == keccak256(abi.encodePacked(cancelOrderInfo.salt)), "salt does not match");
        require(cancelOrderInfo.tokenId == order.tokenId, "tokenId does not match");
        require(cancelOrderInfo.nftContractAddress == order.nftContractAddress, "nftContractAddress does not match");

        bytes32 orderKeyHash = LibOrder.hashKey(order);
        if (order.startedAt > version2timestamp && version2timestamp > 0) {
            orderKeyHash = LibOrder._hashOrderItem(order);
        }
        require(!fills[orderKeyHash], "order has already redeemed or cancelled");
        fills[orderKeyHash] = true;

        emit Cancel(order.nftContractAddress, order.tokenId, order.salt);
    }

    /**
    * @notice Retrieves the current chain ID of the blockchain where the contract is deployed.
    * @return id The current chain ID.
    */
    function getChainId() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    /**
    * @notice Validates a batch order by verifying its signature and returns the signer's address.
    * @param batchOrder The batch order to be validated.
    * @param signature The cryptographic signature associated with the batch order.
    * @return The address of the signer of the batch order.
    */
    function _validate(LibOrder.BatchOrder memory batchOrder, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrder.hash(batchOrder);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Validates an offer by verifying its signature and returns the signer's address.
    * @param offer The offer to be validated.
    * @param signature The cryptographic signature associated with the offer.
    * @return The address of the signer of the offer.
    */
    function _validateOffer(LibOrder.Offer memory offer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrder.hashOffer(offer);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Modifier to ensure an address is not the zero address.
    * @dev Throws if the provided address is the zero address.
    * @param _address The address to be validated.
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}