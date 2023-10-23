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
* @title AuctionMarketplace
* @notice allows the users to create, withdraw, settle and make bids to nft auctions.
*/
contract AuctionMarketplace is Initializable, ERC721HolderUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // contains information about an auction
    struct Auction {
        // When the nft is sold then the price will be split to the shareholders.
        mapping(uint8 => LibShareholder.Shareholder) shareholders;
        /**
        * There is a restriction about removing arrays defined in a struct.
        * This value helps to iterate and remove every shareholder value.
        */
        uint8 shareholderSize;
        // controls the bid increment for every offer
        uint32 defaultBidIncreasePercentage;
        // incremental duration value to extend auction
        uint32 defaultAuctionBidPeriod;
        // the auction ending time
        uint64 endTime;
        // the auction starting time
        uint64 startTime;
        // commission percentage
        uint96 commissionPercentage;
        // allowance for minimum bid
        uint128 minPrice;
        // if a buyer would like to buy immediately without waiting auction progress should pay buyNowPrice
        uint128 buyNowPrice;
        // keep the highest bid for every successful make bid action
        uint128 highestBid;
        // keep the highest bidder for every successful make bid action
        address highestBidder;
        // nft owner
        address seller;
    }

    /**
    * @notice manages payouts for each contract.
    */
    address public paymentManager;

    /**
    * @notice contains information about auctions
    * e.g auctions[contract_address][token_id] = Auction auction;
    */
    mapping(address => mapping(uint256 => Auction)) public auctions;

    /**
    * @notice a control variable to check the buyNowPrice of the auction is higher than minimumPrice of the auction
    * and also check the bids to the auction is greater than previous bids.
    */
    uint32 public defaultBidIncreasePercentage;

    /**
    * @notice if a bid is placed `defaultAuctionBidPeriod` minutes before the end of the auction,
    * auction duration will be extended by defaultAuctionBidPeriod minutes.
    */
    uint32 public defaultAuctionBidPeriod;

    /**
    * @notice a control variable to check the end time of the auction is in the correct range.
    */
    uint32 public maximumDurationPeriod;

    /**
    * @notice a control variable to check the minimum price of the auction is in the correct range.
    */
    uint256 public minimumPriceLimit;

    // events
    event AuctionSettled(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        address highestBidder,
        uint256 highestBid,
        bool isBuyNow
    );
    event AuctionWithdrawn(address indexed collection, uint256 indexed tokenId);
    event BidMade(address indexed collection, uint256 indexed tokenId, uint256 bid);
    event PaymentManagerSet(address indexed paymentManager);
    event DefaultBidIncreasePercentageSet(uint32 defaultBidIncreasePercentage);
    event MinimumPriceLimitSet(uint256 minimumPriceLimit);
    event MaximumDurationPeriodSet(uint32 maximumDurationPeriod);
    event DefaultAuctionBidPeriodSet(uint32 defaultAuctionBidPeriod);
    event NftAuctionCreated(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 minPrice,
        uint256 buyNowPrice,
        uint64 endTime,
        uint64 startTime,
        uint96 bidIncreasePercentage,
        LibShareholder.Shareholder[] shareholders
    );
    event FailedTransfer(address indexed receiver, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _paymentManager) public initializer addressIsNotZero(_paymentManager) {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();
        __ERC721Holder_init_unchained();
        paymentManager = _paymentManager;
        defaultBidIncreasePercentage = 500; // 5%
        defaultAuctionBidPeriod = 300; // 5 minutes
        maximumDurationPeriod = 864000; // 10 days
        minimumPriceLimit = 10000000000000000; // 0.01 ether
    }

    receive() external payable {}

    /**
    * @notice allows owner to set paymentManager contract address.
    * @param _paymentManager PaymentManager contract address.
    */
    function setPaymentManager(address _paymentManager) external onlyOwner addressIsNotZero(_paymentManager) {
        paymentManager = _paymentManager;
        emit PaymentManagerSet(_paymentManager);
    }

    /**
    * @notice allows the owner to set a `defaultBidIncreasePercentage` that is used as a control variable
    * to check the buyNowPrice of the auction is higher than minimumPrice of the auction
    * and also check the bids to the auction is greater than previous bids.
    * @param _defaultBidIncreasePercentage percentage value
    */
    function setDefaultBidIncreasePercentage(uint32 _defaultBidIncreasePercentage) external onlyOwner {
        defaultBidIncreasePercentage = _defaultBidIncreasePercentage;
        emit DefaultBidIncreasePercentageSet(_defaultBidIncreasePercentage);
    }

    /**
    * @notice allows the owner to set a minimumPriceLimit that is used as a control variable
    * to check the minimum price of the auction is in the correct range.
    * @param _minimumPriceLimit amount of ether
    */
    function setMinimumPriceLimit(uint256 _minimumPriceLimit) external onlyOwner {
        minimumPriceLimit = _minimumPriceLimit;
        emit MinimumPriceLimitSet(_minimumPriceLimit);
    }

    /**
    * @notice allows the owner to set a maximumDurationPeriod that is used as a control variable
    * to check the end time of the auction is in the correct range.
    * @param _maximumDurationPeriod timestamp value e.g 864000 (10 days)
    */
    function setMaximumDurationPeriod(uint32 _maximumDurationPeriod) external onlyOwner {
        maximumDurationPeriod = _maximumDurationPeriod;
        emit MaximumDurationPeriodSet(_maximumDurationPeriod);
    }

    /**
    * @notice allows the owner to set a `defaultAuctionBidPeriod` that is used as a control variable
    * to check whether the auction in the last x minutes.
    * @param _defaultAuctionBidPeriod timestamp value e.g 300 (5 minutes)
    */
    function setDefaultAuctionBidPeriod(uint32 _defaultAuctionBidPeriod) external onlyOwner {
        defaultAuctionBidPeriod = _defaultAuctionBidPeriod;
        emit DefaultAuctionBidPeriodSet(defaultAuctionBidPeriod);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
    * @notice allows the nft owner to create an auction. Nft owner can set shareholders to share the sales amount.
    * Nft owner transfers the nft to AuctionMarketplace contract.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param _minPrice minimum price of the auction
    * @param _buyNowPrice buy now price of the auction
    * @param _auctionEnd ending time of the auction
    * @param _auctionStart starting time of the auction
    * @param _shareholders revenue share list
    */
    function createNftAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        uint64 _auctionEnd,
        uint64 _auctionStart,
        LibShareholder.Shareholder[] memory _shareholders
    )
        external
        whenNotPaused
        isAuctionNotStartedByOwner(_nftContractAddress, _tokenId)
        minPriceDoesNotExceedLimit(_buyNowPrice, _minPrice)
        priceGreaterThanMinimumPriceLimit(_minPrice)
    {
        // configures auction
        _configureAuction(
            _nftContractAddress,
            _tokenId,
            _minPrice,
            _buyNowPrice,
            _auctionEnd,
            _auctionStart,
            _shareholders
        );

        // transfers nft to the AuctionMarketplace contract
        _transferNftToAuctionContract(_nftContractAddress, _tokenId);

        LibShareholder.Shareholder[] memory shareholders = _getShareholders(_nftContractAddress, _tokenId);

        emit NftAuctionCreated(
            _nftContractAddress,
            _tokenId,
            _minPrice,
            _buyNowPrice,
            _auctionEnd,
            _auctionStart,
            defaultBidIncreasePercentage,
            shareholders
        );
    }

    /**
    * @notice If there are no bids only nft owner can withdraw an auction.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function withdrawAuction(address _nftContractAddress, uint256 _tokenId)
        external
        whenNotPaused
        nonReentrant
        onlyNftSeller(_nftContractAddress, _tokenId)
        bidNotMade(_nftContractAddress, _tokenId)
    {
        // resets the auction
        _resetAuction(_nftContractAddress, _tokenId);

        // transfer nft to the seller back
        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(address(this), msg.sender, _tokenId);

        emit AuctionWithdrawn(_nftContractAddress, _tokenId);
    }

    /**
    * @notice If the bid amount meets requirements and the auction is ongoing then a user can make a bid.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function makeBid(address _nftContractAddress, uint256 _tokenId)
        external
        payable
        whenNotPaused
        nonReentrant
        paymentAccepted
        bidAmountMeetsBidRequirements(_nftContractAddress, _tokenId)
        auctionOngoing(_nftContractAddress, _tokenId)
    {
        require(msg.sender != auctions[_nftContractAddress][_tokenId].seller, "Owner cannot bid on own NFT");
        // previous highest bid refunded and set the new bid as highest
        _reversePreviousBidAndUpdateHighestBid(_nftContractAddress, _tokenId);
        /**
        * if the buyNowPrice is met then the auction is end
        * in other case if the endTime is in the last x minutes than the end time will be extended x minutes
        */
        if (_isBuyNowPriceMet(_nftContractAddress, _tokenId)) {
            _transferNftAndPaySeller(_nftContractAddress, _tokenId, true);
        } else {
            if (_isAuctionCloseToEnd(_nftContractAddress, _tokenId)) {
                _updateAuctionEnd(_nftContractAddress, _tokenId);
            }
            emit BidMade(_nftContractAddress, _tokenId, msg.value);
        }
    }

    /**
    * @notice auction can be settled by either buyer and seller if an auction ends and there is a highest bid.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function settleAuction(address _nftContractAddress, uint256 _tokenId)
        external
        whenNotPaused
        nonReentrant
        isAuctionOver(_nftContractAddress, _tokenId)
        bidMade(_nftContractAddress, _tokenId)
    {
        // ends the auction and makes the transfers
        _transferNftAndPaySeller(_nftContractAddress, _tokenId, false);
    }

    function balance() external view returns (uint) {
        return address(this).balance;
    }

    function _configureAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint128 _minPrice,
        uint128 _buyNowPrice,
        uint64 _auctionEnd,
        uint64 _auctionStart,
        LibShareholder.Shareholder[] memory _shareholders
    ) internal {
        uint64 auctionStart = _auctionStart > uint64(block.timestamp) ? _auctionStart : uint64(block.timestamp);
        require(
            (_auctionEnd > auctionStart) && (_auctionEnd <= (auctionStart + maximumDurationPeriod)),
            "Ending time of the auction isn't within the allowable range"
        );
        _setShareholders(_nftContractAddress, _tokenId, _shareholders);
        auctions[_nftContractAddress][_tokenId].endTime = _auctionEnd;
        auctions[_nftContractAddress][_tokenId].startTime = auctionStart;
        auctions[_nftContractAddress][_tokenId].buyNowPrice = _buyNowPrice;
        auctions[_nftContractAddress][_tokenId].minPrice = _minPrice;
        auctions[_nftContractAddress][_tokenId].seller = msg.sender;
        auctions[_nftContractAddress][_tokenId].defaultBidIncreasePercentage = defaultBidIncreasePercentage;
        auctions[_nftContractAddress][_tokenId].defaultAuctionBidPeriod = defaultAuctionBidPeriod;
        uint96 commissionPercentage = IPaymentManager(paymentManager).getCommissionPercentage();
        auctions[_nftContractAddress][_tokenId].commissionPercentage = commissionPercentage;
    }

    /**
    * @notice previous highest bid refunded and set the new bid as highest.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _reversePreviousBidAndUpdateHighestBid(address _nftContractAddress, uint256 _tokenId) internal {
        address prevNftHighestBidder = auctions[_nftContractAddress][_tokenId].highestBidder;
        uint256 prevNftHighestBid = auctions[_nftContractAddress][_tokenId].highestBid;

        auctions[_nftContractAddress][_tokenId].highestBid = uint128(msg.value);
        auctions[_nftContractAddress][_tokenId].highestBidder = msg.sender;

        if (prevNftHighestBidder != address(0)) {
            _transferBidSafely(prevNftHighestBidder, prevNftHighestBid);
        }
    }

    function _setShareholders(
        address _nftContractAddress,
        uint256 _tokenId, LibShareholder.Shareholder[] memory _shareholders
    ) internal {
        // makes sure shareholders does not exceed the limits defined in PaymentManager contract
        require(
            _shareholders.length <= IPaymentManager(paymentManager).getMaximumShareholdersLimit(),
            "reached maximum shareholder count"
        );
        uint8 j = 0;
        for (uint8 i = 0; i < _shareholders.length; i++) {
            if (_shareholders[i].account != address(0) && _shareholders[i].value > 0) {
                auctions[_nftContractAddress][_tokenId].shareholders[j].account = _shareholders[i].account;
                auctions[_nftContractAddress][_tokenId].shareholders[j].value = _shareholders[i].value;
                j += 1;
            }
        }
        auctions[_nftContractAddress][_tokenId].shareholderSize = j;
    }

    function _getShareholders(address _nftContractAddress, uint256 _tokenId)
        internal
        view
        returns (LibShareholder.Shareholder[] memory)
    {
        uint256 shareholderSize = auctions[_nftContractAddress][_tokenId].shareholderSize;
        LibShareholder.Shareholder[] memory shareholders = new LibShareholder.Shareholder[](shareholderSize);
        for (uint8 i = 0; i < shareholderSize; i++) {
            shareholders[i].account = auctions[_nftContractAddress][_tokenId].shareholders[i].account;
            shareholders[i].value = auctions[_nftContractAddress][_tokenId].shareholders[i].value;
        }
        return shareholders;
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

        IPaymentManager(paymentManager).payout{ value: _price }(
            _seller,
            _nftContractAddress,
            _tokenId, shareholders,
            auctions[_nftContractAddress][_tokenId].commissionPercentage
        );
    }

    /**
    * @notice extends auction end time as specified in `defaultAuctionBidPeriod`
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _updateAuctionEnd(address _nftContractAddress, uint256 _tokenId) internal {
        auctions[_nftContractAddress][_tokenId].endTime += auctions[_nftContractAddress][_tokenId].defaultAuctionBidPeriod;
    }

    /**
    * @notice checks auction end time is in the last x minutes
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _isAuctionCloseToEnd(address _nftContractAddress, uint256 _tokenId) internal view returns (bool) {
        uint64 extendedEndTime = uint64(block.timestamp) + auctions[_nftContractAddress][_tokenId].defaultAuctionBidPeriod;
        return extendedEndTime > auctions[_nftContractAddress][_tokenId].endTime;
    }

    /**
    * @notice in the case of isBuyNowPrice is set then checks the highest bid is met with buyNowPrice
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _isBuyNowPriceMet(address _nftContractAddress, uint256 _tokenId) internal view returns (bool) {
        uint128 buyNowPrice = auctions[_nftContractAddress][_tokenId].buyNowPrice;
        return buyNowPrice > 0 && auctions[_nftContractAddress][_tokenId].highestBid >= buyNowPrice;
    }

    /**
    * @notice checks there is a bid for the auction
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _isBidMade(address _nftContractAddress, uint256 _tokenId) internal view returns (bool) {
        return auctions[_nftContractAddress][_tokenId].highestBid > 0;
    }

    /**
    * @notice in the case of `isBuyNowPrice` is set then checks the sent amount is higher than buyNowPrice
    * in other case sent amount must be higher than or equal to the `minPrice`
    * the last case is sent amount must be higher than or equal to the x percent more than previous bid
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _doesBidMeetBidRequirements(address _nftContractAddress, uint256 _tokenId) internal view returns (bool) {
        uint128 buyNowPrice = auctions[_nftContractAddress][_tokenId].buyNowPrice;
        if (buyNowPrice > 0 && msg.value >= buyNowPrice) {
            return true;
        }
        uint128 minPrice = auctions[_nftContractAddress][_tokenId].minPrice;
        if (minPrice > msg.value) {
            return false;
        }
        uint256 highestBid = auctions[_nftContractAddress][_tokenId].highestBid;
        uint32 increasePercentage = auctions[_nftContractAddress][_tokenId].defaultBidIncreasePercentage;
        uint256 bidIncreaseAmount = (highestBid * (10000 + increasePercentage)) / 10000;
        return msg.value >= bidIncreaseAmount;
    }

    function _transferBidSafely(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        // if it fails, it updates their credit balance so they can withdraw later
        if (!success) {
            IPaymentManager(paymentManager).depositFailedBalance{value: _amount}(_recipient);
            emit FailedTransfer(_recipient, _amount);
        }
    }

    /**
    * @notice transfers nft to current contract (AuctionMarketplace)
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _transferNftToAuctionContract(address _nftContractAddress, uint256 _tokenId) internal {
        address _nftSeller = auctions[_nftContractAddress][_tokenId].seller;
        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(_nftSeller, address(this), _tokenId);
    }

    /**
    * @notice transfers nft to the highest bidder and pay the highest bid to the nft seller
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _transferNftAndPaySeller(address _nftContractAddress, uint256 _tokenId, bool isBuyNow) internal {
        address _nftSeller = auctions[_nftContractAddress][_tokenId].seller;
        address _nftHighestBidder = auctions[_nftContractAddress][_tokenId].highestBidder;
        uint256 _nftHighestBid = auctions[_nftContractAddress][_tokenId].highestBid;

        _resetBids(_nftContractAddress, _tokenId);

        _payout(payable(_nftSeller), _nftContractAddress, _tokenId, _nftHighestBid);

        _resetAuction(_nftContractAddress, _tokenId);

        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(address(this), _nftHighestBidder, _tokenId);
        emit AuctionSettled(_nftContractAddress, _tokenId, _nftSeller, _nftHighestBidder, _nftHighestBid, isBuyNow);
    }

    /**
    * @notice resets auction parameters
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _resetAuction(address _nftContractAddress, uint256 _tokenId) internal {
        auctions[_nftContractAddress][_tokenId].minPrice = 0;
        auctions[_nftContractAddress][_tokenId].buyNowPrice = 0;
        auctions[_nftContractAddress][_tokenId].startTime = 0;
        auctions[_nftContractAddress][_tokenId].endTime = 0;
        auctions[_nftContractAddress][_tokenId].seller = address(0);
        auctions[_nftContractAddress][_tokenId].defaultBidIncreasePercentage = 0;
        auctions[_nftContractAddress][_tokenId].defaultAuctionBidPeriod = 0;
        for (uint8 i = 0; i < auctions[_nftContractAddress][_tokenId].shareholderSize; i++) {
            delete auctions[_nftContractAddress][_tokenId].shareholders[i];
        }
        auctions[_nftContractAddress][_tokenId].shareholderSize = 0;
    }

    /**
    * @notice resets auction bids
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function _resetBids(address _nftContractAddress, uint256 _tokenId) internal {
        auctions[_nftContractAddress][_tokenId].highestBidder = address(0);
        auctions[_nftContractAddress][_tokenId].highestBid = 0;
    }

    /**
    * @notice makes sure a bid is applicable to buy the nft. In the case of sale, the bid needs to meet the buyNowPrice.
    * In other cases the bid needs to be a % higher than the previous bid.
    * @param _buyNowPrice a limit that allows bidders to buy directly
    * @param _minPrice a restriction for the bidders must pay minimum x amount.
    */
    modifier minPriceDoesNotExceedLimit(uint128 _buyNowPrice, uint128 _minPrice) {
        require(
            _buyNowPrice == 0 ||  (_buyNowPrice * (10000 + defaultBidIncreasePercentage) / 10000) >=_minPrice,
            "buyNowPrice must be greater than or equal to %defaultBidIncreasePercentage percent more than minimumPrice"
        );
        _;
    }

    /**
    * @notice makes sure auction has not started yet and the given nft is belongs to the msg.sender
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier isAuctionNotStartedByOwner(address _nftContractAddress, uint256 _tokenId) {
        require(msg.sender != auctions[_nftContractAddress][_tokenId].seller, "Auction has been already started");
        require(msg.sender == IERC721Upgradeable(_nftContractAddress).ownerOf(_tokenId), "Sender doesn't own NFT");
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
    * @notice sent amount must be greater than zero
    */
    modifier paymentAccepted() {
        require(msg.value > 0, "Bid must be greater than zero");
        _;
    }

    /**
    * @notice makes sure a bid is applicable to buy the nft.
    * In the case of sale, the bid needs to meet the buyNowPrice.
    * In other cases the bid needs to be a % higher than the previous bid.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier bidAmountMeetsBidRequirements(address _nftContractAddress, uint256 _tokenId) {
        require(_doesBidMeetBidRequirements(_nftContractAddress, _tokenId), "Not enough funds to bid on NFT");
        _;
    }

    /**
    * @notice makes sure auction is ongoing in the range of between startTime and endTime
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier auctionOngoing(address _nftContractAddress, uint256 _tokenId) {
        uint64 endTime = auctions[_nftContractAddress][_tokenId].endTime;
        uint64 startTime = auctions[_nftContractAddress][_tokenId].startTime;

        require((block.timestamp >= startTime) && (block.timestamp < endTime), "Auction is not going on");
        _;
    }

    /**
    * @notice makes sure auction is over
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier isAuctionOver(address _nftContractAddress, uint256 _tokenId) {
        require(block.timestamp >= auctions[_nftContractAddress][_tokenId].endTime, "Auction has not over yet");
        _;
    }

    /**
    * @notice makes sure no bids have been submitted to the auction yet.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier bidNotMade(address _nftContractAddress, uint256 _tokenId) {
        require(!_isBidMade(_nftContractAddress, _tokenId), "The auction has a valid bid made");
        _;
    }

    /**
    * @notice makes sure bids have been received in the auction.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier bidMade(address _nftContractAddress, uint256 _tokenId) {
        require(_isBidMade(_nftContractAddress, _tokenId), "The auction has not a valid bid made");
        _;
    }

    /**
    * @notice makes sure msg.sender is nft owner  of the given contract address and tokenId.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier onlyNftSeller(address _nftContractAddress, uint256 _tokenId) {
        address seller = auctions[_nftContractAddress][_tokenId].seller;
        require(msg.sender == seller, "Only nft seller");
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