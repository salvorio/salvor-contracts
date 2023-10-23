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
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "../NFTCollectible/INFTCollectible.sol";
import "../PaymentManager/IPaymentManager.sol";
import "./lib/LibOrder.sol";
import "../libs/LibShareholder.sol";
/**
* @title Marketplace
* @notice allows users to make, cancel, accept and reject offers as well as purchase a listed nft using a listing coupon.
*/
contract Marketplace is Initializable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    struct CollectionOffer {
        uint256 amount;
        uint256 remainingAmount;
        uint256 bid;
    }

    string private constant SIGNING_DOMAIN = "Salvor";
    string private constant SIGNATURE_VERSION = "1";
    using ECDSAUpgradeable for bytes32;

    /**
    * @notice contains information about redeemed and canceled orders.
    * prevents users make transaction with the same offer on the functions.
    */
    mapping(bytes32 => bool) public fills;

    /**
    * @notice contains offered bids to the nfts that are accessible with contract_address and token_id.
    * A buyer accepts or rejects an offer, and a seller cancels or makes an offer according to this mapping.
    * e.g offers[contract_address][token_id][bidder_address] = bid;
    */
    mapping(address => mapping(uint256 => mapping(address => uint256))) public offers;

    /**
    * @notice contains total balance for each bidder_address; It used to make offers on NFTs. In order to make an offer.
    * It also provides unlimited bidding features. Bids can be made for each Nft up to the amount in the biddingWallets.
    * e.g biddingWallets[bidder_address] = total_balance;
    */
    mapping(address => uint256) public offerTotalAmounts;

    /**
    * @notice The mapping contains total bids for each bidder_address; for every bid it will be increased.
    * For every withdrawal and acceptance of an offer it will be decreased.
    * It manages whether or not to allow future withdrawal balance requests.
    * e.g offerTotalAmounts[bidder_address] = total_bid;
    */
    mapping(address => uint256) public biddingWallets;

    /**
    * @notice manages payouts for each contract.
    */
    address public paymentManager;

    /**
    * @notice a control variable to check the minimum price of the orders and offers is in the correct range.
    */
    uint256 public minimumPriceLimit;

    mapping(address => mapping(address => CollectionOffer)) public collectionOffers;


    // events
    event Fund(uint256 value);
    event Withdraw(uint256 balance, uint256 amount);
    event Cancel(address indexed collection, uint256 indexed tokenId, bytes32 hash, string salt);
    event MakeOffer(address indexed collection, uint256 indexed tokenId, uint256 amount);
    event CancelOffer(address indexed collection, uint256 indexed tokenId, bool isExternal);
    event AcceptOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 amount);
    event Redeem(address indexed collection, uint256 indexed tokenId, string salt, uint256 value);
    event RejectOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer);
    event MakeCollectionOffer(address indexed collection, uint256 amount, uint256 bid);
    event CancelCollectionOffer(address indexed collection, bool isExternal);
    event AcceptCollectionOffer(address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 bid);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address _paymentManager) public initializer addressIsNotZero(_paymentManager) {
        __EIP712_init_unchained(SIGNING_DOMAIN, SIGNATURE_VERSION);
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        paymentManager = _paymentManager;
        minimumPriceLimit = 10000000000000000; // 0.01 ether
    }

    /**
    * @notice Allows owner to set paymentManager contract address.
    * @param _paymentManager PaymentManager contract address.
    */
    function setPaymentManager(address _paymentManager) external onlyOwner addressIsNotZero(_paymentManager) {
        paymentManager = _paymentManager;
    }

    /**
    * @notice allows the owner to set a minimumPriceLimit that is used as a control variable
    * to check the minimum price of the orders and offers is in the correct range.
    * @param _minimumPriceLimit amount of ether
    */
    function setMinimumPriceLimit(uint256 _minimumPriceLimit) external onlyOwner {
        minimumPriceLimit = _minimumPriceLimit;
    }

    /**
    * @notice Allows to the msg.sender deposit funds to the biddingWallet balance.
    */
    function deposit() external payable whenNotPaused nonReentrant paymentAccepted {
        biddingWallets[msg.sender] += msg.value;
        emit Fund(msg.value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function batchTransfer(address[] calldata _addresses, uint256[] calldata _tokenIds, address _to) external {
        uint256 len = _addresses.length;
        require(len <= 50, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            IERC721Upgradeable(_addresses[i]).safeTransferFrom(msg.sender, _to, _tokenIds[i]);
        }
    }

    function batchCancelOffer(address[] calldata _addresses, uint256[] calldata _tokenIds) external {
        uint256 len = _addresses.length;
        require(len <= 50, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            cancelOffer(_addresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice Allows the msg.sender to make bids to any nft.
    * This can be done if the amount is less or equal to the balance in the biddingWallets.
    * @param _nftContractAddress nft contract address
    * @param _amount offer
    */
    function makeCollectionOffer(address _nftContractAddress, uint256 _amount, uint256 _bid)
    external
    whenNotPaused
    nonReentrant
    priceGreaterThanMinimumPriceLimit(_bid)
    {
        require(_amount > 0, "amount cannot be 0");
        uint256 totalOfferAmount = _amount * _bid;
        require(biddingWallets[msg.sender] >= totalOfferAmount, "Insufficient funds to make an offer");

        offerTotalAmounts[msg.sender] += totalOfferAmount;

        CollectionOffer memory collectionOffer = collectionOffers[_nftContractAddress][msg.sender];
        if (collectionOffer.remainingAmount > 0) {
            offerTotalAmounts[msg.sender] -= (collectionOffer.bid * collectionOffer.remainingAmount);
            emit CancelCollectionOffer(_nftContractAddress, false);
        }

        collectionOffer.bid = _bid;
        collectionOffer.amount = _amount;
        collectionOffer.remainingAmount = _amount;

        collectionOffers[_nftContractAddress][msg.sender] = collectionOffer;

        emit MakeCollectionOffer(_nftContractAddress, _amount, _bid);
    }

    /**
    * @notice Allows the msg.sender to cancel existing offer of own
    * @param _nftContractAddress nft contract address
    */
    function cancelCollectionOffer(address _nftContractAddress)
    external
    whenNotPaused
    nonReentrant
    {
        CollectionOffer memory collectionOffer = collectionOffers[_nftContractAddress][msg.sender];
        require(collectionOffer.remainingAmount > 0, "there is no any offer");

        uint256 totalOfferAmount = collectionOffer.remainingAmount * collectionOffer.bid;
        offerTotalAmounts[msg.sender] -= totalOfferAmount;

        collectionOffer.amount = 0;
        collectionOffer.remainingAmount = 0;
        collectionOffer.bid = 0;

        collectionOffers[_nftContractAddress][msg.sender] = collectionOffer;
        emit CancelCollectionOffer(_nftContractAddress, true);
    }

    /**
    * @notice Allows the nft owner to accept existing offers. Nft owners can share the amount via shareholders.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param shareholders revenue share list
    */
    function acceptCollectionOffer(address _nftContractAddress, uint256 _tokenId, address _buyer, LibShareholder.Shareholder[] memory shareholders) external whenNotPaused nonReentrant {
        require(msg.sender != _buyer, "could not accept own offer");

        address existingNftOwner = IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId);
        require(existingNftOwner == msg.sender, "you haven't this nft");

        CollectionOffer memory collectionOffer = collectionOffers[_nftContractAddress][_buyer];

        require(collectionOffer.remainingAmount > 0, "there is no any offer for this nft");

        require(biddingWallets[_buyer] >= collectionOffer.bid, "Insufficient funds to accept an offer");

        biddingWallets[_buyer] -= collectionOffer.bid;
        offerTotalAmounts[_buyer] -= collectionOffer.bid;
        collectionOffer.remainingAmount -= 1;

        collectionOffers[_nftContractAddress][_buyer] = collectionOffer;

        emit AcceptCollectionOffer(_nftContractAddress, _tokenId, _buyer, collectionOffer.bid);

        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(msg.sender, _buyer, _tokenId);
        _payout(payable(msg.sender), _nftContractAddress, _tokenId, collectionOffer.bid, shareholders);
    }

    /**
    * @notice Allows the msg.sender to withdraw any amount from biddingWallet balance.
    * This can be done;
    *    - if msg.sender has not any ongoing offers
    *    - if msg.sender has ongoing offers then the total amount of bids of these offers is locked in offerTotalAmounts,
           in this case msg.sender can only withdraw the remaining amount from her/his locked balance.
    * @param _amount amount of ethers transferred to `msg.sender`
    */
    function withdraw(uint256 _amount) external whenNotPaused nonReentrant priceGreaterThanZero(_amount) {
        uint256 existingBalance = biddingWallets[msg.sender];
        require(existingBalance >= _amount, "Balance is insufficient for a withdrawal");
        require((existingBalance - _amount) >= offerTotalAmounts[msg.sender], "cannot withdraw the requested _amount while there are active offers");
        biddingWallets[msg.sender] -= _amount;

        payable(msg.sender).transfer(_amount);
        emit Withdraw(existingBalance, _amount);
    }

    /**
    * @notice Allows the msg.sender to make bids to any nft.
    * This can be done if the amount is less or equal to the balance in the biddingWallets.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param _amount offer
    */
    function makeOffer(address _nftContractAddress, uint256 _tokenId, uint256 _amount)
    external
    whenNotPaused
    nonReentrant
    priceGreaterThanMinimumPriceLimit(_amount)
    {
        address existingNftOwner = IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId);
        require(existingNftOwner != msg.sender, "could not offer to own nft");
        require(biddingWallets[msg.sender] >= _amount, "Insufficient funds to make an offer");

        uint256 previousBid = offers[_nftContractAddress][_tokenId][msg.sender];
        if (previousBid > 0) {
            offerTotalAmounts[msg.sender] -= previousBid;
            emit CancelOffer(_nftContractAddress, _tokenId, false);
        }

        offers[_nftContractAddress][_tokenId][msg.sender] = _amount;
        offerTotalAmounts[msg.sender] += _amount;

        emit MakeOffer(_nftContractAddress, _tokenId, _amount);
    }

    /**
    * @notice Allows the msg.sender to cancel existing offer of own
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function cancelOffer(address _nftContractAddress, uint256 _tokenId)
    public
    whenNotPaused
    nonReentrant
    {
        require(offers[_nftContractAddress][_tokenId][msg.sender] > 0, "there is no any offer");

        uint256 amount = offers[_nftContractAddress][_tokenId][msg.sender];
        offers[_nftContractAddress][_tokenId][msg.sender] = 0;
        offerTotalAmounts[msg.sender] -= amount;

        emit CancelOffer(_nftContractAddress, _tokenId, true);
    }

    /**
    * @notice Allows the nft owner to accept existing offers. Nft owners can share the amount via shareholders.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param shareholders revenue share list
    */
    function acceptOffer(address _nftContractAddress, uint256 _tokenId, address _buyer, LibShareholder.Shareholder[] memory shareholders) external whenNotPaused nonReentrant {
        require(msg.sender != _buyer, "could not accept own offer");

        address existingNftOwner = IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId);
        require(existingNftOwner == msg.sender, "you haven't this nft");

        require(offers[_nftContractAddress][_tokenId][_buyer] > 0, "there is no any offer for this nft");

        require(biddingWallets[_buyer] >= offers[_nftContractAddress][_tokenId][_buyer], "Insufficient funds to accept an offer");

        uint256 bid = offers[_nftContractAddress][_tokenId][_buyer];
        biddingWallets[_buyer] -= bid;
        offerTotalAmounts[_buyer] -= bid;
        offers[_nftContractAddress][_tokenId][_buyer] = 0;

        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(msg.sender, _buyer, _tokenId);
        _payout(payable(msg.sender), _nftContractAddress, _tokenId, bid, shareholders);

        emit AcceptOffer(_nftContractAddress, _tokenId, _buyer, bid);
    }

    /**
    * @notice Allows the nft owner to reject existing offers.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param _buyer address to be rejected
    */
    function rejectOffer(address _nftContractAddress, uint256 _tokenId, address _buyer) external whenNotPaused nonReentrant {
        address existingNftOwner = IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId);
        require(existingNftOwner == msg.sender, "you haven't this nft");

        require(offers[_nftContractAddress][_tokenId][_buyer] > 0, "there is no any offer for this nft");

        uint256 bid = offers[_nftContractAddress][_tokenId][_buyer];
        offerTotalAmounts[_buyer] -= bid;
        offers[_nftContractAddress][_tokenId][_buyer] = 0;

        emit RejectOffer(_nftContractAddress, _tokenId, _buyer);
    }

    function batchRedeem(LibOrder.Order[] calldata orders, bytes[] calldata signatures) external payable
        whenNotPaused
        nonReentrant
    {
        uint256 len = orders.length;
        require(len <= 20, "exceeded the limits");
        uint256 totalPrice;
        for (uint64 i; i < len; ++i) {
            totalPrice += orders[i].price;
        }
        require(msg.value >= totalPrice, "Insufficient funds to redeem");
        for (uint64 i; i < len; ++i) {
            redeem(orders[i], signatures[i]);
        }
    }

    /**
    * @notice A signature is created by a seller when the nft is listed on salvor.io.
    * If the order and signature are matched and the order has not been canceled then it can be redeemed by a buyer.
    * @param order is generated by seller as a listing coupon that contains order details
    * @param signature is generated by seller to validate order
    */
    function redeem(LibOrder.Order memory order, bytes memory signature)
    internal
    isNotCancelled(LibOrder.hashKey(order))
    priceGreaterThanMinimumPriceLimit(order.price)
    {

        bytes32 orderKeyHash = LibOrder.hashKey(order);
        fills[orderKeyHash] = true;
        // make sure signature is valid and get the address of the signer
        address payable signer = payable(_validate(order, signature));
        address payable sender = payable(msg.sender);

        require(sender != signer, "signer cannot redeem own coupon");

        address payable seller = signer;
        address payable buyer = sender;
        uint256 tokenId = order.tokenId;

        require(IERC721Upgradeable(order.nftContractAddress).ownerOf(tokenId) == seller, "cannot redeem the coupon, seller has not the nft");

        IERC721Upgradeable(order.nftContractAddress).safeTransferFrom(seller, buyer, tokenId);
        if (order.price > 0) {
            _payout(seller, order.nftContractAddress, tokenId, order.price, order.shareholders);
        }
        emit Redeem(order.nftContractAddress, tokenId, order.salt, order.price);
    }

    /**
    * @notice allows the nft owner to cancel listed nft on salvor.io.
    * Calculated hash for the requested order will stored on `fills`
    * after the cancel process order and signature cannot be used again to redeem
    * @param order is generated by seller as a listing coupon that contains order details
    * @param signature is generated by seller to validate order
    */
    function cancel(LibOrder.Order memory order, bytes memory signature)
    external
    whenNotPaused
    nonReentrant
    onlySigner(_validate(order, signature))
    isNotCancelled(LibOrder.hashKey(order))
    {
        bytes32 orderKeyHash = LibOrder.hashKey(order);
        fills[orderKeyHash] = true;

        emit Cancel(order.nftContractAddress, order.tokenId, orderKeyHash, order.salt);
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

    /**
    * @notice Process the payment for the allowed requests.
    * Process is completed in 3 steps;commission transfer, royalty transfers and revenue share transfers.
    * @param _seller receiver address
    * @param _nftContractAddress nft contract address is used for process royalty amounts
    * @param _tokenId nft tokenId  is used for process royalty amounts
    * @param _price sent amount
    * @param _shareholders price will be split to the shareholders after royalty and commission calculations.
    */
    function _payout(address payable _seller, address _nftContractAddress, uint256 _tokenId, uint256 _price, LibShareholder.Shareholder[] memory _shareholders) internal {
        IPaymentManager(paymentManager).payout{ value: _price }(_seller, _nftContractAddress, _tokenId, _shareholders, IPaymentManager(paymentManager).getCommissionPercentage());
    }

    /**
    * @notice validates order and signature are matched
    * @param order is generated by seller as a listing coupon that contains order details
    * @param signature is generated by seller to validate order
    */
    function _validate(LibOrder.Order memory order, bytes memory signature) public view returns (address) {
        bytes32 hash = LibOrder.hash(order);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice makes sure given price is greater than 0
    * @param _price amount in ethers
    */
    modifier priceGreaterThanZero(uint256 _price) {
        require(_price > 0, "Price cannot be 0");
        _;
    }

    /**
    * @notice makes sure sent amount is greater than 0
    */
    modifier paymentAccepted() {
        require(msg.value > 0, "Bid must be grater then zero");
        _;
    }

    /**
    * @notice makes sure msg.sender is given address
    * @param _signer account address
    */
    modifier onlySigner(address _signer) {
        require(msg.sender == _signer, "Only signer");
        _;
    }

    /**
    * @notice makes sure order has not redeemed before
    * @param _orderKeyHash hash of an offer
    */
    modifier isNotCancelled(bytes32 _orderKeyHash) {
        require(!fills[_orderKeyHash], "order has already redeemed or cancelled");
        _;
    }

    /**
    * @notice checks the given value is greater than `minimumPriceLimit`
    */
    modifier priceGreaterThanMinimumPriceLimit(uint256 _price) {
        require(_price >= minimumPriceLimit, "Price must be higher than minimum price limit");
        _;
    }

    /**
    * @notice checks the given value is not zero address
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}