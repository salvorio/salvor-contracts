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
contract OfferPool is OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC721HolderUpgradeable, PausableUpgradeable {
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

    struct BiddingNode {
        address owner;
        // set to true when the NFT is deposited, otherwise it will be false, it determines that NFT is available to buy or not.
        bool isActive;
    }

    struct Offer {
        uint64 currentStep;
        uint64 biddingNodeIndex;
        // holds the timestamp indicating when the NFT was listed.
        uint256 startedAt;
        uint256 rewardDebt;
        // holds the listing price of the NFT
        uint256 amount;
        // holds the duration for which NFTs will be locked.
        uint256 lockDuration;
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

    struct PoolBiddingInfo {
        uint64 nodeIndex;
        // represents the total amount of art accumulated per share.
        uint256 accARTPerShare;
        // holds the timestamp of the last reward that was generated for the pool.
        uint256 lastRewardTimestamp;
        // holds the total number of NFTs that are eligible for rewards in the pool.
        uint256 totalOfferCount;
        uint256 totalBiddingNodeCount;
    }

    /// @notice Address of ART contract.
    IERC20Upgradeable public art;

    /**
	* @notice manages payouts for each contract.
    */
    address public paymentManager;

    // mapping of address to PoolInfo structure to store information of all liquidity pools.
    mapping(address => mapping(uint32 => PoolInfo)) public pools;

    mapping(address => mapping(uint32 => mapping(uint64 => PoolBiddingInfo))) public biddingPools;

    // an array of Node structs, which holds information about each node in the pool.
    mapping(address => mapping(uint32 => Node[])) public nodes;

    mapping(address => mapping(uint32 => mapping(uint64 => BiddingNode[]))) public biddingNodes;

    // the NFTs listed for trade in a specific pool.
    mapping(address => mapping(uint32 => mapping(address => Offer))) public offers;

    mapping(address => mapping(uint256 => uint32)) public rarities;

    // This factor is present to reduce loss from division operations.
    uint256 private constant ACC_TOKEN_PRECISION = 1e18;

    address public admin;

    event AcceptOffer(address indexed lpAddress, uint32 indexed rarity, address bidder, address indexed seller, uint256 tokenId, uint64 step, uint256 price);
    event MakeOffer(address indexed lpAddress, uint32 indexed rarity, address indexed bidder, uint256 amount, uint64 step, uint256 price);
    event UpdateOffer(address indexed lpAddress, uint32 indexed rarity, address indexed bidder, uint256 amount, uint64 step);
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

    function listBiddingNodes(address _lpAddress, uint32 _rarity, uint64 _step) external view returns (BiddingNode[] memory) {
        return biddingNodes[_lpAddress][_rarity][_step];
    }

    function setRarities(address _lpAddress, uint256[] calldata _tokenIds, uint32 _rarity) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        uint256 _len = _tokenIds.length;
        for(uint256 i; i < _len; i++) {
            rarities[_lpAddress][_tokenIds[i]] = _rarity;
        }
    }

    function pendingRewards(address _lpAddress, uint32 _rarity, address _user) external view returns (uint256) {
        Offer memory offer = offers[_lpAddress][_rarity][_user];
        PoolBiddingInfo memory biddingPool = biddingPools[_lpAddress][_rarity][offer.currentStep];
        uint256 accARTPerShare = biddingPool.accARTPerShare;

        if (block.timestamp > biddingPool.lastRewardTimestamp && biddingPool.totalOfferCount > 0) {
            uint256 secondsElapsed = block.timestamp - biddingPool.lastRewardTimestamp;
            uint256 artReward = secondsElapsed * _getRewardRate(_lpAddress, _rarity, biddingPool.nodeIndex);
            accARTPerShare = accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / biddingPool.totalOfferCount);
        }
        return ((offer.amount * accARTPerShare) / ACC_TOKEN_PRECISION) - offer.rewardDebt;
    }

    function harvestPendings(address _lpAddress, uint32 _rarity) external {
        Offer memory offer = offers[_lpAddress][_rarity][msg.sender];
        _updatePool(_lpAddress, _rarity, offer.currentStep);
        PoolBiddingInfo memory biddingPool = biddingPools[_lpAddress][_rarity][offer.currentStep];
        _harvestPending(_lpAddress, _rarity, msg.sender, true);
        offers[_lpAddress][_rarity][msg.sender].rewardDebt = (offer.amount * biddingPool.accARTPerShare) / ACC_TOKEN_PRECISION;
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
        require(pools[_lpAddress][_rarity].isActive, "lp does not exist");
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

    function makeOffer(address _lpAddress, uint32 _rarity, uint256 _amount, uint64 _step, uint64 _freeIndex, uint64 _previousIndex, uint64 _freeBiddingIndex) external payable whenNotPaused nonReentrant {
        require(_step > 0 && _amount > 0, "step must be greater than zero");
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        require(pool.isActive, "lp does not exist");
        require(_step % pool.stepMod == 0, "stepMod does not match");
        Offer memory offer = offers[_lpAddress][_rarity][msg.sender];
        require(offer.startedAt == 0 || offer.currentStep != _step, "have already submitted an offer");
        if (offer.currentStep > 0) {
            if (_getRewardRate(_lpAddress, _rarity, biddingPools[_lpAddress][_rarity][offer.currentStep].nodeIndex) > 0 && _step < offer.currentStep) {
                require((block.timestamp - offer.startedAt) > offer.lockDuration, "lock duration not reached");
            }
        }

        checkPayment(_lpAddress, _rarity, _amount, _step);

        _updateTopPools(_lpAddress, _rarity);
        _updatePool(_lpAddress, _rarity, _step);
        if (offer.currentStep > 0) {
            _harvestPending(_lpAddress, _rarity, msg.sender, false);
            biddingPools[_lpAddress][_rarity][offer.currentStep].totalOfferCount -= offer.amount;
            _dropBiddingNode(_lpAddress, _rarity, offer.currentStep, offer.biddingNodeIndex);
            _addBiddingNode(_lpAddress, _rarity, _step, _freeBiddingIndex);
        } else {
            _addBiddingNode(_lpAddress, _rarity, _step, _freeBiddingIndex);
        }
        biddingPools[_lpAddress][_rarity][_step].totalOfferCount += _amount;
        // previous step is empty
        if (offer.currentStep > 0 && biddingPools[_lpAddress][_rarity][offer.currentStep].totalOfferCount == 0) {
            if (pool.activeNodeCount > 3) {
                _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
            }
            _freeIndex = biddingPools[_lpAddress][_rarity][offer.currentStep].nodeIndex;
            _dropNode(_lpAddress, _rarity, _freeIndex);
        }
        // new step node is created
        if (biddingPools[_lpAddress][_rarity][_step].totalOfferCount == _amount) {
            _updatePool(_lpAddress, _rarity, _step);
            _addNode(_lpAddress, _rarity, _step, _freeIndex, _previousIndex);
        }

        offers[_lpAddress][_rarity][msg.sender].currentStep = _step;
        offers[_lpAddress][_rarity][msg.sender].amount = _amount;
        offers[_lpAddress][_rarity][msg.sender].startedAt = block.timestamp;
        offers[_lpAddress][_rarity][msg.sender].lockDuration = pool.lockDuration;
        offers[_lpAddress][_rarity][msg.sender].rewardDebt = (_amount * biddingPools[_lpAddress][_rarity][_step].accARTPerShare) / ACC_TOKEN_PRECISION;

        emit MakeOffer(_lpAddress, _rarity, msg.sender, _amount, _step, _step * pool.stepPrice);
    }

    function updateAmount(address _lpAddress, uint32 _rarity, uint256 _amount) external payable whenNotPaused nonReentrant {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        require(pool.isActive, "pool does not exist");

        Offer memory offer = offers[_lpAddress][_rarity][msg.sender];
        uint64 step = offer.currentStep;
        require(step > 0, "There is no offer");

        if (_getRewardRate(_lpAddress, _rarity, biddingPools[_lpAddress][_rarity][step].nodeIndex) > 0 && offer.amount > _amount) {
            require((block.timestamp - offer.startedAt) > offer.lockDuration, "lock duration error");
        }

        checkPayment(_lpAddress, _rarity, _amount, step);

        _updateTopPools(_lpAddress, _rarity);
        _harvestPending(_lpAddress, _rarity, msg.sender, false);

        if (_amount == 0 && biddingPools[_lpAddress][_rarity][step].totalOfferCount == offer.amount) {
            biddingPools[_lpAddress][_rarity][step].totalOfferCount = 0;
            // if the dropped node is rewardable then update next rewardable node if exists
            if (pool.activeNodeCount > 3) {
                _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
            }
            _dropNode(_lpAddress, _rarity, biddingPools[_lpAddress][_rarity][step].nodeIndex);
        } else {
            biddingPools[_lpAddress][_rarity][step].totalOfferCount -= offer.amount;
            biddingPools[_lpAddress][_rarity][step].totalOfferCount += _amount;
        }

        if (_amount == 0) {
            delete offers[_lpAddress][_rarity][msg.sender];
            _dropBiddingNode(_lpAddress, _rarity, offer.currentStep, offer.biddingNodeIndex);
        } else {
            offers[_lpAddress][_rarity][msg.sender].amount = _amount;
            offers[_lpAddress][_rarity][msg.sender].startedAt = block.timestamp;
            offers[_lpAddress][_rarity][msg.sender].rewardDebt = (_amount * biddingPools[_lpAddress][_rarity][step].accARTPerShare) / ACC_TOKEN_PRECISION;
        }

        emit UpdateOffer(_lpAddress, _rarity, msg.sender, _amount, step);
    }

    function acceptOffers(address _lpAddress, uint32 _rarity, address[] calldata _owners, uint256[] calldata _amounts, uint256[] calldata _tokenIds) external whenNotPaused nonReentrant {
        uint256 _len = _owners.length;
        uint256 t;
        for (uint256 i = 0; i < _len; i++) {
            require(_owners[i] != msg.sender, "cannot accept your own offer");

            uint256[] memory tokenIds = new uint256[](_amounts[i]);
            for (uint256 j = 0; j < _amounts[i]; j++) {
                tokenIds[j] = _tokenIds[t];
                t += 1;
            }
            acceptOffer(_lpAddress, _rarity, _owners[i], tokenIds);
        }
    }

    function acceptOffer(address _lpAddress, uint32 _rarity, address _owner, uint256[] memory _tokenIds) internal {
        uint256 _len = _tokenIds.length;
        require(_len > 0, "insufficient tokenIds");
        Offer memory offer = offers[_lpAddress][_rarity][_owner];
        PoolInfo memory pool = pools[_lpAddress][_rarity];

        require(offer.amount >= _len, "Insufficient offer amount");
        for (uint256 i; i<_len; i++) {
            uint256 _tokenId = _tokenIds[i];
            require(msg.sender == IERC721Upgradeable(_lpAddress).ownerOf(_tokenId), "NFT does not belong to the sender");
            require(_rarity == rarities[_lpAddress][_tokenId], "Rarity does not match");

            require(offer.currentStep > 0 && offer.currentStep == nodes[_lpAddress][_rarity][pool.highestNodeIndex].step, "offer must be top rewarded");

            _updateTopPools(_lpAddress, _rarity);

            _harvestPending(_lpAddress, _rarity, _owner, false);
            if (offers[_lpAddress][_rarity][_owner].amount == 1) {
                delete offers[_lpAddress][_rarity][_owner];
                _dropBiddingNode(_lpAddress, _rarity, offer.currentStep, offer.biddingNodeIndex);
            } else {
                offers[_lpAddress][_rarity][_owner].amount -= 1;
                offers[_lpAddress][_rarity][_owner].rewardDebt = (offers[_lpAddress][_rarity][_owner].amount * biddingPools[_lpAddress][_rarity][offer.currentStep].accARTPerShare) / ACC_TOKEN_PRECISION;
            }

            biddingPools[_lpAddress][_rarity][offer.currentStep].totalOfferCount -= 1;

            if (biddingPools[_lpAddress][_rarity][offer.currentStep].totalOfferCount == 0) {
                if (pool.activeNodeCount > 3) {
                    _updatePool(_lpAddress, _rarity, _getNextRewardableStep(_lpAddress, _rarity));
                }
                _dropNode(_lpAddress, _rarity, biddingPools[_lpAddress][_rarity][offer.currentStep].nodeIndex);
            }
            uint256 price = offer.currentStep * pool.stepPrice;
            emit AcceptOffer(_lpAddress, _rarity, _owner, msg.sender, _tokenId, offer.currentStep, price);
            IERC721Upgradeable(_lpAddress).safeTransferFrom(msg.sender, _owner, _tokenId);
            LibShareholder.Shareholder[] memory _shareholders;
            IPaymentManager(paymentManager).payout{ value: price }(
                payable(msg.sender),
                _lpAddress,
                _tokenId,
                _shareholders,
                pool.commissionPercentage
            );
        }
    }

    function checkPayment(address _lpAddress, uint32 _rarity, uint256 _amount, uint64 _step) internal {
        uint256 existingPayment = pools[_lpAddress][_rarity].stepPrice * offers[_lpAddress][_rarity][msg.sender].amount * offers[_lpAddress][_rarity][msg.sender].currentStep;
        uint256 newPayment = pools[_lpAddress][_rarity].stepPrice * _amount * _step;
        if (existingPayment > newPayment) {
            payable(msg.sender).transfer(existingPayment - newPayment);
        } else {
            require(msg.value >= (newPayment - existingPayment), "Insufficient payment");
        }
    }

    function _updateTopPools(address _lpAddress, uint32 _rarity) internal {
        PoolInfo memory pool = pools[_lpAddress][_rarity];

        Node memory highestNode;
        Node memory secondNode;
        if (pool.activeNodeCount > 0) {
            highestNode = nodes[_lpAddress][_rarity][pool.highestNodeIndex];
            _updatePool(_lpAddress, _rarity, highestNode.step);
        }
        if (pool.activeNodeCount > 1) {
            secondNode = nodes[_lpAddress][_rarity][highestNode.previousIndex];
            _updatePool(_lpAddress, _rarity, secondNode.step);
        }
        if (pool.activeNodeCount > 2) {
            _updatePool(_lpAddress, _rarity, nodes[_lpAddress][_rarity][secondNode.previousIndex].step);
        }
    }

    function _updatePool(address _lpAddress, uint32 _rarity, uint64 _step) internal {
        PoolBiddingInfo memory biddingPool = biddingPools[_lpAddress][_rarity][_step];
        uint256 rewardRate = _getRewardRate(_lpAddress, _rarity, biddingPool.nodeIndex);

        if (block.timestamp > biddingPool.lastRewardTimestamp) {
            if (biddingPool.totalOfferCount > 0) {
                uint256 secondsElapsed = block.timestamp - biddingPool.lastRewardTimestamp;
                uint256 artReward = secondsElapsed * rewardRate;
                biddingPools[_lpAddress][_rarity][_step].accARTPerShare = biddingPool.accARTPerShare + ((artReward * ACC_TOKEN_PRECISION) / biddingPool.totalOfferCount);
            }
            biddingPools[_lpAddress][_rarity][_step].lastRewardTimestamp = block.timestamp;
            emit UpdatePool(_lpAddress, _step, biddingPool.lastRewardTimestamp, biddingPool.totalOfferCount, biddingPool.accARTPerShare);
        }
    }

    function _getRewardRate(address _lpAddress, uint32 _rarity, uint64 _nodeIndex) public view returns(uint256) {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        uint64 highestNodeIndex = pool.highestNodeIndex;
        if (pool.activeNodeCount == 0) {
            return 0;
        }
        Node memory highestNode = nodes[_lpAddress][_rarity][highestNodeIndex];
        Node memory secondNode = nodes[_lpAddress][_rarity][highestNode.previousIndex];

        if (highestNodeIndex == _nodeIndex) {
            return pool.rewardRate;
        } else if (highestNode.previousIndex == _nodeIndex) {
            return pool.rewardSecondRate;
        } else if (secondNode.previousIndex == _nodeIndex) {
            return pool.rewardThirdRate;
        } else {
            return 0;
        }
    }

    function _getNextRewardableStep(address _lpAddress, uint32 _rarity) internal view returns(uint64) {
        PoolInfo memory pool = pools[_lpAddress][_rarity];
        uint64 highestNodeIndex = pool.highestNodeIndex;
        Node memory highestNode = nodes[_lpAddress][_rarity][highestNodeIndex];
        Node memory secondNode = nodes[_lpAddress][_rarity][highestNode.previousIndex];
        Node memory thirdNode = nodes[_lpAddress][_rarity][secondNode.previousIndex];

        return nodes[_lpAddress][_rarity][thirdNode.previousIndex].step;
    }

    function _harvestPending(address _lpAddress, uint32 _rarity, address _user, bool _isStandAlone) internal {
        Offer memory offer = offers[_lpAddress][_rarity][_user];
        uint256 pending = ((offer.amount * biddingPools[_lpAddress][_rarity][offer.currentStep].accARTPerShare) / ACC_TOKEN_PRECISION);
        pending -= offer.rewardDebt;
        if (pending > 0) {
            emit Harvest(_user, _lpAddress, _rarity, offer.currentStep, pending, _isStandAlone);
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
        biddingPools[_lpAddress][_rarity][_step].nodeIndex = _freeIndex;
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

    function _addBiddingNode(address _lpAddress, uint32 _rarity, uint64 _step, uint64 _freeIndex) internal {
        PoolBiddingInfo memory biddingPool = biddingPools[_lpAddress][_rarity][_step];
        bool doesFreeIndexPointReusableNode = _freeIndex < biddingNodes[_lpAddress][_rarity][_step].length && !biddingNodes[_lpAddress][_rarity][_step][_freeIndex].isActive;
        bool isReusableNodeExisting = (biddingNodes[_lpAddress][_rarity][_step].length - biddingPool.totalBiddingNodeCount) > 0;

        if (!doesFreeIndexPointReusableNode) {
            // _freeIndex must point last index of nodes as a new node
            require(_freeIndex == biddingNodes[_lpAddress][_rarity][_step].length, "bidding freeIndex is out of range");
            require(!isReusableNodeExisting, "Reusable node available");
        }

        BiddingNode memory newNode = BiddingNode({isActive: true, owner: msg.sender});
        if (doesFreeIndexPointReusableNode) {
            biddingNodes[_lpAddress][_rarity][_step][_freeIndex] = newNode;
        } else {
            biddingNodes[_lpAddress][_rarity][_step].push(newNode);
        }

        offers[_lpAddress][_rarity][msg.sender].biddingNodeIndex = _freeIndex;
        biddingPools[_lpAddress][_rarity][_step].totalBiddingNodeCount += 1;
    }

    function _dropBiddingNode(address _lpAddress, uint32 _rarity, uint64 _step, uint64 _nodeIndex) internal {
        delete biddingNodes[_lpAddress][_rarity][_step][_nodeIndex];
        biddingPools[_lpAddress][_rarity][_step].totalBiddingNodeCount -= 1;
    }

    function _safeTransfer(address _receiver, uint256 _amount) internal {
        uint256 _totalBalance = art.balanceOf(address(this));
        require(_totalBalance >= _amount, "insufficient balance");
        art.safeTransfer(_receiver, _amount);
    }
}