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
contract SalvorExchangeV2 is Initializable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    string private constant SIGNING_DOMAIN = "Salvor";
    string private constant SIGNATURE_VERSION = "3";
    using ECDSAUpgradeable for bytes32;

    mapping(bytes32 => uint256) public sizes;

    mapping(bytes32 => bool) public fills;
    mapping(bytes32 => bool) public tokenFills;

    address public assetManager;

    address public validator;

    uint256 public blockRange;

    mapping(address => mapping(address => uint256)) public cancelOfferTimestamps;
    mapping(address => mapping(address => uint256)) public cancelOrderTimestamps;


    // events
    event CancelOrder(address indexed collection, uint256 indexed tokenId, string salt);
    event Redeem(address indexed collection, uint256 indexed tokenId, string salt, uint256 value);
    event CancelOffer(address indexed user);
    event CancelAllOrders(address indexed user);
    event AcceptOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer, string salt, uint256 bid);
    event SetAssetManager(address indexed assetManager);
    event SetValidator(address indexed validator);
    event SetBlockRange(uint256 blockRange);

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
        emit SetAssetManager(_assetManager);
    }

    /**
    * @notice Assigns a new validator address. Restricted to actions by the contract owner.
    * @param _validator The new validator's address, which cannot be the zero address.
    */
    function setValidator(address _validator) external onlyOwner addressIsNotZero(_validator) {
        validator = _validator;
        emit SetValidator(_validator);
    }

    /**
    * @notice Updates the block range parameter within the contract. This action can only be performed by the contract owner.
    * @param _blockRange The new block range value to be set.
    */
    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
        emit SetBlockRange(_blockRange);
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

    function getRemainingAmount(LibOrderV2.Offer memory offer) external view returns (uint256) {
        return offer.size - sizes[LibOrderV2.hashOffer(offer)];
    }

    /**
    * @notice Accepts a batch of offers for tokens in a single transaction.
    * @param offers Array of offers to be accepted.
    * @param signatures Array of signatures corresponding to each offer.
    * @param tokens Array of tokens for which the offers are made.
    * @param tokenSignatures Array of signatures corresponding to each token.
    */
    function acceptOfferBatch(LibOrderV2.Offer[] calldata offers, bytes[] calldata signatures, LibOrderV2.Token[] calldata tokens, bytes[] calldata tokenSignatures) external whenNotPaused nonReentrant {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        require(len == signatures.length && len == tokens.length && len == tokenSignatures.length, "inputs do not match");

        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (uint256 i; i < len; ++i) {
            payments[i] = acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }

        IAssetManager(assetManager).payMPBatch(payments);
    }

    /// @notice Cancels all offers made by the sender.
    function cancelAllOffers() external whenNotPaused {
        cancelOfferTimestamps[msg.sender][address(0x0)] = block.timestamp;
        emit CancelOffer(msg.sender);
    }

    /// @notice Cancels all orders made by the sender.
    function cancelAllOrders() external whenNotPaused {
        cancelOrderTimestamps[msg.sender][address(0x0)] = block.timestamp;
        emit CancelAllOrders(msg.sender);
    }

    /**
    * @notice Executes a batch purchase of multiple orders in a single transaction.
    * @param batchOrders Array of batch orders to be executed.
    * @param signatures Array of signatures corresponding to each batch order.
    * @param positions Array of positions indicating the specific item in each batch order.
    */
    function batchBuy(LibOrderV2.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        require(len == signatures.length && len == positions.length, "inputs do not match");
        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (uint256 i; i < len; ++i) {
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
    function batchBuyETH(LibOrderV2.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external payable
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        require(len  == signatures.length && len == positions.length, "inputs do not match");
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        IAssetManager.PaymentInfo[] memory payments = new IAssetManager.PaymentInfo[](len);
        for (uint256 i; i < len; ++i) {
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
    function batchCancelOrder(LibOrderV2.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        require(len == signatures.length && len == positions.length, "inputs do not match");
        for (uint256 i; i < len; ++i) {
            cancelOrder(batchOrders[i], signatures[i], positions[i]);
        }
    }

    /**
    * @notice Accepts an individual offer.
    * @param offer The offer to be accepted.
    * @param signature The signature corresponding to the offer.
    * @param token The token associated with the offer.
    * @param tokenSignature The signature of the token.
    */
    function acceptOffer(LibOrderV2.Offer memory offer, bytes memory signature, LibOrderV2.Token memory token, bytes memory tokenSignature) internal returns (IAssetManager.PaymentInfo memory) {
        bytes32 tokenHash = LibOrderV2.hashToken(token);
        require(!tokenFills[tokenHash], "token has already used");
        require(_hashTypedDataV4(tokenHash).recover(tokenSignature) == validator, "token signature is not valid");
        require(keccak256(abi.encodePacked(offer.salt)) == keccak256(abi.encodePacked(token.salt)), "salt does not match");
        bytes32 offerKeyHash = LibOrderV2.hashOffer(offer);

        address seller = msg.sender;
        address buyer = _validateOffer(offer, signature);
        require(buyer != seller, "signer cannot redeem own coupon");
        require(buyer == offer.buyer, "buyer does not match");

        require(token.sender == msg.sender, "token signature does not belong to msg.sender");

        require(offer.bid > 0, "non existent offer");
        require((block.timestamp - offer.startedAt) < offer.duration, "offer has expired");
        require(cancelOfferTimestamps[buyer][address(0x0)] < offer.startedAt, "offer is cancelled");

        require(offer.size > sizes[offerKeyHash], "size is filled");
        require(offer.nftContractAddress == token.nftContractAddress, "contract address does not match");
        require(token.blockNumber + blockRange > block.number, "token signature has been expired");

        if (!offer.isCollectionOffer) {
            require(token.tokenId == offer.tokenId, "token id does not match");
        } else {
            require(keccak256(abi.encodePacked(offer.traits)) == keccak256(abi.encodePacked(token.traits)), "traits does not match");
        }

        sizes[offerKeyHash] += 1;
        tokenFills[tokenHash] = true;

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
    function buy(LibOrderV2.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal returns (IAssetManager.PaymentInfo memory) {
        address seller = _validate(batchOrder, signature);
        require(seller == batchOrder.seller, "seller does not match");
        address buyer = msg.sender;
        require(buyer != seller, "signer cannot redeem own coupon");

        LibOrderV2.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require((block.timestamp - order.startedAt) < order.duration, "order has expired");
        require(cancelOrderTimestamps[seller][address(0x0)] < order.startedAt, "order is cancelled");

        bytes32 orderKeyHash = LibOrderV2._hashOrderItem(order);

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
    */
    function cancelOrder(LibOrderV2.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal {
        LibOrderV2.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        address seller = _validate(batchOrder, signature);
        require(msg.sender == seller, "only signer");
        require(batchOrder.seller == seller, "seller does not match");

        bytes32 orderKeyHash = LibOrderV2._hashOrderItem(order);

        require(!fills[orderKeyHash], "order has already redeemed or cancelled");
        fills[orderKeyHash] = true;

        emit CancelOrder(order.nftContractAddress, order.tokenId, order.salt);
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
    function _validate(LibOrderV2.BatchOrder memory batchOrder, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrderV2.hash(batchOrder);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Validates an offer by verifying its signature and returns the signer's address.
    * @param offer The offer to be validated.
    * @param signature The cryptographic signature associated with the offer.
    * @return The address of the signer of the offer.
    */
    function _validateOffer(LibOrderV2.Offer memory offer, bytes memory signature) public view returns (address) {
        return _hashTypedDataV4(LibOrderV2.hashOffer(offer)).recover(signature);
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