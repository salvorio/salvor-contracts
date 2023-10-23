//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "../Royalty/IRoyalty.sol";
import "../Royalty/LibRoyalty.sol";
import "../NFTCollectible/INFTCollectible.sol";
import "../PaymentManager/IPaymentManager.sol";
import "../libs/LibShareholder.sol";

/**
* @title ArtMarketplace
* @notice the users can simply list and lock their NFTs for a specific period and earn rewards if it does not sell.
*/
contract ArtMarketplace is OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC721HolderUpgradeable, PausableUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Node {
        // holds the index of the next node in the linked list.
        uint256 tokenId;
        // variable holds the listing price of the NFT
        uint256 price;
        // holds the index of the previous node in the linked list.
        uint64 previousIndex;
        // holds the index of the next node in the linked list.
        uint64 nextIndex;
        // set to true when the NFT is deposited, otherwise it will be false, it determines that NFT is available to buy or not.
        bool isActive;
    }

    struct Order {
        // holds the wallet address of the seller who listed the NFT.
        address seller;
        // holds the timestamp indicating when the NFT was listed.
        uint256 startedAt;
        // holds the listing price of the NFT
        uint256 price;
        // holds the duration for which NFTs will be locked.
        uint256 lockDuration;
        // holds the percentage of commission taken from every sale.
        uint96 commissionPercentage;
        // holds the pointer for matched node
        uint64 nodeIndex;
        /**
        * There is a restriction about removing arrays defined in a struct.
        * This value helps to iterate and remove every shareholder value.
        */
        uint8 shareholderSize;
        // set to true when the NFT is deposited, otherwise it will be false and it determines that users will not receive the reward
        bool isRewardable;
    }

    struct UserInfo {
        // holds the total number of NFTs for the user that are eligible for rewards in the pool.
        uint256 rewardableNFTCount;
        // The amount of ART entitled to the user.
        uint256 rewardDebt;
        // the balance that the user has failed to collect as rewards.
        uint256 failedBalance;
    }

    struct PoolInfo {
        // represents the rate at which rewards are generated for the pool.
        uint256 rewardGenerationRate;
        // represents the total amount of art accumulated per share.
        uint256 accARTPerShare;
        // holds the timestamp of the last reward that was generated for the pool.
        uint256 lastRewardTimestamp;
        // holds the total number of NFTs that are eligible for rewards in the pool.
        uint256 totalRewardableNFTCount;
        // holds the initial floor price of NFTs
        uint256 initialFloorPrice;
        // holds the duration for which NFTs will be locked.
        uint256 lockDuration;
        // holds the minimum number of nodes that need to be active for the floor price to be increased.
        uint256 floorPriceThresholdNodeCount;
        // holds the index of the node responsible for updating the floor price of NFTs when the number of deposited nodes exceeds the specified number in "floorPriceThresholdNodeCount".
        // This information is used to determine the current floor price of NFTs.
        uint256 activeNodeCount;
        // holds the percentage by which the floor price of the NFTs will increase.
        uint96 floorPriceIncreasePercentage;
        // holds the percentage of commission taken from every sale.
        uint96 commissionPercentage;
        // holds the index of the node responsible for restricting the floor price.
        uint64 floorPriceNodeIndex;
    }

    bytes4 private constant _INTERFACE_ID_ERC721 = 0x80ac58cd;

    /// @notice Address of ART contract.
    IERC20Upgradeable public art;

    /**
	* @notice manages payouts for each contract.
    */
    address public paymentManager;

    // mapping of address to PoolInfo structure to store information of all liquidity pools.
    mapping(address => PoolInfo) public pools;

    // an array of Node structs, which holds information about each node in the pool.   
    mapping(address => Node[]) public nodes;

    // holds information about each user in the pool
    mapping(address => mapping(address => UserInfo)) public users;

    // the NFTs listed for trade in a specific pool.
    mapping(address => mapping(uint256 => Order)) public listedNFTs;

    // mapping of uint8 to LibShareholder.Shareholder structs, which holds information about each shareholder in the NFT.
    mapping(address => mapping(uint256 => mapping(uint8 => LibShareholder.Shareholder))) public shareholders;

    // Set of all LP tokens that have been added as pools
    EnumerableSetUpgradeable.AddressSet private lpCollections;

    // By using a factor such as ACC_TOKEN_PRECISION, accARTPerShare is stored in a highly accurate manner.
    // This factor is present to reduce loss from division operations. 
    uint256 private constant ACC_TOKEN_PRECISION = 1e18;

    address public admin;

    event Deposit(address indexed user, address indexed lpAddress, uint256 tokenId, uint256 price);
    event Withdraw(address indexed user, address indexed lpAddress, uint256 tokenId);
    event Buy(address indexed seller, address indexed user, address indexed lpAddress, uint256 tokenId, uint256 price);
    event UpdatePool(address indexed lpAddress, uint256 lastRewardTimestamp, uint256 lpSupply, uint256 accARTPerShare);
    event Harvest(address indexed user, address indexed lpAddress, uint256 amount, bool isStandalone);
    event EndRewardPeriod(address indexed lpAddress, uint256 indexed tokenId, address indexed user);
    event ReAdjustNFT(address indexed lpAddress, uint256 tokenId);
    event PaymentManagerSet(address indexed paymentManager);

    /**
	* @notice checks the given value is not zero address
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }

    /**
	* @notice makes sure price is greater than 0
    */
    modifier priceAccepted(uint256 _price) {
        require(_price > 0, "Price must be grater then zero");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Upgradeable _art, address _paymentManager)
    public
    initializer
    addressIsNotZero(_paymentManager)
    addressIsNotZero(address(_art)) {

        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
        art = _art;
        paymentManager = _paymentManager;
        emit PaymentManagerSet(_paymentManager);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
    }

    /**
	* @notice allows owner to update the pool info.
    * @param _lpAddress the address of the liquidity pool
    * @param _rewardGenerationRate the reward generation rate of the liquidity pool
    * @param _initialFloorPrice the initial floor price of the liquidity pool
    * @param _floorPriceThresholdNodeCount the threshold limit used to determine the actual calculated floor price when the deposited NFT count surpasses the threshold value.
    * @param _lockDuration the lock duration of NFTs in the liquidity pool
    * @param _floorPriceIncreasePercentage the percentage increase of the floor price
    * @param _commissionPercentage the percentage of the transaction fee
    */
    function updatePoolInfo(
        address _lpAddress,
        uint256 _rewardGenerationRate,
        uint256 _initialFloorPrice,
        uint256 _floorPriceThresholdNodeCount,
        uint256 _lockDuration,
        uint96 _floorPriceIncreasePercentage,
        uint96 _commissionPercentage
    ) external {
        require(msg.sender == owner() || msg.sender == admin, "caller is not authorized");
        require(_rewardGenerationRate < 772000000000000000, "allowable generation rate is reached");
        require(lpCollections.contains(_lpAddress), "The provided liquidity pool does not exist");
        _updatePool(_lpAddress);
        PoolInfo memory pool = pools[_lpAddress];
        pool.rewardGenerationRate = _rewardGenerationRate;
        pool.initialFloorPrice = _initialFloorPrice;
        pool.floorPriceThresholdNodeCount = _floorPriceThresholdNodeCount;
        pool.lockDuration = _lockDuration;
        pool.floorPriceIncreasePercentage = _floorPriceIncreasePercentage;
        pool.commissionPercentage = _commissionPercentage;
        pools[_lpAddress] = pool;
    }


    /**
	* @notice used to collect (or "harvest") the rewards that have been generated for a specific user in a specific liquidity pool
    * @param _lpAddress the address of the liquidity pool
    * @param _receiver the address of the receiver
    */
    function harvest(address _lpAddress, address _receiver) external addressIsNotZero(_lpAddress) addressIsNotZero(_receiver) {
        _updatePool(_lpAddress);
        UserInfo memory user = users[_lpAddress][_receiver];
        uint256 accArtPerShare = pools[_lpAddress].accARTPerShare;
        uint256 previousRewardDebt = user.rewardDebt;
        users[_lpAddress][_receiver].rewardDebt = (user.rewardableNFTCount * accArtPerShare) / ACC_TOKEN_PRECISION;
        uint256 pending = ((user.rewardableNFTCount * accArtPerShare) / ACC_TOKEN_PRECISION) - previousRewardDebt;

        if (pending > 0 || user.failedBalance > 0) {
            emit Harvest(_receiver, _lpAddress, pending, true);
            _safeTransfer(_lpAddress, _receiver, pending);
        }
    }

    /**
    * @notice returns an array of Node structs, which holds information about each node in the pool.
    * It retrieves the relevant information about the nodes from storage by returning the 'nodes' variable from the 'pools[_lpAddress]' struct.
    * Additionally this function helps to calculate the position of the new node to be added to the pool in the linked list by providing all the nodes already listed in the pool.
    * @param _lpAddress the address of the liquidity pool
    */
    function listNodes(address _lpAddress) external view returns (Node[] memory) {
        return nodes[_lpAddress];
    }

    /**
    * @notice returns a specific Node struct from the pool, based on the provided index
    * @param _lpAddress the address of the liquidity pool
    * @param _index the index of the Node
    */
    function getNode(address _lpAddress, uint64 _index) external view returns (Node memory) {
        return nodes[_lpAddress][_index];
    }

    /**
    * @notice returns the UserInfo struct of a specific user in a specific liquidity pool
    * @param _lpAddress the address of the liquidity pool
    * @param _user the address of the user
    */
    function getUser(address _lpAddress, address _user) external view returns (UserInfo memory) {
        return users[_lpAddress][_user];
    }

    /**
    * @notice allows the owner to add a new liquidity pool to the contract.
    * @param _lpAddress the address of the liquidity pool
    * @param _generationRate the reward generation rate
    * @param _initialFloorPrice the initial floor price
    * @param _floorPriceThresholdNodeCount the threshold limit used to determine the actual calculated floor price when the deposited NFT count surpasses the threshold value.
    * @param _floorPriceIncreasePercentage the floor price increase percentage
    * @param _lockDuration the lock duration
    * @param _commissionPercentage the commission percentage
    */
    function addPool(
        address _lpAddress,
        uint256 _generationRate,
        uint256 _initialFloorPrice,
        uint256 _floorPriceThresholdNodeCount,
        uint96 _floorPriceIncreasePercentage,
        uint256 _lockDuration,
        uint96 _commissionPercentage
    ) external onlyOwner {
        require(msg.sender == owner() || msg.sender == admin, "caller is not authorized");
        require(_generationRate < 772000000000000000, "allowable generation rate is reached");
        require(!lpCollections.contains(_lpAddress), "add: LP already added");
        require(_commissionPercentage < 2000, "commission percentage cannot be higher than 20%");
        // check to ensure _lpCollection is an ERC721 address
        require(IERC721Upgradeable(_lpAddress).supportsInterface(_INTERFACE_ID_ERC721), "only erc721 is supported");

        pools[_lpAddress] = PoolInfo({
        rewardGenerationRate: _generationRate,
        lastRewardTimestamp: block.timestamp,
        initialFloorPrice: _initialFloorPrice,
        floorPriceIncreasePercentage: _floorPriceIncreasePercentage,
        lockDuration: _lockDuration,
        commissionPercentage: _commissionPercentage,
        floorPriceThresholdNodeCount: _floorPriceThresholdNodeCount,
        accARTPerShare: 0,
        totalRewardableNFTCount: 0,
        floorPriceNodeIndex: 0,
        activeNodeCount: 0
        });

        lpCollections.add(_lpAddress);
    }

    /**
    * @notice calculates and returns the pending rewards for a specific user in a specific liquidity pool.
    * @param _lpAddress the address of the liquidity pool
    * @param _user the address of the user
    */
    function pendingRewards(address _lpAddress, address _user) external view returns (uint256) {
        PoolInfo memory pool = pools[_lpAddress];
        UserInfo memory user = users[_lpAddress][_user];
        uint256 accARTPerShare = pool.accARTPerShare;
        if (block.timestamp > pool.lastRewardTimestamp && pool.totalRewardableNFTCount > 0) {
            uint256 secondsElapsed = block.timestamp - pool.lastRewardTimestamp;
            uint256 artReward = secondsElapsed * pool.rewardGenerationRate;
            accARTPerShare = accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / pool.totalRewardableNFTCount);
        }
        return ((user.rewardableNFTCount * accARTPerShare) / ACC_TOKEN_PRECISION) - user.rewardDebt;
    }

    /**
    * @notice If the requirements are met, this function ends the reward period of multiple NFTs at once. Be cautious of gas spending!
    * @param _lpAddresses an array of addresses of liquidity pools
    * @param _tokenIds an array of token ids
    */
    function massEndRewardPeriod(address[] calldata _lpAddresses, uint256[] calldata _tokenIds) external whenNotPaused {
        uint256 len = _lpAddresses.length;
        for (uint256 i; i < len; ++i) {
            endRewardPeriod(_lpAddresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice allows the owner of a listed NFT to withdraw it from the specified liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function withdrawNFT(address _lpAddress, uint256 _tokenId) external whenNotPaused nonReentrant {
        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];
        require(listedNFT.seller == msg.sender, "The sender is not the owner of the listed NFT and cannot withdraw it.");
        require((block.timestamp - listedNFT.startedAt) > listedNFT.lockDuration, "The minimum lock duration has not expired.");
        _withdrawNFT(_lpAddress, _tokenId);
    }

    /**
	* @notice Allows the owner to emergency withdraw a listed NFT from the specified LP pool by providing the LP address and NFT ID.
    * The NFT will be withdrawn only if it was previously listed for sale by a seller.
    * This function should be used in case of emergencies only.
    * @param _lpAddress The address of the LP pool from which to withdraw the NFT.
    * @param _tokenId The ID of the NFT to withdraw.
    */
    function emergencyWithdrawNFT(address _lpAddress, uint256 _tokenId) external onlyOwner {
        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];
        require(listedNFT.seller != address(0x0), "The NFT is not currently listed for sale");
        _withdrawNFT(_lpAddress, _tokenId);
    }

    function depositNFTs(
        address[] calldata _lpAddresses,
        uint256[] calldata _tokenIds,
        uint256 _price,
        uint64[] calldata _freeIndexes,
        uint64 _previousIndex,
        LibShareholder.Shareholder[] memory _shareholders
    ) external {
        uint256 len = _lpAddresses.length;
        require(len <= 100, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            uint64 previousIndex = i == 0 ? _previousIndex : _freeIndexes[i - 1];
            depositNFT(_lpAddresses[i], _tokenIds[i], _price, _freeIndexes[i], previousIndex, _shareholders);
        }
    }

    function buyNFTs(address[] calldata _lpAddresses, uint256[] calldata _tokenIds) external payable {
        uint256 len = _lpAddresses.length;
        require(len <= 100, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            buyNFT(_lpAddresses[i], _tokenIds[i]);
        }
    }

    function reAdjustNFTs(
        address _lpAddress,
        uint256[] calldata _tokenIds,
        uint256 _price,
        uint64 _previousIndex
    ) external whenNotPaused nonReentrant {
        require(lpCollections.contains(_lpAddress), "The provided liquidity pool does not exist");
        uint256 totalReadjustedItemCount = _tokenIds.length;
        require(totalReadjustedItemCount <= 100, "exceeded the limits");
        for (uint64 i; i < totalReadjustedItemCount; ++i) {
            uint256 _tokenId = _tokenIds[i];
            require(listedNFTs[_lpAddress][_tokenId].seller == msg.sender, "Only the owner of the listed NFT can re-adjust it");
            require(!listedNFTs[_lpAddress][_tokenId].isRewardable, "A rewardable NFT cannot be re-adjusted");

            _dropNode(_lpAddress, _tokenId);
        }
        for (uint64 i; i < totalReadjustedItemCount; ++i) {
            uint64 _calculatedPreviousIndex = i == 0 ? _previousIndex : listedNFTs[_lpAddress][_tokenIds[i-1]].nodeIndex;
            uint256 _tokenId = _tokenIds[i];

            uint256 floorPrice = pools[_lpAddress].initialFloorPrice;
            if (pools[_lpAddress].activeNodeCount > 0 && nodes[_lpAddress][pools[_lpAddress].floorPriceNodeIndex].price < floorPrice) {
                floorPrice = nodes[_lpAddress][pools[_lpAddress].floorPriceNodeIndex].price;
            }
            uint256 allowableMaxPrice = (floorPrice * (10000 + pools[_lpAddress].floorPriceIncreasePercentage)) / 10000;
            require(_price <= allowableMaxPrice, "The provided price exceeds the allowable maximum price for this liquidity pool");
            uint64 freeIndex = listedNFTs[_lpAddress][_tokenId].nodeIndex;
            listedNFTs[_lpAddress][_tokenId].isRewardable = true;
            listedNFTs[_lpAddress][_tokenId].startedAt = block.timestamp;
            listedNFTs[_lpAddress][_tokenId].price = _price;
            _addNode(_lpAddress, _tokenId, _price, freeIndex, _calculatedPreviousIndex);

            emit ReAdjustNFT(_lpAddress, _tokenId);
        }

        _updatePool(_lpAddress);
        uint256 pending;
        if (users[_lpAddress][msg.sender].rewardableNFTCount > 0) {
            pending = ((users[_lpAddress][msg.sender].rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION) - users[_lpAddress][msg.sender].rewardDebt;
            if (pending > 0) {
                emit Harvest(msg.sender, _lpAddress, pending, false);
            }
        }


        users[_lpAddress][msg.sender].rewardableNFTCount += totalReadjustedItemCount;
        users[_lpAddress][msg.sender].rewardDebt = (users[_lpAddress][msg.sender].rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION;

        pools[_lpAddress].totalRewardableNFTCount += totalReadjustedItemCount;

        if (pending > 0) {
            _safeTransfer(_lpAddress, msg.sender, pending);
        }
    }

    /**
    * @notice allows a user to buy a listed NFT from a specified liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function buyNFT(address _lpAddress, uint256 _tokenId) public payable nonReentrant whenNotPaused {
        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];
        require(listedNFT.seller != address(0x0), "The NFT with this token ID is not currently listed on this liquidity pool.");
        require(listedNFT.seller != msg.sender, "Cannot buy your own NFT");
        require(msg.value >= listedNFT.price, "Incorrect payment amount");

        PoolInfo memory pool = pools[_lpAddress];
        UserInfo memory user = users[_lpAddress][listedNFT.seller];

        _dropNode(_lpAddress, _tokenId);

        emit Buy(listedNFT.seller, msg.sender, _lpAddress, _tokenId, listedNFT.price);

        _updatePool(_lpAddress);
        uint256 pending;
        if (user.rewardableNFTCount > 0) {
            pending = ((user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION) - user.rewardDebt;
            if (pending > 0) {
                emit Harvest(listedNFT.seller, _lpAddress, pending, false);
            }
        }

        if (listedNFT.isRewardable) {
            user.rewardableNFTCount -= 1;
            pools[_lpAddress].totalRewardableNFTCount = pool.totalRewardableNFTCount - 1;
        }
        users[_lpAddress][listedNFT.seller].rewardDebt = (user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION;
        users[_lpAddress][listedNFT.seller].rewardableNFTCount = user.rewardableNFTCount;

        LibShareholder.Shareholder[] memory _shareholders = _getShareholders(_lpAddress, _tokenId);
        _resetListedNFT(_lpAddress, _tokenId, listedNFTs[_lpAddress][_tokenId].shareholderSize);

        IERC721Upgradeable(_lpAddress).safeTransferFrom(address(this), msg.sender, _tokenId);

        IPaymentManager(paymentManager).payout{ value: listedNFT.price }(
            payable(listedNFT.seller),
            _lpAddress,
            _tokenId,
            _shareholders,
            listedNFT.commissionPercentage
        );

        if (pending > 0) {
            _safeTransfer(_lpAddress, listedNFT.seller, pending);
        }
    }


    /**
    * @notice allows a user to deposit an NFT token to a specific liquidity pool.
    * _freeIndex and _previousIndex help to keep track of the node position in the doubly linked list, for example, to know which node is the next or previous one, or to know the order of the nodes.
    * The floor price is used to prevent the listing of NFTs at excessively high prices.
    * The floor price is determined by taking the price of the node at a specific index in the doubly linked list, which is determined by the number of nodes in the pool and a threshold value provided during the creation of the pool.
    * The function checks if the provided price is less than or equal to the floor price. If the provided price is higher it throws an error message, preventing the user from listing an NFT at an excessively high price.
    * It is also worth noting that floor price is also protected by a percentage increase value that is set during the pool creation, this means that the floor price can't be exceeded by more than the value of the percentage increase.
    * @param _lpAddress the address of the liquidity pool
    * @param _tokenId the token ID of the NFT
    * @param _price the price at which the NFT will be listed
    * @param _freeIndex is the index of the next available node in the 'nodes' array, where the new node will be added.
    * @param _previousIndex is the index of the node that comes before the new node in the list. This allows for easy traversal of the nodes in the list and maintaining the order of the nodes.
    * @param _shareholders an array of Shareholder structs representing the shareholders of the token
    */
    function depositNFT(
        address _lpAddress,
        uint256 _tokenId,
        uint256 _price,
        uint64 _freeIndex,
        uint64 _previousIndex,
        LibShareholder.Shareholder[] memory _shareholders
    ) public priceAccepted(_price) whenNotPaused nonReentrant {
        require(lpCollections.contains(_lpAddress), "The provided liquidity pool does not exist");

        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];

        require(listedNFT.seller == address(0), "The provided NFT has already been listed on this pool");
        require(IERC721Upgradeable(_lpAddress).ownerOf(_tokenId) == msg.sender, "The provided NFT does not belong to the sender");

        PoolInfo memory pool = pools[_lpAddress];
        UserInfo memory user = users[_lpAddress][msg.sender];

        uint256 floorPrice = pool.initialFloorPrice;
        if (pool.activeNodeCount > 0 && nodes[_lpAddress][pool.floorPriceNodeIndex].price < floorPrice) {
            floorPrice = nodes[_lpAddress][pool.floorPriceNodeIndex].price;
        }
        uint256 allowableMaxPrice = (floorPrice * (10000 + pool.floorPriceIncreasePercentage)) / 10000;
        require(_price <= allowableMaxPrice, "The provided price exceeds the allowable maximum price for this liquidity pool");

        _addNode(_lpAddress, _tokenId, _price, _freeIndex, _previousIndex);

        _updatePool(_lpAddress);
        uint256 pending;
        if (user.rewardableNFTCount > 0) {
            pending = ((user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION);
            pending -= user.rewardDebt;
            if (pending > 0) {
                emit Harvest(msg.sender, _lpAddress, pending, false);
            }
        }

        emit Deposit(msg.sender, _lpAddress, _tokenId, _price);

        listedNFTs[_lpAddress][_tokenId] = Order({
        seller: msg.sender,
        price: _price,
        startedAt: block.timestamp,
        isRewardable: true,
        nodeIndex: _freeIndex,
        commissionPercentage: pool.commissionPercentage,
        lockDuration: pool.lockDuration,
        shareholderSize: 0
        });

        _setShareholders(_lpAddress, _tokenId, _shareholders);

        user.rewardableNFTCount += 1;
        users[_lpAddress][msg.sender].rewardDebt = (user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION;
        users[_lpAddress][msg.sender].rewardableNFTCount = user.rewardableNFTCount;

        pools[_lpAddress].totalRewardableNFTCount = pool.totalRewardableNFTCount + 1;

        IERC721Upgradeable(_lpAddress).safeTransferFrom(msg.sender, address(this), _tokenId);
        if (pending > 0) {
            _safeTransfer(_lpAddress, msg.sender, pending);
        }
    }

    /**
    * @notice Ends the reward period for a specific NFT token in a specific liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function endRewardPeriod(address _lpAddress, uint256 _tokenId) public whenNotPaused {
        require(lpCollections.contains(_lpAddress), "The provided liquidity pool does not exist");

        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];
        require(listedNFT.seller != address(0), "The NFT with this token ID is not currently listed on this liquidity pool.");
        require(listedNFT.isRewardable, "The reward period for this NFT has already ended.");

        PoolInfo memory pool = pools[_lpAddress];
        require((block.timestamp - listedNFT.startedAt) > listedNFT.lockDuration, "The minimum lock duration has not expired.");

        UserInfo memory user = users[_lpAddress][listedNFT.seller];

        emit EndRewardPeriod(_lpAddress, _tokenId, listedNFT.seller);

        _updatePool(_lpAddress);
        uint256 pending;
        if (user.rewardableNFTCount > 0) {
            pending = ((user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION) - user.rewardDebt;
            if (pending > 0) {
                emit Harvest(listedNFT.seller, _lpAddress, pending, false);
            }
        }

        user.rewardableNFTCount -= 1;
        users[_lpAddress][listedNFT.seller].rewardDebt = (user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION;
        users[_lpAddress][listedNFT.seller].rewardableNFTCount = user.rewardableNFTCount;

        pools[_lpAddress].totalRewardableNFTCount = pool.totalRewardableNFTCount - 1;
        listedNFTs[_lpAddress][_tokenId].isRewardable = false;
        if (pending > 0) {
            _safeTransfer(_lpAddress, listedNFT.seller, pending);
        }
    }

    /**
    * @notice withdraws a listed NFT from the specified liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function _withdrawNFT(address _lpAddress, uint256 _tokenId) internal {
        Order memory listedNFT = listedNFTs[_lpAddress][_tokenId];

        UserInfo memory user = users[_lpAddress][listedNFT.seller];
        _updatePool(_lpAddress);
        uint256 pending;
        if (user.rewardableNFTCount > 0) {
            pending = ((user.rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION) - user.rewardDebt;
            if (pending > 0) {
                emit Harvest(listedNFT.seller, _lpAddress, pending, false);
            }
        }

        _dropNode(_lpAddress, _tokenId);
        emit Withdraw(listedNFT.seller, _lpAddress, _tokenId);

        if (listedNFT.isRewardable) {
            users[_lpAddress][listedNFT.seller].rewardableNFTCount = user.rewardableNFTCount - 1;
            pools[_lpAddress].totalRewardableNFTCount -= 1;
        }
        users[_lpAddress][listedNFT.seller].rewardDebt = (users[_lpAddress][listedNFT.seller].rewardableNFTCount * pools[_lpAddress].accARTPerShare) / ACC_TOKEN_PRECISION;

        _resetListedNFT(_lpAddress, _tokenId, listedNFT.shareholderSize);

        IERC721Upgradeable(_lpAddress).safeTransferFrom(address(this), listedNFT.seller, _tokenId);

        if (pending > 0) {
            _safeTransfer(_lpAddress, listedNFT.seller, pending);
        }
    }

    /**
    * @notice Add a new node to the linked list of nodes that represent the prices of NFTs in a specific liquidity pool.
    * _freeIndex and _previousIndex help to keep track of the node position in the doubly linked list, for example, to know which node is the next or previous one, or to know the order of the nodes.
    * The floor price is used to prevent the listing of NFTs at excessively high prices.
    * The floor price is determined by taking the price of the node at a specific index in the doubly linked list
    * If the provided price is higher it throws an error message, preventing the user from listing an NFT at an excessively high price.
    * @param _lpAddress the address of the liquidity pool.
    * @param _tokenId the token ID of the NFT.
    * @param _price the price of the NFT.
    * @param _freeIndex is checked to make sure it is pointing to a valid location in the list and that there are no reusable nodes available.
    * @param _previousIndex the index of the node that the new node should come before in the list.
    */
    function _addNode(address _lpAddress, uint256 _tokenId, uint256 _price, uint64 _freeIndex, uint64 _previousIndex) internal {
        PoolInfo memory pool = pools[_lpAddress];
        bool doesFreeIndexPointReusableNode = _freeIndex < nodes[_lpAddress].length && !nodes[_lpAddress][_freeIndex].isActive;
        bool isReusableNodeExisting = (nodes[_lpAddress].length - pool.activeNodeCount) > 0;

        if (!doesFreeIndexPointReusableNode) {
            // _freeIndex must point last index of nodes as a new node
            require(_freeIndex == nodes[_lpAddress].length, "freeIndex is out of range");
            require(!isReusableNodeExisting, "Reusable node available, please use the existing node.");
        }

        /*
            If the activeNodeCount value is 0, the node will definitely be added to the beginning of the linked list and added as the node that determines the floor price.
            It will be added as the first node in the list and used as a reference point for the floor price, unless a previously used node is available to be reused in the list.
        */
        if (pool.activeNodeCount == 0) {
            _registerNewNode(
                doesFreeIndexPointReusableNode,
                _lpAddress,
                _tokenId,
                _price,
                _freeIndex,
                _freeIndex,
                _freeIndex
            );
            pools[_lpAddress].floorPriceNodeIndex = _freeIndex;
        } else {
            /*
                When _previousIndex is equal to _freeIndex, it means that the new node is being added to the head of the list and its price must be lower than the next node's price.
                The new node is added as the head of the list and its next index is set to the current head of the list
                If the `_previousIndex` is not the same as the `freeIndex` it means that the new node is being added somewhere in between other nodes, and the previous and next nodes' indices are updated to include the new node.
                The new node is added either as a reusable node or as a new node in the list.
            */
            if (_previousIndex == _freeIndex) {
                Node memory nextNode = nodes[_lpAddress][pool.floorPriceNodeIndex];
                require(nextNode.price > _price, "price must be lower than next node price");
                uint64 nextIndex = pool.floorPriceNodeIndex;
                _registerNewNode(
                    doesFreeIndexPointReusableNode,
                    _lpAddress,
                    _tokenId,
                    _price,
                    _freeIndex,
                    _freeIndex,
                    nextIndex
                );
                nextNode.previousIndex = _freeIndex;
                nodes[_lpAddress][pool.floorPriceNodeIndex] = nextNode;
                pools[_lpAddress].floorPriceNodeIndex = _freeIndex;
            } else {
                Node memory previousNode = nodes[_lpAddress][_previousIndex];
                require(previousNode.isActive, "previous node is must be active");
                require(previousNode.price <= _price, "price must be higher than previous node price");
                uint64 nextIndex = _freeIndex;
                if (previousNode.nextIndex != _previousIndex) {
                    Node memory nextNode = nodes[_lpAddress][previousNode.nextIndex];
                    require(previousNode.price <= _price && _price <= nextNode.price, "price must be higher than previous node and must be lower than next node");
                    nextNode.previousIndex = _freeIndex;
                    nodes[_lpAddress][previousNode.nextIndex] = nextNode;
                    nextIndex = previousNode.nextIndex;
                }
                previousNode.nextIndex = _freeIndex;
                nodes[_lpAddress][_previousIndex] = previousNode;

                _registerNewNode(
                    doesFreeIndexPointReusableNode,
                    _lpAddress,
                    _tokenId,
                    _price,
                    _freeIndex,
                    _previousIndex,
                    nextIndex
                );
            }
        }
        pools[_lpAddress].activeNodeCount = pool.activeNodeCount + 1;
    }


    /**
    * @notice Registers a new node in the linked list for the specified liquidity pool.
    * If a free node already exists, it will reuse it and update its information,
    * otherwise a new node will be created and added to the end of the linked list.
    * @param _doesFreeIndexPointReusableNode A boolean indicating whether there is a free node that can be reused.
    * @param _lpAddress The address of the liquidity pool.
    * @param _tokenId the token ID of the NFT.
    * @param _price The price of the NFT.
    * @param _freeIndex The index of the free node to be reused (if exists).
    * @param _previousIndex The index of the previous node in the linked list.
    * @param _nextIndex The index of the next node in the linked list.
    */
    function _registerNewNode(
        bool _doesFreeIndexPointReusableNode,
        address _lpAddress,
        uint256 _tokenId,
        uint256 _price,
        uint64 _freeIndex,
        uint64 _previousIndex,
        uint64 _nextIndex
    ) internal {
        Node memory newNode = Node({
        price: _price,
        previousIndex: _previousIndex,
        nextIndex: _nextIndex,
        tokenId: _tokenId,
        isActive: true
        });
        if (_doesFreeIndexPointReusableNode) {
            nodes[_lpAddress][_freeIndex] = newNode;
        } else {
            nodes[_lpAddress].push(newNode);
        }
    }

    /**
    * @notice Responsible for removing a specific node from the linked list of nodes in the specified liquidity pool.
    * It updates the previous, next, and current node references in the linked list.
    * If the node is also the floor price node, the next node in the list will be set as the new floor price node.
    * @param _lpAddress the address of the liquidity pool.
    * @param _tokenId the token ID of the NFT.
    */
    function _dropNode(address _lpAddress, uint256 _tokenId) internal {
        uint64 nodeIndex = listedNFTs[_lpAddress][_tokenId].nodeIndex;

        Node memory currentNode = nodes[_lpAddress][nodeIndex];
        Node storage previousNode = nodes[_lpAddress][currentNode.previousIndex];
        Node storage nextNode = nodes[_lpAddress][currentNode.nextIndex];

        if (nodeIndex == currentNode.previousIndex) {
            nextNode.previousIndex = currentNode.nextIndex;
            pools[_lpAddress].floorPriceNodeIndex = currentNode.nextIndex;
        } else if (nodeIndex == currentNode.nextIndex) {
            previousNode.nextIndex = currentNode.previousIndex;
        } else {
            previousNode.nextIndex = currentNode.nextIndex;
            nextNode.previousIndex = currentNode.previousIndex;
        }

        delete nodes[_lpAddress][nodeIndex];
        pools[_lpAddress].activeNodeCount -= 1;
    }

    /**
    * @notice Updates the accARTPerShare and lastRewardTimestamp value, which is used to calculate the rewards users will earn when they harvest in the future.
    * @param _lpAddress The address of the pool. See `poolInfo`.
    */
    function _updatePool(address _lpAddress) internal {
        PoolInfo memory pool = pools[_lpAddress];
        if (block.timestamp > pool.lastRewardTimestamp) {
            if (pool.totalRewardableNFTCount > 0) {
                uint256 secondsElapsed = block.timestamp - pool.lastRewardTimestamp;
                uint256 artReward = secondsElapsed * pool.rewardGenerationRate;
                pools[_lpAddress].accARTPerShare = pool.accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / pool.totalRewardableNFTCount);
            }
            pools[_lpAddress].lastRewardTimestamp = block.timestamp;
            emit UpdatePool(_lpAddress, pool.lastRewardTimestamp, pool.totalRewardableNFTCount, pool.accARTPerShare);
        }
    }

    /**
    * @notice retrieves the shareholders of a specific NFT in a specific liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function _getShareholders(address _lpAddress, uint256 _tokenId) internal view returns (LibShareholder.Shareholder[] memory) {
        uint256 shareholderSize = listedNFTs[_lpAddress][_tokenId].shareholderSize;
        LibShareholder.Shareholder[] memory _shareholders = new LibShareholder.Shareholder[](shareholderSize);
        for (uint8 i; i < shareholderSize; i++) {
            _shareholders[i] = shareholders[_lpAddress][_tokenId][i];
        }
        return _shareholders;
    }

    /**
    * @notice set the shareholders for a specific NFT token in a specific liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    * @param _shareholders an array of Shareholder structs representing the shareholders of the token
    */
    function _setShareholders(address _lpAddress, uint256 _tokenId, LibShareholder.Shareholder[] memory _shareholders) internal {
        uint256 shareholderSize = _shareholders.length;
        // makes sure shareholders does not exceed the limits defined in PaymentManager contract
        require(
            shareholderSize <= IPaymentManager(paymentManager).getMaximumShareholdersLimit(),
            "reached maximum shareholder count"
        );

        uint8 j;
        for (uint8 i; i < shareholderSize; i++) {
            if (_shareholders[i].account != address(0) && _shareholders[i].value > 0) {
                shareholders[_lpAddress][_tokenId][j] = _shareholders[i];
                j += 1;
            }
        }
        listedNFTs[_lpAddress][_tokenId].shareholderSize = j;
    }

    /**
    * @notice resets the information of a previously listed NFT on a specific liquidity pool.
    * @param _lpAddress liquidity pool address
    * @param _tokenId NFT's tokenId
    */
    function _resetListedNFT(address _lpAddress, uint256 _tokenId, uint8 _shareholderSize) internal {
        for (uint8 i; i < _shareholderSize; i++) {
            delete shareholders[_lpAddress][_tokenId][i];
        }
        delete listedNFTs[_lpAddress][_tokenId];
    }

    /**
    * @notice Transfers a specified amount of ART tokens from the contract to a user.
    * @dev If the specified amount is greater than the contract's ART balance,
    * the remaining balance will be stored as failedBalance for the user, to be sent in future transactions.
    * @param _lpAddress The address of the liquidity pool.
    * @param _receiver The address of the recipient of the ART tokens.
    * @param _amount The amount of ART tokens to be transferred.
    */
    function _safeTransfer(address _lpAddress, address _receiver, uint256 _amount) internal {
        uint256 _totalBalance = art.balanceOf(address(this));
        _amount += users[_lpAddress][_receiver].failedBalance;
        if (_amount > _totalBalance) {
            users[_lpAddress][_receiver].failedBalance = _amount - _totalBalance;
            if (_totalBalance > 0) {
                art.safeTransfer(_receiver, _totalBalance);
            }
        } else {
            users[_lpAddress][_receiver].failedBalance = 0;
            art.safeTransfer(_receiver, _amount);
        }
    }
}