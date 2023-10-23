//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "../PaymentManager/IPaymentManager.sol";
import "../libs/LibShareholder.sol";

/**
* @title DutchAuctionMarketplace
* @notice allows the users to create and make bids to nft dutch auctions.
* Sellers specify auction startPrice, endPrice, duration and dropInterval.
* The nft price is continuously updated downwards over time using these parameters.
* Whoever bids first ends the auction.
*/
contract DutchAuctionMarketplace is Initializable, ERC721HolderUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // contains information about an auction
    struct DutchAuction {
        // When the nft is sold then the price will be split to the shareholders.
        mapping(uint8 => LibShareholder.Shareholder) shareholders;
        // There is a restriction about removing arrays defined in a struct.
        // This value helps to iterate and remove every shareholder value.
        uint8 shareholderSize;
        // duration of the auction
        uint64 duration;
        // drop interval timestamp. e.g 5 minutes
        uint64 dropInterval;
        // the auction starting time
        uint64 startTime;
        // commission percentage
        uint96 commissionPercentage;
        // maximum amount for the nft at the beginning of the auction
        uint128 startPrice;
        // minimum amount for the nft at the end of auction
        uint128 endPrice;
        // nft owner
        address seller;
    }

    /**
    * @notice manages payouts for each contract.
    */
    address public paymentManager;

    /**
    * @notice contains information about auctions
    * e.g auctions[contract_address][token_id] = DutchAuction auction;
    */
    mapping(address => mapping(uint256 => DutchAuction)) public dutchAuctions;

    /**
    * @notice a control variable to check the minimum price of the auction is in the correct range.
    */
    uint256 public minimumPriceLimit;

    /**
    * @notice a control variable to check the duration of the auction is in the correct range.
    */
    uint32 public maximumDurationPeriod;

    /**
    * @notice Used as a control variable to check the minimum drop interval defined on the auction is higher than the minimum.
    */
    uint32 public minimumDropInterval;

    // events
    event DutchAuctionMadeBid(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 value, uint256 amount);
    event DutchAuctionWithdrawn(address indexed collection, uint256 indexed tokenId);
    event PaymentManagerSet(address indexed paymentManager);
    event MinimumPriceLimitSet(uint256 minimumPriceLimit);
    event MaximumDurationPeriodSet(uint32 maximumDurationPeriod);
    event MinimumDropIntervalSet(uint32 minimumDropInterval);
    event DutchAuctionCreated(
        address indexed collection,
        uint256 indexed tokenId,
        uint64 duration,
        uint64 dropInterval,
        uint128 startPrice,
        uint128 endPrice,
        uint64 startTime,
        LibShareholder.Shareholder[] shareholders
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(address _paymentManager) public initializer addressIsNotZero(_paymentManager) {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
        __Pausable_init_unchained();
        paymentManager = _paymentManager;
        minimumPriceLimit = 0; // 0 ether
        maximumDurationPeriod = 864000; // 10 days
        minimumDropInterval = 120; // 2 minutes
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
    * @notice allows owner to set paymentManager contract address.
    * @param _paymentManager PaymentManager contract address.
    */
    function setPaymentManager(address _paymentManager) external onlyOwner addressIsNotZero(_paymentManager) {
        paymentManager = _paymentManager;
        emit PaymentManagerSet(_paymentManager);
    }

    /**
    * @notice allows the owner to set a minimumPriceLimit that is used as a control variable to check the minimum price of the auction is in the correct range.
    * @param _minimumPriceLimit amount of ether e.g 0.01 ether
    */
    function setMinimumPriceLimit(uint256 _minimumPriceLimit) external onlyOwner {
        minimumPriceLimit = _minimumPriceLimit;
        emit MinimumPriceLimitSet(_minimumPriceLimit);
    }

    /**
    * @notice allows the owner to set a maximumDurationPeriod that is used as a control variable to check the duration of the auction is in the correct range.
    * @param _maximumDurationPeriod timestamp value e.g 864000 (10 days)
    */
    function setMaximumDurationPeriod(uint32 _maximumDurationPeriod) external onlyOwner {
        maximumDurationPeriod = _maximumDurationPeriod;
        emit MaximumDurationPeriodSet(_maximumDurationPeriod);
    }

    /**
    * @notice allows the owner to set a minimumDropInterval that is used as a control variable to check the minimum drop interval on the auction is higher than the limits.
    * @param _minimumDropInterval timestamp value e.g 120 (2 minutes)
    */
    function setMinimumDropInterval(uint32 _minimumDropInterval) external onlyOwner {
        minimumDropInterval = _minimumDropInterval;
        emit MinimumDropIntervalSet(_minimumDropInterval);
    }

    /**
    * @notice allows the nft owner to create a dutch auction. Nft owner can set shareholders to share the sales amount.
    * Nft owner transfers the nft to AuctionMarketplace contract.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param _duration if the auction reach to the duration the price decreasing will be stop.
    * @param _dropInterval the intervals at which the price will be updated
    * @param _startPrice the starting price at which the price will be decreased
    * @param _endPrice the ending price at which the price will be stop decreasing
    * @param _shareholders revenue share list
    */
    function createDutchAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint64 _duration,
        uint64 _dropInterval,
        uint128 _startPrice,
        uint128 _endPrice,
        uint64 _startTime,
        LibShareholder.Shareholder[] memory _shareholders
    )
        external
        whenNotPaused
        isAuctionNotStartedByOwner(_nftContractAddress, _tokenId)
        startPriceDoesNotExceedLimit(_startPrice, _endPrice)
    {
        require((_duration <= maximumDurationPeriod) && (_duration > _dropInterval), "Duration period exceed the limit");
        require(_dropInterval >= minimumDropInterval, "Drop Interval must be higher than minimum drop interval limit");

        _configureAuction(_nftContractAddress, _tokenId, _duration, _dropInterval, _startPrice, _endPrice, _startTime, _shareholders);
        _transferNftToAuctionContract(_nftContractAddress, _tokenId);

        LibShareholder.Shareholder[] memory shareholders = _getShareholders(_nftContractAddress, _tokenId);
        emit DutchAuctionCreated(
            _nftContractAddress,
            _tokenId,
            _duration,
            _dropInterval,
            _startPrice,
            _endPrice,
            _startTime,
            shareholders
        );
    }

    /**
    * @notice If the auction ends then the seller can withdraw the auction.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function withdrawDutchAuction(address _nftContractAddress, uint256 _tokenId)
        external
        nonReentrant
        whenNotPaused
        onlyNftSeller(_nftContractAddress, _tokenId)
        isAuctionOver(_nftContractAddress, _tokenId)
    {
        _resetDutchAuction(_nftContractAddress, _tokenId);
        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        emit DutchAuctionWithdrawn(_nftContractAddress, _tokenId);
    }

    /**
    * @notice allows the buyer to make a bid and claim the nft.
    * The price is calculated using the parameters defined before on the auction.
    * Bidders must pay the calculated price. If the payment is higher than the calculated price, the excess amount will be refunded.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function makeBidForDutchAuction(address _nftContractAddress, uint256 _tokenId)
        external
        payable
        whenNotPaused
        nonReentrant
        auctionStarted(_nftContractAddress, _tokenId)
    {
        address seller = dutchAuctions[_nftContractAddress][_tokenId].seller;
        require(seller != address(0), "NFT is not deposited");
        require(msg.sender != seller, "Owner cannot bid on own NFT");
        uint256 amount = getDutchPrice(_nftContractAddress, _tokenId);
        require(msg.value >= amount, "Insufficient payment");
        _resetDutchAuction(_nftContractAddress, _tokenId);

        if (amount > 0) {
            _payout(payable(seller), _nftContractAddress, _tokenId, amount);
        }

        if (msg.value > amount) {
            _transferBidSafely(msg.sender, msg.value - amount);
        }

        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(address(this), msg.sender, _tokenId);

        emit DutchAuctionMadeBid(_nftContractAddress, _tokenId, seller, msg.value, amount);
    }

    function balance() external view returns (uint) {
        return address(this).balance;
    }

    /**
    * @notice the current dutch price by calculating the steps
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function getDutchPrice(address _nftContractAddress, uint256 _tokenId) public view returns (uint256) {
        if (block.timestamp < dutchAuctions[_nftContractAddress][_tokenId].startTime) {
            return dutchAuctions[_nftContractAddress][_tokenId].startPrice;
        }

        if ((block.timestamp - dutchAuctions[_nftContractAddress][_tokenId].startTime) > dutchAuctions[_nftContractAddress][_tokenId].duration) {
            return dutchAuctions[_nftContractAddress][_tokenId].endPrice;
        } else {
            uint256 diffPrice = dutchAuctions[_nftContractAddress][_tokenId].startPrice - dutchAuctions[_nftContractAddress][_tokenId].endPrice;
            uint256 diffDate = block.timestamp - dutchAuctions[_nftContractAddress][_tokenId].startTime;
            uint256 dropsPerStep = diffPrice / (dutchAuctions[_nftContractAddress][_tokenId].duration / dutchAuctions[_nftContractAddress][_tokenId].dropInterval);
            uint256 steps = diffDate / dutchAuctions[_nftContractAddress][_tokenId].dropInterval;
            return dutchAuctions[_nftContractAddress][_tokenId].startPrice - (steps * dropsPerStep);
        }
    }

    function _configureAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint64 _duration,
        uint64 _dropInterval,
        uint128 _startPrice,
        uint128 _endPrice,
        uint64 _startTime,
        LibShareholder.Shareholder[] memory _shareholders
    ) internal {
        _setShareholders(_nftContractAddress, _tokenId, _shareholders);
        dutchAuctions[_nftContractAddress][_tokenId].startTime = _startTime > uint64(block.timestamp) ? _startTime : uint64(block.timestamp);
        dutchAuctions[_nftContractAddress][_tokenId].duration = _duration;
        dutchAuctions[_nftContractAddress][_tokenId].dropInterval = _dropInterval;
        dutchAuctions[_nftContractAddress][_tokenId].startPrice = _startPrice;
        dutchAuctions[_nftContractAddress][_tokenId].endPrice = _endPrice;
        dutchAuctions[_nftContractAddress][_tokenId].seller = msg.sender;
        dutchAuctions[_nftContractAddress][_tokenId].commissionPercentage = IPaymentManager(paymentManager).getCommissionPercentage();
    }

    function _setShareholders(address _nftContractAddress, uint256 _tokenId, LibShareholder.Shareholder[] memory _shareholders) internal {
        // makes sure shareholders does not exceed the limits defined in PaymentManager contract
        require(_shareholders.length <= IPaymentManager(paymentManager).getMaximumShareholdersLimit(), "reached maximum shareholder count");
        uint8 j = 0;
        for (uint8 i = 0; i < _shareholders.length; i++) {
            if (_shareholders[i].account != address(0) && _shareholders[i].value > 0) {
                dutchAuctions[_nftContractAddress][_tokenId].shareholders[j].account = _shareholders[i].account;
                dutchAuctions[_nftContractAddress][_tokenId].shareholders[j].value = _shareholders[i].value;
                j += 1;
            }
        }
        dutchAuctions[_nftContractAddress][_tokenId].shareholderSize = j;
    }

    function _getShareholders(address _nftContractAddress, uint256 _tokenId) internal view returns (LibShareholder.Shareholder[] memory) {
        uint8 shareholderSize = dutchAuctions[_nftContractAddress][_tokenId].shareholderSize;
        LibShareholder.Shareholder[] memory shareholders = new LibShareholder.Shareholder[](shareholderSize);
        for (uint8 i = 0; i < shareholderSize; i++) {
            shareholders[i].account = dutchAuctions[_nftContractAddress][_tokenId].shareholders[i].account;
            shareholders[i].value = dutchAuctions[_nftContractAddress][_tokenId].shareholders[i].value;
        }
        return shareholders;
    }

    /**
    * @notice resets auction parameters
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _resetDutchAuction(address _nftContractAddress, uint256 _tokenId) internal {
        dutchAuctions[_nftContractAddress][_tokenId].startTime = 0;
        dutchAuctions[_nftContractAddress][_tokenId].duration = 0;
        dutchAuctions[_nftContractAddress][_tokenId].dropInterval = 0;
        dutchAuctions[_nftContractAddress][_tokenId].startPrice = 0;
        dutchAuctions[_nftContractAddress][_tokenId].endPrice = 0;
        dutchAuctions[_nftContractAddress][_tokenId].seller = address(0);
        for (uint8 i = 0; i < dutchAuctions[_nftContractAddress][_tokenId].shareholderSize; i++) {
            delete dutchAuctions[_nftContractAddress][_tokenId].shareholders[i];
        }
        dutchAuctions[_nftContractAddress][_tokenId].shareholderSize = 0;
    }

    /**
    * @notice Process the payment for the allowed requests.
    * Process is completed in 3 steps;commission transfer, royalty transfers and revenue share transfers.
    * @param _seller receiver address
    * @param _nftContractAddress nft contract address is used for process royalty amounts
    * @param _tokenId nft tokenId  is used for process royalty amounts
    * @param _price sent amount
    */
    function _payout(address payable _seller, address _nftContractAddress, uint256 _tokenId, uint256 _price) internal {
        LibShareholder.Shareholder[] memory shareholders = _getShareholders(_nftContractAddress, _tokenId);

        IPaymentManager(paymentManager).payout{ value: _price }(_seller, _nftContractAddress, _tokenId, shareholders, dutchAuctions[_nftContractAddress][_tokenId].commissionPercentage);
    }

    function _transferBidSafely(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        // if it fails, it will be reverted
        require(success, "Transfer failed.");
    }

    /**
    * @notice transfers nft to current contract (DutchAuctionMarketplace)
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _transferNftToAuctionContract(address _nftContractAddress, uint256 _tokenId) internal {
        address _nftSeller = dutchAuctions[_nftContractAddress][_tokenId].seller;
        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(_nftSeller, address(this), _tokenId);
    }

    /**
    * @notice makes sure auction is started
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier auctionStarted(address _nftContractAddress, uint256 _tokenId) {
        uint64 startTime = dutchAuctions[_nftContractAddress][_tokenId].startTime;

        require(block.timestamp >= startTime, "Auction is not started");
        _;
    }

    /**
    * @notice makes sure auction has not started yet and the given nft is belongs to the msg.sender
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier isAuctionNotStartedByOwner(address _nftContractAddress, uint256 _tokenId) {
        require(msg.sender != dutchAuctions[_nftContractAddress][_tokenId].seller, "Auction has been already started");
        require(msg.sender == IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId), "Sender doesn't own NFT");
        _;
    }

    /**
    * @notice makes sure msg.sender is nft owner  of the given contract address and tokenId.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier onlyNftSeller(address _nftContractAddress, uint256 _tokenId) {
        address seller = dutchAuctions[_nftContractAddress][_tokenId].seller;
        require(msg.sender == seller, "Only nft seller");
        _;
    }

    /**
    * @notice startPrice and endPrice does not exceed the limits
    * @param _startPrice starting price in ethers
    * @param _endPrice ending price in ethers
    */
    modifier startPriceDoesNotExceedLimit(uint128 _startPrice, uint128 _endPrice) {
        require((_endPrice >= minimumPriceLimit) && (_startPrice > _endPrice), "End price must be higher than minimum limit and lower than start price");
        _;
    }

    /**
    * @notice makes sure auction is over
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier isAuctionOver(address _nftContractAddress, uint256 _tokenId) {
        require((block.timestamp - dutchAuctions[_nftContractAddress][_tokenId].startTime) > dutchAuctions[_nftContractAddress][_tokenId].duration, "Auction has not over yet");
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