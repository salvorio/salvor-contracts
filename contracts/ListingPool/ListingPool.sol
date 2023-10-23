//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../PaymentManager/IPaymentManager.sol";
import "../libs/LibShareholder.sol";

/**
* @title ArtMarketplace
* @notice the users can simply list and lock their NFTs for a specific period and earn rewards if it does not sell.
*/
contract ListingPool is OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC721HolderUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Node {
        // variable holds the listing price of the NFT
        uint64 step;
        // holds the index of the previous node in the linked list.
        uint64 previousIndex;
        // holds the index of the next node in the linked list.
        uint64 nextIndex;
        // set to true when the NFT is deposited, otherwise it will be false, it determines that NFT is available to buy or not.
        bool isActive;
    }

    struct NftOwner {
        address owner;
        uint256 startedAt;
    }

    struct Order {
        uint64 currentStep;
        uint256 rewardDebt;
        // holds the listing price of the NFT
        uint256 amount;
        // holds the duration for which NFTs will be locked.
        uint256 lockDuration;
        uint256 startedAt;
    }

    struct PoolInfo {
        // represents the rate at which rewards are generated for the pool.
        uint256 rewardRate;
        uint256 rewardSecondRate;
        uint256 rewardThirdRate;
        // holds the duration for which NFTs will be locked.
        uint256 lockDuration;
        // holds the percentage of commission taken from every sale.
        uint96 commissionPercentage;
        // holds the index of the node responsible for restricting the floor price.
        uint64 highestNodeIndex;
        uint64 floorNodeIndex;
        uint256 stepPrice;
        uint256 stepMod;
        // holds the index of the node responsible for updating the floor price of NFTs when the number of deposited nodes exceeds the specified number in "floorPriceThresholdNodeCount".
        // This information is used to determine the current floor price of NFTs.
        uint256 activeNodeCount;
        bool isActive;
    }

    struct ListingInfo {
        uint64 nodeIndex;
        // represents the total amount of art accumulated per share.
        uint256 accARTPerShare;
        // holds the timestamp of the last reward that was generated for the pool.
        uint256 lastRewardTimestamp;
        // holds the total number of NFTs that are eligible for rewards in the pool.
        uint256 totalListingCount;
    }

    /// @notice Address of ART contract.
    IERC20Upgradeable public art;

    /**
	* @notice manages payouts for each contract.
    */
    address public paymentManager;

    // mapping of address to PoolInfo structure to store information of all liquidity pools.
    mapping(address => mapping(uint32 => PoolInfo)) public pools;

    mapping(address => mapping(uint32 => mapping(uint64 => ListingInfo))) public listingPools;

    // an array of Node structs, which holds information about each node in the pool.
    mapping(address => mapping(uint32 => Node[])) public nodes;

    mapping(address => mapping(uint256 => NftOwner)) public nftOwners;

    // the NFTs listed for trade in a specific pool.
    mapping(address => mapping(uint32 => mapping(address => Order))) public orders;

    mapping(address => mapping(uint256 => uint32)) public rarities;

    // This factor is present to reduce loss from division operations.
    uint256 private constant ACC_TOKEN_PRECISION = 1e18;

    address public admin;

    event BuyNFT(address indexed lpAddress, uint32 indexed rarity, address bidder, address indexed seller, uint256 tokenId, uint64 step, uint256 price);
    event ListNFT(address indexed lpAddress, uint32 indexed rarity, address indexed seller, uint256 tokenId, uint64 step, uint256 price);
    event UpdateStep(address indexed lpAddress, uint32 indexed rarity, address indexed seller, uint64 step, uint256 price);
    event WithdrawNFT(address indexed lpAddress, uint256 indexed tokenId, address indexed seller, uint32 rarity, uint64 step);
    event Harvest(address indexed user, address indexed lpAddress, uint32 indexed rarity, uint64 step, uint256 amount, bool isStandalone);
    event UpdatePool(address indexed lpAddress, uint256 indexed price, uint256 lastRewardTimestamp, uint256 lpSupply, uint256 accARTPerShare);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Upgradeable _art, address _paymentManager)
    public
    initializer {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
        __Pausable_init_unchained();
        art = _art;
        paymentManager = _paymentManager;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
    }

    function listNodes(address _lpAddress, uint32 _rarity) external view returns (Node[] memory) {
        return nodes[_lpAddress][_rarity];
    }

    function setRarities(address _lpAddress, uint256[] calldata _tokenIds, uint32 _rarity) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        uint256 _len = _tokenIds.length;
        for(uint256 i; i < _len; i++) {
            rarities[_lpAddress][_tokenIds[i]] = _rarity;
        }
    }

    function pendingRewards(address _lpAddress, uint32 _rarity, address _user) external view returns (uint256) {
        Order memory order = orders[_lpAddress][_rarity][_user];
        ListingInfo memory listingPool = listingPools[_lpAddress][_rarity][order.currentStep];
        uint256 accARTPerShare = listingPool.accARTPerShare;

        if (block.timestamp > listingPool.lastRewardTimestamp && listingPool.totalListingCount > 0) {
            uint256 secondsElapsed = block.timestamp - listingPool.lastRewardTimestamp;
            uint256 artReward = secondsElapsed * _getRewardRate(_lpAddress, _rarity, listingPool.nodeIndex);
            accARTPerShare = accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / listingPool.totalListingCount);
        }
        return ((order.amount * accARTPerShare) / ACC_TOKEN_PRECISION) - order.rewardDebt;
    }

    function harvestPendings(address _lpAddress, uint32 _rarity) external {
        Order memory order = orders[_lpAddress][_rarity][msg.sender];
        _updatePool(_lpAddress, _rarity, order.currentStep);
        ListingInfo memory listingPool = listingPools[_lpAddress][_rarity][order.currentStep];
        _harvestPending(_lpAddress, _rarity, msg.sender, true);
        orders[_lpAddress][_rarity][msg.sender].rewardDebt = (order.amount * listingPool.accARTPerShare) / ACC_TOKEN_PRECISION;
    }

    function addPool(
        address _lpAddress,
        uint32 _rarity,
        uint256 _rewardRate,
        uint256 _rewardSecondRate,
        uint256 _rewardThirdRate,
        uint256 _stepMod,
        uint256 _lockDuration,
        uint96 _commissionPercentage
    ) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        require(_rewardRate < 772000000000000000, "generation rate is reached");

        require(!pools[_lpAddress][_rarity].isActive, "LP already added");
        require(_commissionPercentage < 2000, "cannot be higher than 20%");

        pools[_lpAddress][_rarity] = PoolInfo({
            rewardRate: _rewardRate,
            rewardSecondRate: _rewardSecondRate,
            rewardThirdRate: _rewardThirdRate,
            lockDuration: _lockDuration,
            stepPrice: 10000000000000000,
            stepMod: _stepMod,
            commissionPercentage: _commissionPercentage,
            highestNodeIndex: 0,
            floorNodeIndex: 0,
            activeNodeCount: 0,
            isActive: true
        });
    }

    function updatePoolInfo(
        address _lpAddress,
        uint32 _rarity,
        bool _isActive,
        uint256 _rewardRate,
        uint256 _rewardSecondRate,
        uint256 _rewardThirdRate,
        uint256 _lockDuration,
        uint96 _commissionPercentage,
        uint256 _stepMod
    ) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        require(_rewardRate < 772000000000000000, "generation rate is reached");
        require(_commissionPercentage < 2000, "cannot be higher than 20%");
        PoolInfo storage pool = pools[_lpAddress][_rarity];

        _updateTopPools(_lpAddress, _rarity);

        pool.rewardRate = _rewardRate;
        pool.rewardSecondRate = _rewardSecondRate;
        pool.rewardThirdRate = _rewardThirdRate;
        pool.lockDuration = _lockDuration;
        pool.commissionPercentage = _commissionPercentage;
        pool.isActive = _isActive;
        pool.stepMod = _stepMod;
    }

    function listNFTs(address _lpAddress, uint32 _rarity, uint256[] calldata _tokenIds, uint64 _step, uint64 _freeIndex, uint64 _previousIndex) external whenNotPaused nonReentrant {
        uint256 _amount = _tokenIds.length;
        require(_step > 0, "step must be greater than zero");
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        require(pool.isActive, "lp does not exist");
        Order memory order = orders[_lpAddress][_rarity][msg.sender];
        require(_step % pool.stepMod == 0, "stepMod does not match");

        bool isUpdate = false;
        if (order.currentStep == 0) {
            require(_amount > 0, "at least 1 tokenId must be listed");
        } else {
            if (_amount == 0) {
                require(order.currentStep != _step, "have already submitted an order");
                if (_step > order.currentStep) {
                    require((block.timestamp - order.startedAt) > order.lockDuration, "lock duration not reached");
                }
                isUpdate = true;
                emit UpdateStep(_lpAddress, _rarity, msg.sender, _step, _step * pool.stepPrice);
            } else {
                require(order.currentStep == _step, "must be in same step");
            }
        }

        for (uint256 i; i<_amount; i++) {
            require(msg.sender == IERC721Upgradeable(_lpAddress).ownerOf(_tokenIds[i]), "NFT does not belong to the sender");
            require(_rarity == rarities[_lpAddress][_tokenIds[i]], "Rarity does not match");

            emit ListNFT(_lpAddress, _rarity, msg.sender, _tokenIds[i], _step, _step * pool.stepPrice);
            IERC721Upgradeable(_lpAddress).safeTransferFrom(msg.sender, address(this), _tokenIds[i]);
            nftOwners[_lpAddress][_tokenIds[i]].owner = msg.sender;
            nftOwners[_lpAddress][_tokenIds[i]].startedAt = block.timestamp;
        }

        _updateTopPools(_lpAddress, _rarity);
        _updatePool(_lpAddress, _rarity, _step);
        if (order.currentStep > 0) {
            _harvestPending(_lpAddress, _rarity, msg.sender, false);
            if (order.currentStep != _step) {
                listingPools[_lpAddress][_rarity][order.currentStep].totalListingCount -= order.amount;
                if (listingPools[_lpAddress][_rarity][order.currentStep].totalListingCount == 0) {
                    if (pool.activeNodeCount > 3) {
                        _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
                    }
                    _freeIndex = listingPools[_lpAddress][_rarity][order.currentStep].nodeIndex;
                    _dropNode(_lpAddress, _rarity, _freeIndex);
                }
            }
        }

        // new step node is created
        if (listingPools[_lpAddress][_rarity][_step].totalListingCount == 0) {
            _addNode(_lpAddress, _rarity, _step, _freeIndex, _previousIndex);
        }

        if (isUpdate) {
            listingPools[_lpAddress][_rarity][_step].totalListingCount += order.amount;
        } else {
            listingPools[_lpAddress][_rarity][_step].totalListingCount += _amount;
            orders[_lpAddress][_rarity][msg.sender].amount += _amount;
        }

        orders[_lpAddress][_rarity][msg.sender].currentStep = _step;
        orders[_lpAddress][_rarity][msg.sender].lockDuration = pool.lockDuration;
        orders[_lpAddress][_rarity][msg.sender].startedAt = block.timestamp;
        orders[_lpAddress][_rarity][msg.sender].rewardDebt = (orders[_lpAddress][_rarity][msg.sender].amount * listingPools[_lpAddress][_rarity][_step].accARTPerShare) / ACC_TOKEN_PRECISION;
    }

    function withdrawNFTs(address _lpAddress, uint32 _rarity, uint256[] calldata _tokenIds) external whenNotPaused nonReentrant {
        uint256 _amount = _tokenIds.length;
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        Order memory order = orders[_lpAddress][_rarity][msg.sender];
        uint64 step = order.currentStep;
        require(step > 0, "There is no order");

        for (uint256 i; i<_amount; i++) {
            require(msg.sender == nftOwners[_lpAddress][_tokenIds[i]].owner, "NFT does not belong to the sender");
            require(_rarity == rarities[_lpAddress][_tokenIds[i]], "Rarity does not match");
            if (nftOwners[_lpAddress][_tokenIds[i]].startedAt > 0) {
                require((block.timestamp - nftOwners[_lpAddress][_tokenIds[i]].startedAt) > order.lockDuration, "lock duration not reached");
            }
            emit WithdrawNFT(_lpAddress, _tokenIds[i], msg.sender, _rarity, step);
            IERC721Upgradeable(_lpAddress).safeTransferFrom(address(this), msg.sender, _tokenIds[i]);
            delete nftOwners[_lpAddress][_tokenIds[i]];
        }

        _updateTopPools(_lpAddress, _rarity);
        _harvestPending(_lpAddress, _rarity, msg.sender, false);

        if (listingPools[_lpAddress][_rarity][step].totalListingCount == _amount) {
            listingPools[_lpAddress][_rarity][step].totalListingCount = 0;
            // if the dropped node is rewardable then update next rewardable node if exists
            if (pool.activeNodeCount > 3) {
                _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
            }
            _dropNode(_lpAddress, _rarity, listingPools[_lpAddress][_rarity][step].nodeIndex);
        } else {
            listingPools[_lpAddress][_rarity][step].totalListingCount -= _amount;
        }

        if (_amount == order.amount) {
            delete orders[_lpAddress][_rarity][msg.sender];
        } else {
            orders[_lpAddress][_rarity][msg.sender].amount -= _amount;
            orders[_lpAddress][_rarity][msg.sender].rewardDebt = (orders[_lpAddress][_rarity][msg.sender].amount * listingPools[_lpAddress][_rarity][step].accARTPerShare) / ACC_TOKEN_PRECISION;
        }
    }

    function buyNFTs(address[] calldata _lpAddresses, uint256[] calldata _tokenIds) external payable whenNotPaused nonReentrant {
        uint256 _len = _tokenIds.length;
        uint256 total;
        for (uint256 i = 0; i < _len; i++) {
            require(msg.sender != nftOwners[_lpAddresses[i]][_tokenIds[i]].owner, "cannot accept your own order");
            require(nftOwners[_lpAddresses[i]][_tokenIds[i]].startedAt > 0, "nft is not listed");
            uint32 rarity = rarities[_lpAddresses[i]][_tokenIds[i]];
            total += (orders[_lpAddresses[i]][rarity][nftOwners[_lpAddresses[i]][_tokenIds[i]].owner].currentStep * pools[_lpAddresses[i]][rarity].stepPrice);
        }
        require(msg.value >= total, "insufficient payment");

        for (uint256 i = 0; i < _len; i++) {
            buyNFT(_lpAddresses[i], _tokenIds[i]);
        }
    }

    function buyNFT(address _lpAddress, uint256 _tokenId) internal {
        uint32 _rarity = rarities[_lpAddress][_tokenId];
        address _owner = nftOwners[_lpAddress][_tokenId].owner;
        Order memory order = orders[_lpAddress][_rarity][_owner];
        PoolInfo memory pool = pools[_lpAddress][_rarity];

        require(order.amount > 0, "There is no order");

        _updateTopPools(_lpAddress, _rarity);

        _harvestPending(_lpAddress, _rarity, _owner, false);
        if (orders[_lpAddress][_rarity][_owner].amount == 1) {
            delete orders[_lpAddress][_rarity][_owner];
        } else {
            orders[_lpAddress][_rarity][_owner].amount -= 1;
            orders[_lpAddress][_rarity][_owner].rewardDebt = (orders[_lpAddress][_rarity][_owner].amount * listingPools[_lpAddress][_rarity][order.currentStep].accARTPerShare) / ACC_TOKEN_PRECISION;
        }

        listingPools[_lpAddress][_rarity][order.currentStep].totalListingCount -= 1;

        if (listingPools[_lpAddress][_rarity][order.currentStep].totalListingCount == 0) {
            if (pool.activeNodeCount > 3) {
                _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
            }
            _dropNode(_lpAddress, _rarity, listingPools[_lpAddress][_rarity][order.currentStep].nodeIndex);
        }
        delete nftOwners[_lpAddress][_tokenId];
        uint256 price = order.currentStep * pool.stepPrice;
        emit BuyNFT(_lpAddress, _rarity, msg.sender, _owner, _tokenId, order.currentStep, price);
        IERC721Upgradeable(_lpAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        LibShareholder.Shareholder[] memory _shareholders;
        IPaymentManager(paymentManager).payout{ value: price }(
            payable(_owner),
            _lpAddress,
            _tokenId,
            _shareholders,
            pool.commissionPercentage
        );
    }

    function _updateTopPools(address _lpAddress, uint32 _rarity) internal {
        PoolInfo memory pool = pools[_lpAddress][_rarity];

        Node memory floorNode;
        Node memory secondNode;
        if (pool.activeNodeCount > 0) {
            floorNode = nodes[_lpAddress][_rarity][pool.floorNodeIndex];
            _updatePool(_lpAddress, _rarity, floorNode.step);
        }
        if (pool.activeNodeCount > 1) {
            secondNode = nodes[_lpAddress][_rarity][floorNode.nextIndex];
            _updatePool(_lpAddress, _rarity, secondNode.step);
        }
        if (pool.activeNodeCount > 2) {
            _updatePool(_lpAddress, _rarity, nodes[_lpAddress][_rarity][secondNode.nextIndex].step);
        }
    }

    function _updatePool(address _lpAddress, uint32 _rarity, uint64 _step) internal {
        ListingInfo memory listingPool = listingPools[_lpAddress][_rarity][_step];
        uint256 rewardRate = _getRewardRate(_lpAddress, _rarity, listingPool.nodeIndex);

        if (block.timestamp > listingPool.lastRewardTimestamp) {
            if (listingPool.totalListingCount > 0) {
                uint256 secondsElapsed = block.timestamp - listingPool.lastRewardTimestamp;
                uint256 artReward = secondsElapsed * rewardRate;
                listingPools[_lpAddress][_rarity][_step].accARTPerShare = listingPool.accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / listingPool.totalListingCount);
            }
            listingPools[_lpAddress][_rarity][_step].lastRewardTimestamp = block.timestamp;
            emit UpdatePool(_lpAddress, _step, listingPool.lastRewardTimestamp, listingPool.totalListingCount, listingPool.accARTPerShare);
        }
    }

    function _getRewardRate(address _lpAddress, uint32 _rarity, uint64 _nodeIndex) internal view returns(uint256) {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        uint64 floorNodeIndex = pool.floorNodeIndex;
        if (pool.activeNodeCount == 0) {
            return 0;
        }
        Node memory floorNode = nodes[_lpAddress][_rarity][floorNodeIndex];
        Node memory secondNode = nodes[_lpAddress][_rarity][floorNode.nextIndex];

        if (floorNodeIndex == _nodeIndex) {
            return pool.rewardRate;
        } else if (floorNode.nextIndex == _nodeIndex) {
            return pool.rewardSecondRate;
        } else if (secondNode.nextIndex == _nodeIndex) {
            return pool.rewardThirdRate;
        } else {
            return 0;
        }
    }

    function _getNextRewardableStep(address _lpAddress, uint32 _rarity) internal view returns(uint64) {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        uint64 floorNodeIndex = pool.floorNodeIndex;
        Node memory floorNode = nodes[_lpAddress][_rarity][floorNodeIndex];
        Node memory secondNode = nodes[_lpAddress][_rarity][floorNode.nextIndex];
        Node memory thirdNode = nodes[_lpAddress][_rarity][secondNode.nextIndex];

        return nodes[_lpAddress][_rarity][thirdNode.nextIndex].step;
    }

    function _harvestPending(address _lpAddress, uint32 _rarity, address _user, bool _isStandAlone) internal {
        Order memory order = orders[_lpAddress][_rarity][_user];
        uint256 pending = ((order.amount * listingPools[_lpAddress][_rarity][order.currentStep].accARTPerShare) / ACC_TOKEN_PRECISION);
        pending -= order.rewardDebt;
        if (pending > 0) {
            emit Harvest(_user, _lpAddress, _rarity, order.currentStep, pending, _isStandAlone);
            _safeTransfer(_user, pending);
        }
    }

    function _addNode(address _lpAddress, uint32 _rarity, uint64 _step, uint64 _freeIndex, uint64 _previousIndex) internal {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        bool doesFreeIndexPointReusableNode = _freeIndex < nodes[_lpAddress][_rarity].length && !nodes[_lpAddress][_rarity][_freeIndex].isActive;
        bool isReusableNodeExisting = (nodes[_lpAddress][_rarity].length - pool.activeNodeCount) > 0;

        if (!doesFreeIndexPointReusableNode) {
            // _freeIndex must point last index of nodes as a new node
            require(_freeIndex == nodes[_lpAddress][_rarity].length, "freeIndex is out of range");
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
                _rarity,
                _step,
                _freeIndex,
                _freeIndex,
                _freeIndex
            );
            pools[_lpAddress][_rarity].highestNodeIndex = _freeIndex;
            pools[_lpAddress][_rarity].floorNodeIndex = _freeIndex;
        } else {
            if (_previousIndex == _freeIndex) {
                Node memory nextNode = nodes[_lpAddress][_rarity][pool.floorNodeIndex];
                require(nextNode.step > _step, "price must be lower than next node price");
                uint64 nextIndex = pool.floorNodeIndex;
                _registerNewNode(
                    doesFreeIndexPointReusableNode,
                    _lpAddress,
                    _rarity,
                    _step,
                    _freeIndex,
                    _freeIndex,
                    nextIndex
                );
                nextNode.previousIndex = _freeIndex;
                nodes[_lpAddress][_rarity][pool.floorNodeIndex] = nextNode;
                pools[_lpAddress][_rarity].floorNodeIndex = _freeIndex;
            } else {
                Node memory previousNode = nodes[_lpAddress][_rarity][_previousIndex];
                require(previousNode.isActive, "previous node is must be active");
                require(previousNode.step < _step, "price must be higher than previous node price");
                uint64 nextIndex = _freeIndex;
                if (previousNode.nextIndex != _previousIndex) {
                    Node memory nextNode = nodes[_lpAddress][_rarity][previousNode.nextIndex];
                    require(previousNode.step < _step && _step < nextNode.step, "price must be higher than previous node and must be lower than next node");
                    nextNode.previousIndex = _freeIndex;
                    nodes[_lpAddress][_rarity][previousNode.nextIndex] = nextNode;
                    nextIndex = previousNode.nextIndex;
                } else {
                    require(pools[_lpAddress][_rarity].highestNodeIndex == previousNode.nextIndex, "must be top index");
                    pools[_lpAddress][_rarity].highestNodeIndex = _freeIndex;
                }
                previousNode.nextIndex = _freeIndex;
                nodes[_lpAddress][_rarity][_previousIndex] = previousNode;

                _registerNewNode(
                    doesFreeIndexPointReusableNode,
                    _lpAddress,
                    _rarity,
                    _step,
                    _freeIndex,
                    _previousIndex,
                    nextIndex
                );
            }
        }
        pools[_lpAddress][_rarity].activeNodeCount = pool.activeNodeCount + 1;
        listingPools[_lpAddress][_rarity][_step].nodeIndex = _freeIndex;
    }

    function _registerNewNode(
        bool _doesFreeIndexPointReusableNode,
        address _lpAddress,
        uint32 _rarity,
        uint64 _step,
        uint64 _freeIndex,
        uint64 _previousIndex,
        uint64 _nextIndex
    ) internal {
        Node memory newNode = Node({
            step: _step,
            previousIndex: _previousIndex,
            nextIndex: _nextIndex,
            isActive: true
        });
        if (_doesFreeIndexPointReusableNode) {
            nodes[_lpAddress][_rarity][_freeIndex] = newNode;
        } else {
            nodes[_lpAddress][_rarity].push(newNode);
        }
    }

    function _dropNode(address _lpAddress, uint32 _rarity, uint64 _nodeIndex) internal {
        Node memory currentNode = nodes[_lpAddress][_rarity][_nodeIndex];
        Node storage previousNode = nodes[_lpAddress][_rarity][currentNode.previousIndex];
        Node storage nextNode = nodes[_lpAddress][_rarity][currentNode.nextIndex];

        if (pools[_lpAddress][_rarity].activeNodeCount == 1) {
            pools[_lpAddress][_rarity].highestNodeIndex = 0;
            pools[_lpAddress][_rarity].floorNodeIndex = 0;
        } else {
            if (_nodeIndex == currentNode.previousIndex) {
                nextNode.previousIndex = currentNode.nextIndex;
                pools[_lpAddress][_rarity].floorNodeIndex = currentNode.nextIndex;
            } else if (_nodeIndex == currentNode.nextIndex) {
                previousNode.nextIndex = currentNode.previousIndex;
                pools[_lpAddress][_rarity].highestNodeIndex = currentNode.previousIndex;
            } else {
                previousNode.nextIndex = currentNode.nextIndex;
                nextNode.previousIndex = currentNode.previousIndex;
            }
        }

        delete nodes[_lpAddress][_rarity][_nodeIndex];
        pools[_lpAddress][_rarity].activeNodeCount -= 1;
    }

    function _safeTransfer(address _receiver, uint256 _amount) internal {
        uint256 _totalBalance = art.balanceOf(address(this));
        require(_totalBalance >= _amount, "insufficient balance");
        art.safeTransfer(_receiver, _amount);
    }
}



