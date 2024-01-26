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

    function setAssetManager(address _assetManager) external onlyOwner addressIsNotZero(_assetManager) {
        assetManager = _assetManager;
    }

    function setValidator(address _validator) external onlyOwner addressIsNotZero(_validator) {
        validator = _validator;
    }

    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // closed
    function batchCancelOffer(LibOrder.Offer[] calldata offers, bytes[] calldata signatures) external onlyOwner whenNotPaused {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            cancelOffer(offers[i], signatures[i]);
        }
    }

    function acceptOfferBatch(LibOrder.Offer[] calldata offers, bytes[] calldata signatures, LibOrder.Token[] calldata tokens, bytes[] calldata tokenSignatures) external whenNotPaused nonReentrant {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        uint64 i;
        for (; i < len; ++i) {
            acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }
    }

    function acceptOfferBatchETH(LibOrder.Offer[] calldata offers, bytes[] calldata signatures, LibOrder.Token[] calldata tokens, bytes[] calldata tokenSignatures) external payable whenNotPaused nonReentrant {
        uint256 len = offers.length;
        require(len <= 20, "exceeded the limits");
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        uint64 i;
        for (; i < len; ++i) {
            acceptOffer(offers[i], signatures[i], tokens[i], tokenSignatures[i]);
        }
    }

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

    function cancelOffer(LibOrder.Offer memory offer, bytes memory signature) internal {
        require(offer.bid > 0, "non existent offer");
        bytes32 offerKeyHash = LibOrder.hashOfferKey(offer);
        require(!offerFills[offerKeyHash], "offer has already cancelled");
        require(offer.size > sizes[offerKeyHash], "offer has already redeemed");
        require(msg.sender == _validateOffer(offer, signature), "only signer");
        emit CancelOffer(offer.nftContractAddress, offer.tokenId, offer.salt, offer.isCollectionOffer);
        offerFills[offerKeyHash] = true;
    }

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

    function cancelOrder(LibOrder.BatchOrder memory batchOrder, bytes memory signature, uint256 position) internal {
        LibOrder.Order memory order = batchOrder.orders[position];
        require(order.price > 0, "non existent order");
        require(msg.sender == _validate(batchOrder, signature), "only signer");


        bytes32 orderKeyHash = LibOrder.hashKey(order);
        require(!fills[orderKeyHash], "order has already redeemed or cancelled");
        fills[orderKeyHash] = true;

        emit Cancel(order.nftContractAddress, order.tokenId, order.salt);
    }

    function getChainId() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    function balance() external view returns (uint) {
        return address(this).balance;
    }

    function _getPortionOfBid(uint256 _totalBid, uint96 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    function _validate(LibOrder.BatchOrder memory batchOrder, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrder.hash(batchOrder);
        return _hashTypedDataV4(hash).recover(signature);
    }

    function _validateOffer(LibOrder.Offer memory offer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrder.hashOffer(offer);
        return _hashTypedDataV4(hash).recover(signature);
    }

    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}