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

    // events
    event Cancel(address indexed collection, uint256 indexed tokenId, string salt);
    event Redeem(address indexed collection, uint256 indexed tokenId, string salt, uint256 value);
    event CancelOffer(address indexed collection, uint256 indexed tokenId, string salt, bool isCollectionOffer);
    event AcceptOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer, string salt, uint256 bid);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

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
     * @notice Cancels a batch of offers made by the owner in a single transaction. (It's not used anymore)
     * @param offers Array of offers to be canceled.
     * @param signatures Array of signatures corresponding to each offer.
     */
    function batchCancelOffer(LibOrder.Offer[] calldata offers, bytes[] calldata signatures) external onlyOwner whenNotPaused {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            cancelOffer(offers[i], signatures[i]);
        }
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
        for (; i < len; ++i) {
            acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }
    }

    /**
     * @notice Accepts a batch of offers for tokens with Ether payment in a single transaction.
     * @param offers Array of offers to be accepted.
     * @param signatures Array of signatures corresponding to each offer.
     * @param tokens Array of tokens for which the offers are made.
     * @param tokenSignatures Array of signatures corresponding to each token.
     */
    function acceptOfferBatchETH(LibOrder.Offer[] calldata offers, bytes[] calldata signatures, LibOrder.Token[] calldata tokens, bytes[] calldata tokenSignatures) external payable whenNotPaused nonReentrant {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        uint64 i;
        for (; i < len; ++i) {
            acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }
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
        for (; i < len; ++i) {
            buy(batchOrders[i], signatures[i], positions[i]);
        }
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
        for (; i < len; ++i) {
            buy(batchOrders[i], signatures[i], positions[i]);
        }
    }

    /**
     * @notice Cancels a batch of orders in a single transaction.
     * @param batchOrders Array of batch orders to be cancelled.
     * @param signatures Array of signatures corresponding to each batch order.
     * @param positions Array of positions indicating the specific item in each batch order.
     */
    function batchCancelOrder(LibOrder.BatchOrder[] calldata batchOrders, bytes[] calldata signatures, uint256[] calldata positions) external
    whenNotPaused
    nonReentrant
    {
        uint256 len = batchOrders.length;
        require(len <= 20, "exceeded the limits");
        uint64 i;
        for (; i < len; ++i) {
            cancelOrder(batchOrders[i], signatures[i], positions[i]);
        }
    }

    /**
     * @notice Cancels an individual offer.
     * @param offer The offer to be cancelled.
     * @param signature The signature corresponding to the offer.
     */
    function cancelOffer(LibOrder.Offer memory offer, bytes memory signature) internal {
        require(offer.bid > 0, "non existent offer");
        bytes32 offerKeyHash = LibOrder.hashOfferKey(offer);
        require(!offerFills[offerKeyHash], "offer has already cancelled");
        require(offer.size > sizes[offerKeyHash], "offer has already redeemed");
        require(msg.sender == _validateOffer(offer, signature), "only signer");
        emit CancelOffer(offer.nftContractAddress, offer.tokenId, offer.salt, offer.isCollectionOffer);
        offerFills[offerKeyHash] = true;
    }

    /**
     * @notice Accepts an individual offer.
     * @param offer The offer to be accepted.
     * @param signature The signature corresponding to the offer.
     * @param token The token associated with the offer.
     * @param tokenSignature The signature of the token.
     */
    function acceptOffer(LibOrder.Offer memory offer, bytes memory signature, LibOrder.Token memory token, bytes memory tokenSignature) internal {
        require(keccak256(abi.encodePacked(offer.salt)) == keccak256(abi.encodePacked(token.salt)), "salt does not match");
        address buyer = _validateOffer(offer, signature);
        address seller = msg.sender;
        require(buyer != seller, "signer cannot redeem own coupon");
        require(offer.bid > 0, "non existent offer");
        require((block.timestamp - offer.startedAt) < offer.duration, "offer has expired");

        bytes32 offerKeyHash = LibOrder.hashOfferKey(offer);
        require(!offerFills[offerKeyHash], "offer cancelled");
        require(offer.size > sizes[offerKeyHash], "size is filled");
        require(_hashTypedDataV4(LibOrder.hashToken(token)).recover(tokenSignature) == validator, "token signature is not valid");
        require(token.sender == msg.sender, "token signature does not belong to msg.sender");
        require(token.blockNumber + blockRange > block.number, "token signature has been expired");

        if (!offer.isCollectionOffer) {
            require(token.tokenId == offer.tokenId, "token id does not match");
        } else {
            require(keccak256(abi.encodePacked(offer.traits)) == keccak256(abi.encodePacked(token.traits)), "traits does not match");
        }

        sizes[offerKeyHash] += 1;

        IAssetManager(assetManager).payMP(buyer, seller, offer.nftContractAddress, token.tokenId, offer.bid);

        emit AcceptOffer(offer.nftContractAddress, token.tokenId, buyer, offer.salt, offer.bid);
    }

    /**
     * @notice Executes a purchase for a specific order within a batch order.
     * @param batchOrder The batch order containing the specific order to be executed.
     * @param signature The signature corresponding to the batch order.
     * @param position The position of the specific order within the batch order.
     */
    function buy(LibOrder.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal {
        address seller = _validate(batchOrder, signature);
        address buyer = msg.sender;
        require(buyer != seller, "signer cannot redeem own coupon");


        LibOrder.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require((block.timestamp - order.startedAt) < order.duration, "order has expired");

        bytes32 orderKeyHash = LibOrder.hashKey(order);
        require(!fills[orderKeyHash], "order has already redeemed or cancelled");
        fills[orderKeyHash] = true;

        emit Redeem(order.nftContractAddress, order.tokenId, order.salt, order.price);

        IAssetManager(assetManager).payMP(buyer, seller, order.nftContractAddress, order.tokenId, order.price);
    }

    /**
     * @notice Cancels a specific order within a batch order.
     * @param batchOrder The batch order containing the specific order to be cancelled.
     * @param signature The signature corresponding to the batch order.
     * @param position The position of the specific order within the batch order.
     */
    function cancelOrder(LibOrder.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal {
        LibOrder.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require(msg.sender == _validate(batchOrder, signature), "only signer");


        bytes32 orderKeyHash = LibOrder.hashKey(order);
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
    * @notice Returns the contract's Ether balance.
    * @return The Ether balance of the contract.
    */
    function balance() external view returns (uint) {
        return address(this).balance;
    }

    /**
    * @notice Calculates a portion of a bid based on a given percentage. (It's not used)
     * @param _totalBid The total bid amount.
     * @param _percentage The percentage to calculate from the total bid.
     * @return The calculated portion of the bid.
     */
    function _getPortionOfBid(uint256 _totalBid, uint96 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

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