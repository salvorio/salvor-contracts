//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "../SalvorMini/ISalvorMini.sol";
import "../SalvorOperator/ISalvorOperator.sol";

/**
* @title VeArt
* @notice the users can simply stake and withdraw their NFTs for a specific period and earn rewards if it does not sell.
*/
contract VeArt is ERC721HolderUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    // Struct to store information about User's burned Salvor Mini NFTs
    struct UserSalvorMiniBoostInfo {
        // Total number of burned Salvor Mini NFTs
        uint256 totalBurnedSalvorMiniCount;
        // Total rarity level of burned Salvor Mini NFTs
        uint256 totalRarityLevel;
    }

    // Struct to store information about a user
    struct UserInfo {
        // Amount of ART staked by the user
        uint256 amount;
        // Time of the last VeART claim, or the time of the first deposit if the user has not claimed yet
        uint256 lastRelease;
        uint256 rewardDebt;
        uint256 artRewardDebt;
        uint256 failedArtBalance;
        uint256 failedBalance;
    }

    struct DQPool {
        uint256 multiplier;
        uint256 endedAt;
        uint256 withdrawDuration;
    }

    struct DQPoolItem {
        address owner;
        uint256 endedAt;
    }

    // Struct to store information about a user
    struct UserSalvorInfo {
        // Amount of Salvor staked by the user
        uint256 amount;
        uint256 rewardDebt;
    }

    // allows the whitelisted contracts.
    EnumerableSetUpgradeable.AddressSet private _whitelistedPlatforms;

    // The constant "WAD" represents the precision level for fixed point arithmetic, set to 10^18 for 18 decimal places precision.
    uint256 public constant WAD = 10**18;

    // Multiplier used to calculate the rarity level of Salvor Mini NFTs
    uint256 public rarityLevelMultiplier;

    // Total amount of ART staked by all users  
    uint256 public totalStakedARTAmount;

    // Contract representing the ART token
    IERC20Upgradeable public art;

    // Contract representing the Salvor Mini collection
    ISalvorMini public salvorMiniCollection;

    // max veART to staked art ratio
    // Note if user has 10 art staked, they can only have a max of 10 * maxCap veART in balance
    uint256 public maxCap;

    // the rate of veART generated per second, per art staked
    uint256 public veARTgenerationRate;

    // the rate at which rewards in ART are generated
    uint256 public rewardARTGenerationRate;

    // user info mapping
    mapping(address => UserInfo) public users;

    // Stores information about a user's Salvor Mini boost
    mapping(address => UserSalvorMiniBoostInfo) public userSalvorMiniBoostInfos;

    // Balance of rewards at the last reward distribution
    uint256 public lastRewardBalance;
    // Accumulated rewards per share
    uint256 public accRewardPerShare;
    // Accumulated ART rewards per share
    uint256 public accARTPerShare;
    // Timestamp of the last reward distribution
    uint256 public lastRewardTimestamp;
    // Precision used for ART reward calculations
    uint256 public ACC_ART_REWARD_PRECISION;
    // Precision used for reward per share calculations
    uint256 public ACC_REWARD_PER_SHARE_PRECISION;


    // Balances of each address
    mapping(address => uint256) private _balances;
    // Allowances granted by each address to other addresses
	mapping(address => mapping(address => uint256)) private _allowances;
    // Total supply of the token
    uint256 private _totalSupply;
    // Name of the token
	string private _name;
    // Symbol of the token
	string private _symbol;

    mapping(address => uint256) public boostDuration;
    mapping(address => uint256) public earnedTotalBoost;
    uint256 public boostFee;
    mapping(address => uint256) public dqBoostDuration;
    mapping(address => mapping(uint256 => uint256)) public dqRarityLevels;
    mapping(address => mapping(uint256 => uint256)) public dqRarityPrices;
    mapping(address => DQPool) public dqPools;
    mapping(address => mapping(uint256 => DQPoolItem)) public dqPoolItems;
    address public admin;
    uint256 public totalSalvorSupply;
    uint256 public accSalvorRewardPerShare;
    mapping(address => UserSalvorInfo) public salvorUsers;
    mapping(uint256 => address) public salvorOwners;
    ISalvorMini public salvorCollection;
    uint256 public depositSalvorFee;
    ISalvorOperator public salvorOperator;

    event Deposit(address indexed user, uint256 amount);
    event DepositART(address indexed user, uint256 amount);
    event DepositSalvor(address indexed user, uint256 indexed tokenId);
    event WithdrawSalvor(address indexed user, uint256 indexed tokenId);
    event WithdrawART(address indexed user, uint256 amount);
    event ClaimReward(address indexed user, uint256 amount);
    event ClaimSalvorReward(address indexed user, uint256 amount);
    event ClaimARTReward(address indexed user, uint256 amount);
    event ClaimedVeART(address indexed user, uint256 indexed amount);
    event MaxCapUpdated(uint256 cap);
    event ArtGenerationRateUpdated(uint256 rate);
    event Burn(address indexed account, uint256 value);
	event Mint(address indexed beneficiary, uint256 value);
    event BurnSalvorMini(address indexed user, uint256 indexed tokenId, uint256 rarityLevel);
    event WhitelistAdded(address indexed platform);
    event WhitelistRemoved(address indexed platform);
    event BoostFeeSet(uint256 boostFee);
    event DqStake(address indexed user, address indexed collection, uint256 indexed tokenId, uint256 endedAt);
    event DqWithdraw(address indexed user, address indexed collection, uint256 indexed tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Upgradeable _art) public initializer {
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
        _name = "SalvorVeArt";
		_symbol = "veART";
        veARTgenerationRate = 6415343915343;
        rewardARTGenerationRate = 77160493827160000;
        rarityLevelMultiplier = 1;
        maxCap = 100;
        art = _art;
        ACC_REWARD_PER_SHARE_PRECISION = 1e24;
        ACC_ART_REWARD_PRECISION = 1e18;
    }
    receive() external payable {}

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

    function setAdmin(address _admin) external onlyOwner {
        admin = _admin;
    }

    /**
    * @notice  allows the owner to add a contract address to the whitelist.
    * @param _whitelist The address of the contract.
    */
    function addPlatform(address _whitelist) external onlyOwner {
        require(!_whitelistedPlatforms.contains(_whitelist), "Error: already whitelisted");
        _whitelistedPlatforms.add(_whitelist);
        emit WhitelistAdded(_whitelist);
    }

    /**
    * @notice allows the owner to remove a contract address to restrict.
    * @param _whitelist The address of the contract.
    */
    function removePlatform(address _whitelist) external onlyOwner {
        require(_whitelistedPlatforms.contains(_whitelist), "Error: not whitelisted");
        _whitelistedPlatforms.remove(_whitelist);
        emit WhitelistRemoved(_whitelist);
    }

    function setSalvorAddress(address _salvorCollection) external onlyOwner {
        salvorCollection = ISalvorMini(_salvorCollection);
    }

    function setSalvorOperator(address _salvorOperator) external onlyOwner {
        salvorOperator = ISalvorOperator(_salvorOperator);
    }

    function setDQRarityLevels(address _collection, uint256[] calldata _tokenIds, uint256[] calldata _rarityLevels) external {
        require(msg.sender == owner() || msg.sender == admin, "caller is not authorized");
        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
            dqRarityLevels[_collection][_tokenIds[i]] = _rarityLevels[i];
        }
    }

    function setDQRarityPrices(address _collection, uint256[] calldata _rarityLevels, uint256[] calldata _prices) external onlyOwner {
        uint256 len = _rarityLevels.length;
        for (uint256 i; i < len; ++i) {
            dqRarityPrices[_collection][_rarityLevels[i]] = _prices[i];
        }
    }

    /**
	* @notice sets maxCap
    * @param _maxCap the new max ratio
    */
    function setMaxCap(uint256 _maxCap) external onlyOwner {
        maxCap = _maxCap;
        emit MaxCapUpdated(_maxCap);
    }

    /**
    * @notice Sets the reward ART generation rate
    * @param _rewardARTGenerationRate reward ART generation rate
    */
    function setARTGenerationRate(uint256 _rewardARTGenerationRate) external onlyOwner {
        _updateARTReward();
        rewardARTGenerationRate = _rewardARTGenerationRate;
        emit ArtGenerationRateUpdated(_rewardARTGenerationRate);
    }

    function setBoostFee(uint256 _boostFee) external onlyOwner {
        boostFee = _boostFee;
        emit BoostFeeSet(_boostFee);
    }

    function setDepositSalvorFee(uint256 _depositSalvorFee) external onlyOwner {
        depositSalvorFee = _depositSalvorFee;
    }

    function setDQConfiguration(address _collection, uint256 _duration, uint256 _withdrawDuration, uint256 _multiplier) external onlyOwner {
        dqPools[_collection].endedAt = block.timestamp + _duration;
        dqPools[_collection].multiplier = _multiplier;
        dqPools[_collection].withdrawDuration = _withdrawDuration;
    }

    /**
    * @notice Gets the balance of the contract
    */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
    * @notice Gets the boosted generation rate for a user
    * @param _addr The address of the user
    */
    function getBoostedGenerationRate(address _addr) external view returns (uint256) {
        if ((users[_addr].lastRelease + boostDuration[_addr]) > block.timestamp) {
            if ((users[_addr].lastRelease + dqBoostDuration[_addr]) > block.timestamp) {
                return veARTgenerationRate * 5;
            } else {
                return veARTgenerationRate * 4;
            }
        } else {
            if ((users[_addr].lastRelease + dqBoostDuration[_addr]) > block.timestamp) {
                return veARTgenerationRate * 2;
            } else {
                return veARTgenerationRate;
            }
        }
    }

    /**
    * @notice Allows a user to deposit ART tokens to earn rewards in veART
    * @param _amount The amount of ART tokens to be deposited
    */
    function depositART(uint256 _amount) external nonReentrant whenNotPaused {
        // ensures that the call is not made from a smart contract, unless it is on the whitelist.
        _assertNotContract(msg.sender);

        require(_amount > 0, "Error: Deposit amount must be greater than zero");
        require(art.balanceOf(msg.sender) >= _amount, "Error: Insufficient balance to deposit the specified amount");

        if (users[msg.sender].amount > 0) {
            // if user exists, first, claim his veART
            _harvestVeART(msg.sender);
            // then, increment his holdings
            users[msg.sender].amount += _amount;
        } else {
            // add new user to mapping
            users[msg.sender].lastRelease = block.timestamp;
            users[msg.sender].amount = _amount;
        }
        totalStakedARTAmount += _amount;

        emit DepositART(msg.sender, _amount);
        // Request art from user
        art.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
    * @notice Burns a salvormini NFT to boost VeART generation rate for the sender.
    * @param _tokenId The unique identifier of the SalvorMini NFT being burned.
    */
    function burnSalvorMiniToBoostVeART(uint256 _tokenId) external payable whenNotPaused nonReentrant {
        // ensures that the call is not made from a smart contract, unless it is on the whitelist.
        _assertNotContract(msg.sender);
        require(salvorMiniCollection.ownerOf(_tokenId) == msg.sender, "The provided NFT does not belong to the sender");

        uint256 secondsElapsed = block.timestamp - users[msg.sender].lastRelease;

        if (secondsElapsed < boostDuration[msg.sender]) {
            require(msg.value >= boostFee, "insufficient payment");
        }

        _harvestVeART(msg.sender);

        salvorMiniCollection.burn(_tokenId);

        uint256 rarityLevel = salvorMiniCollection.getRarityLevel(_tokenId);
        boostDuration[msg.sender] += rarityLevel * 3600;
        emit BurnSalvorMini(msg.sender, _tokenId, rarityLevel);
    }

    function stakeDqItems(address _collection, uint256[] calldata _tokenIds) external payable whenNotPaused nonReentrant {
        // ensures that the call is not made from a smart contract, unless it is on the whitelist.
        _assertNotContract(msg.sender);
        uint256 len = _tokenIds.length;
        uint256 price;
        require(block.timestamp < dqPools[_collection].endedAt, "The boosting pool has expired, and NFT staking is no longer allowed.");
        for (uint256 i; i < len; ++i) {
            price += dqRarityPrices[_collection][dqRarityLevels[_collection][_tokenIds[i]]];
        }
        require(msg.value >= ((100 * price * balanceOf(msg.sender)) / _totalSupply), "Insufficient payment provided for staking the NFT(s).");

        _harvestVeART(msg.sender);

        for (uint256 i; i < len; ++i) {
            require(ISalvorMini(_collection).ownerOf(_tokenIds[i]) == msg.sender, "The provided NFT does not belong to the sender");
            ISalvorMini(_collection).safeTransferFrom(msg.sender, address(this), _tokenIds[i]);
            dqBoostDuration[msg.sender] += dqRarityLevels[_collection][_tokenIds[i]] * dqPools[_collection].multiplier * 1800;
            dqPoolItems[_collection][_tokenIds[i]].owner = msg.sender;
            dqPoolItems[_collection][_tokenIds[i]].endedAt = block.timestamp + dqPools[_collection].withdrawDuration;
            emit DqStake(msg.sender, _collection, _tokenIds[i], dqPoolItems[_collection][_tokenIds[i]].endedAt);
        }
    }

    function withdrawDqItems(address _collection, uint256[] calldata _tokenIds) external whenNotPaused nonReentrant {
        _assertNotContract(msg.sender);
        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
            require(dqPoolItems[_collection][_tokenIds[i]].owner == msg.sender, "The provided NFT does not belong to the sender");
            require(dqPoolItems[_collection][_tokenIds[i]].endedAt <= block.timestamp, "The provided NFT has not yet expired, and cannot be withdrawn from the boosting pool.");

            ISalvorMini(_collection).safeTransferFrom(address(this), msg.sender, _tokenIds[i]);
            delete dqPoolItems[_collection][_tokenIds[i]];
            emit DqWithdraw(msg.sender, _collection, _tokenIds[i]);
        }
    }

    /**
    * @notice Withdraws all the ART deposit by the caller
    */
    function withdrawAllART() external nonReentrant whenNotPaused {
        require(users[msg.sender].amount > 0, "Error: amount to withdraw cannot be zero");
        require(salvorUsers[msg.sender].amount == 0, "Error: You must first unstake all of your The Salvors NFTs to unstake your ART.");
        _withdrawART(msg.sender, users[msg.sender].amount);
    }

    /**
    * @dev Allows the contract owner to withdraw all ART tokens from a specific user's account in case of an emergency.
    * @param _receiver The address of the user whose ART tokens will be withdrawn.
    */
    function emergencyWithdrawAllART(address _receiver) external onlyOwner {
        require(users[_receiver].amount > 0, "Error: amount to withdraw cannot be zero");
        require(salvorUsers[_receiver].amount == 0, "Error: You must first unstake all of your The Salvors NFTs to unstake your ART.");
        _withdrawART(_receiver, users[_receiver].amount);
    }

    /**
    * @notice Allows a user to withdraw a specified amount of ART
    * @param _amount The amount of ART to withdraw
    */
    function withdrawART(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Error: amount to withdraw cannot be zero");
        require(users[msg.sender].amount >= _amount, "Error: not enough balance");
        require(salvorUsers[msg.sender].amount == 0, "Error: You must first unstake all of your The Salvors NFTs to unstake your ART.");
        _withdrawART(msg.sender, _amount);
    }

    /**
    * @notice Harvests VeART rewards for the user
    * @param _receiver The address of the receiver
    */
    function harvestVeART(address _receiver) external nonReentrant whenNotPaused {
        require(users[_receiver].amount > 0, "Error: user has no stake");
        _harvestVeART(_receiver);
    }

    function withdrawSalvors(uint256[] calldata _tokenIds) external nonReentrant whenNotPaused {
        // ensures that the call is not made from a smart contract, unless it is on the whitelist.
        _assertNotContract(msg.sender);
        _withdrawSalvors(msg.sender, _tokenIds);
    }

    function emergencyWithdrawSalvors(address _receiver, uint256[] calldata _tokenIds) external onlyOwner {
        _withdrawSalvors(_receiver, _tokenIds);
    }

    /**
    * @notice This function allows the user to claim the rewards earned by their VeART holdings.
    * The rewards are calculated based on the current rewards per share and the user's VeART balance.
    * The user's reward debt is also updated to the latest rewards earned.
    * @param _receiver The address of the receiver
    */
    function _claimAllEarnings(address _receiver) internal {
        uint256 userVeARTBalance = balanceOf(_receiver);
        _updateReward();
        _updateARTReward();

        UserInfo memory user = users[_receiver];
        uint256 _pending = ((userVeARTBalance * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;

        uint256 _pendingARTReward = ((userVeARTBalance * accARTPerShare) / ACC_ART_REWARD_PRECISION) - user.artRewardDebt;

        uint256 _pendingSalvorReward = ((salvorUsers[_receiver].amount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - salvorUsers[_receiver].rewardDebt;

        uint256 failedBalance = users[_receiver].failedBalance;

        if (_pending > 0 || failedBalance > 0) {
            users[_receiver].rewardDebt = (userVeARTBalance * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;
            emit ClaimReward(_receiver, _pending);
            _claimEarnings(_receiver, _pending);
        }
        if (_pendingSalvorReward > 0) {
            salvorUsers[_receiver].rewardDebt = (salvorUsers[_receiver].amount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;
            emit ClaimSalvorReward(_receiver, _pendingSalvorReward);
            _claimEarnings(_receiver, _pendingSalvorReward);
        }
        if (_pendingARTReward > 0) {
            users[_receiver].artRewardDebt = (userVeARTBalance * accARTPerShare) / ACC_ART_REWARD_PRECISION;
            emit ClaimARTReward(_receiver, _pendingARTReward);
            _claimARTEarnings(_receiver, _pendingARTReward);
        }
    }

    /**
    * @notice This function allows the user to claim the rewards earned by their VeART holdings.
    * The rewards are calculated based on the current rewards per share and the user's VeART balance.
    * The user's reward debt is also updated to the latest rewards earned.
    * @param _receiver The address of the receiver
    */
    function claimEarnings(address _receiver) external nonReentrant whenNotPaused {
        _claimAllEarnings(_receiver);
    }

    /**
    * @notice View function to see pending reward token
    * @param _user The address of the user
    * @return `_user`'s pending reward token
    */
    function pendingRewards(address _user) external view returns (uint256) {
        UserInfo memory user = users[_user];
        uint256 _totalVeART = _totalSupply;
        uint256 _accRewardTokenPerShare = accRewardPerShare;
        uint256 _rewardBalance = address(this).balance;

        if (_rewardBalance != lastRewardBalance && _totalVeART != 0) {
            uint256 _accruedReward = _rewardBalance - lastRewardBalance;
            if (totalSalvorSupply > 0) {
                uint256 artRewardPart = ((_accruedReward) * 8) / 10;
                _accRewardTokenPerShare += ((artRewardPart * ACC_REWARD_PER_SHARE_PRECISION) / _totalVeART);
            } else {
                _accRewardTokenPerShare += ((_accruedReward * ACC_REWARD_PER_SHARE_PRECISION) / _totalVeART);
            }
        }

        uint256 currentBalance = balanceOf(_user);
        return ((currentBalance * _accRewardTokenPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;
    }

    /**
    * @notice View function to see pending reward token
    * @param _user The address of the user
    * @return `_user`'s pending reward token
    */
    function pendingSalvorRewards(address _user) external view returns (uint256) {
        UserSalvorInfo memory user = salvorUsers[_user];
        uint256 _accRewardTokenPerShare = accSalvorRewardPerShare;
        uint256 _rewardBalance = address(this).balance;

        if (_rewardBalance != lastRewardBalance && totalSalvorSupply != 0) {
            uint256 _accruedReward = _rewardBalance - lastRewardBalance;
            uint256 artRewardPart = ((_accruedReward) * 8) / 10;
            uint256 salvorRewardPart = _accruedReward - artRewardPart;

            _accRewardTokenPerShare += ((salvorRewardPart * ACC_REWARD_PER_SHARE_PRECISION) / totalSalvorSupply);
        }
        return ((user.amount * _accRewardTokenPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;
    }

    /**
    * @notice Calculates and returns the pending art rewards for a specific user.
    * @param _user the address of the user
    */
    function pendingARTRewards(address _user) external view returns (uint256) {
        UserInfo memory user = users[_user];
        uint256 _userVeART = balanceOf(_user);
        uint256 _totalVeART = _totalSupply;
        if (_userVeART > 0) {
            uint256 secondsElapsed = block.timestamp - lastRewardTimestamp;
            uint256 artReward = secondsElapsed * rewardARTGenerationRate;
            uint256 _accARTPerShare = accARTPerShare + ((artReward * ACC_ART_REWARD_PRECISION) / _totalVeART);
            return ((_userVeART * _accARTPerShare) / ACC_ART_REWARD_PRECISION) - user.artRewardDebt;
        }
        return 0;
    }

    /**
    * @notice Calculate the amount of veART that can be claimed by user
    * @param _addr The address of the user
    * @return amount of veART that can be claimed by user
    */
    function claimableVeART(address _addr) public view returns (uint256) {
        UserInfo storage user = users[_addr];

        // get seconds elapsed since last claim
        uint256 secondsElapsed = block.timestamp - user.lastRelease;

        // calculate pending amount
        // Math.mwmul used to multiply wad numbers

        uint256 pending = _wmul(user.amount, secondsElapsed * veARTgenerationRate);
        if (secondsElapsed > boostDuration[_addr]) {
            pending += _wmul(user.amount, boostDuration[_addr] * veARTgenerationRate * 3);
        } else {
            pending += _wmul(user.amount, secondsElapsed * veARTgenerationRate * 3);
        }

        if (secondsElapsed > dqBoostDuration[_addr]) {
            pending += _wmul(user.amount, dqBoostDuration[_addr] * veARTgenerationRate * 1);
        } else {
            pending += _wmul(user.amount, secondsElapsed * veARTgenerationRate * 1);
        }

        // get user's veART balance
        uint256 userVeARTBalance = balanceOf(_addr);



        // user vePTP balance cannot go above user.amount * maxCap
        uint256 maxVeARTCap = user.amount * maxCap;

        // first, check that user hasn't reached the max limit yet
        if (userVeARTBalance < maxVeARTCap) {
            // then, check if pending amount will make user balance overpass maximum amount
            if ((userVeARTBalance + pending) > maxVeARTCap) {
                return maxVeARTCap - userVeARTBalance;
            } else {
                return pending;
            }
        }
        return 0;
    }

        /**
	 * @notice Returns the name of the token.
     */
	function name() public view returns (string memory) {
		return _name;
	}

	/**
	 * @notice Returns the symbol of the token, usually a shorter version of the name.
     */
	function symbol() public view returns (string memory) {
		return _symbol;
	}

    /**
	* @notice See {IERC20-totalSupply}.
    */
	function totalSupply() external view returns (uint256) {
		return _totalSupply;
	}

	/**
	* @notice See {IERC20-balanceOf}.
    */
	function balanceOf(address account) public view returns (uint256) {
		return _balances[account];
	}

	/**
	* @notice Returns the number of decimals used to get its user representation.
    */
	function decimals() public pure returns (uint8) {
		return 18;
	}

    function _withdrawART(address _receiver, uint256 _amount) internal {
        UserInfo memory user = users[_receiver];
        UserSalvorInfo memory userSalvorInfo = salvorUsers[_receiver];
        // Reset the user's last release timestamp
        users[_receiver].lastRelease = block.timestamp;

        // Update the user's ART balance by subtracting the withdrawn amount
        users[_receiver].amount = user.amount - _amount;
        // Update the total staked ART amount
        totalStakedARTAmount -= _amount;

        // Calculate the user's VEART balance that must be burned
        uint256 userVeARTBalance = balanceOf(_receiver);

        if (userVeARTBalance > 0) {
            // Update the rewards
            _updateReward();
            _updateARTReward();

            // Calculate the pending rewards and ART rewards
            uint256 _pending = ((userVeARTBalance * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - user.rewardDebt;

            uint256 _pendingARTReward = ((userVeARTBalance * accARTPerShare) / ACC_ART_REWARD_PRECISION) - user.artRewardDebt;

            uint256 currentSalvorRewardDebt = ((userSalvorInfo.amount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION);
            uint256 _pendingSalvorReward = currentSalvorRewardDebt - userSalvorInfo.rewardDebt;

            // Reset the user's reward and ART reward debts
            users[_receiver].rewardDebt = 0;
            users[_receiver].artRewardDebt = 0;
            salvorUsers[_receiver].rewardDebt = currentSalvorRewardDebt;


            // Claim the rewards and ART rewards if there is a pending amount
            if (_pending > 0) {
                emit ClaimReward(_receiver, _pending);
                _claimEarnings(_receiver, _pending);
            }
            if (_pendingSalvorReward > 0) {
                emit ClaimSalvorReward(_receiver, _pendingSalvorReward);
                _claimEarnings(_receiver, _pendingSalvorReward);
            }
            if (_pendingARTReward > 0) {
                emit ClaimARTReward(_receiver, _pendingARTReward);
                _claimARTEarnings(_receiver, _pendingARTReward);
            }

            // Burn the user's VEART balance
            _burn(_receiver, userVeARTBalance);
        }

        emit WithdrawART(_receiver, _amount);
        // Send the withdrawn ART back to the user
        art.safeTransfer(_receiver, _amount);
    }

    /**
    * @notice Update reward variables
    */
    function _updateReward() internal {
        uint256 _totalVeART = _totalSupply;
        uint256 _rewardBalance = address(this).balance;

        if (_rewardBalance == lastRewardBalance || _totalVeART == 0) {
            return;
        }

        uint256 _accruedReward = _rewardBalance - lastRewardBalance;

        if (totalSalvorSupply > 0) {
            uint256 artPartReward = ((_accruedReward * 8) / 10);
            uint256 salvorPartReward = _accruedReward - artPartReward;
            accRewardPerShare += ((artPartReward * ACC_REWARD_PER_SHARE_PRECISION) / _totalVeART);
            accSalvorRewardPerShare += ((salvorPartReward * ACC_REWARD_PER_SHARE_PRECISION) / totalSalvorSupply);
        } else {
            accRewardPerShare += ((_accruedReward * ACC_REWARD_PER_SHARE_PRECISION) / _totalVeART);
        }

        lastRewardBalance = _rewardBalance;
    }

    /**
    * @notice Updates the accARTPerShare and lastRewardTimestamp value, which is used to calculate the rewards
    * users will earn when they harvest in the future.
    */
    function _updateARTReward() internal {
        uint256 _totalVeART = _totalSupply;
        if (block.timestamp > lastRewardTimestamp && _totalVeART > 0) {

            uint256 secondsElapsed = block.timestamp - lastRewardTimestamp;
            uint256 artReward = secondsElapsed * rewardARTGenerationRate;
            accARTPerShare += ((artReward * ACC_ART_REWARD_PRECISION) / _totalVeART);
        }
        lastRewardTimestamp = block.timestamp;
    }

    /**
    * This internal function _harvestVeART is used to allow the users to claim the VeART they are entitled to.
    * It calculates the amount of VeART that can be claimed based on the user's stake, updates the user's
    * last release time, deposits the VeART to the user's account, and mints new VeART tokens.
    *
    * @param _addr address of the user claiming VeART
    */
    function _harvestVeART(address _addr) internal {
        uint256 amount = claimableVeART(_addr);
        uint256 timeElapsed = block.timestamp - users[_addr].lastRelease;
        if (timeElapsed > boostDuration[_addr]) {
            boostDuration[_addr] = 0;
        } else {
            boostDuration[_addr] -= timeElapsed;
        }

        if (timeElapsed > dqBoostDuration[_addr]) {
            dqBoostDuration[_addr] = 0;
        } else {
            dqBoostDuration[_addr] -= timeElapsed;
        }

        // Update the user's last release time
        users[_addr].lastRelease = block.timestamp;

        // If the amount of VeART that can be claimed is greater than 0
        if (amount > 0) {
            // deposit the VeART to the user's account
            _depositVeART(_addr, amount);
            // mint new VeART tokens
            _mint(_addr, amount);
            emit ClaimedVeART(_addr, amount);
        }
    }

    function _depositVeART(address _user, uint256 _amount) internal {
        UserInfo memory user = users[_user];
        UserSalvorInfo memory userSalvorInfo = salvorUsers[_user];

        // Calculate the new balance after the deposit
        uint256 _previousAmount = balanceOf(_user);
        uint256 _newAmount = _previousAmount + _amount;

        // Update the reward variables
        _updateReward();
        _updateARTReward();

        // Calculate the reward debt for the new balance
        uint256 _previousRewardDebt = user.rewardDebt;
        users[_user].rewardDebt = (_newAmount * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;

        // Calculate the art reward debt for the new balance
        uint256 _previousARTRewardDebt = user.artRewardDebt;
        users[_user].artRewardDebt = (_newAmount * accARTPerShare) / ACC_ART_REWARD_PRECISION;

        // If the user had a non-zero balance before the deposit
        if (_previousAmount != 0) {
            // Calculate the pending reward for the previous balance
            uint256 _pending = ((_previousAmount * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - _previousRewardDebt;

            // If there is a pending reward, claim it
            if (_pending != 0) {
                emit ClaimReward(_user, _pending);
                _claimEarnings(_user, _pending);
            }

            // Calculate the pending art reward for the previous balance
            uint256 _pendingARTReward = ((_previousAmount * accARTPerShare) / ACC_ART_REWARD_PRECISION) - _previousARTRewardDebt;
            // If there is a pending art reward, claim it
            if (_pendingARTReward != 0) {
                emit ClaimARTReward(_user, _pending);
                _claimARTEarnings(_user, _pendingARTReward);
            }
        }

        if (userSalvorInfo.amount > 0) {
            // Calculate the reward debt for the new balance
            uint256 _previousSalvorRewardDebt = userSalvorInfo.rewardDebt;
            uint256 currentSalvorRewardDebt = (userSalvorInfo.amount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;
            salvorUsers[_user].rewardDebt = currentSalvorRewardDebt;

            // Calculate the pending reward for the previous balance
            uint256 _pendingSalvorReward = currentSalvorRewardDebt - _previousSalvorRewardDebt;

            // If there is a pending reward, claim it
            if (_pendingSalvorReward != 0) {
                emit ClaimSalvorReward(_user, _pendingSalvorReward);
                _claimEarnings(_user, _pendingSalvorReward);
            }
        }

        emit Deposit(_user, _amount);
    }

    function depositSalvors(uint256[] calldata _tokenIds) external payable nonReentrant whenNotPaused {
        uint256 len = _tokenIds.length;
        require(len <= 100, "exceeded the limits");
        require(balanceOf(msg.sender) * 10000 >= _totalSupply, "Insufficient power balance.");
        // ensures that the call is not made from a smart contract, unless it is on the whitelist.
        _assertNotContract(msg.sender);
        uint256 totalSalvorAmount;
        for (uint256 i; i < len; ++i) {
            uint256 salvorPower = salvorOperator.getSalvorPower(_tokenIds[i]);
            require(salvorPower > 0, "The provided NFT does not have salvor power");
            require(salvorCollection.ownerOf(_tokenIds[i]) == msg.sender, "The provided NFT does not belong to the sender");
            emit DepositSalvor(msg.sender, _tokenIds[i]);
            salvorCollection.transferFrom(msg.sender, address(this), _tokenIds[i]);
            salvorOwners[_tokenIds[i]] = msg.sender;
            totalSalvorAmount += salvorPower;
        }
        if (balanceOf(msg.sender) * 100 <= _totalSupply) {
            require(msg.value >= (depositSalvorFee * len), "Insufficient payment provided to deposit.");
        } else {
            uint256 precision = 100000;
            require(msg.value >= ((depositSalvorFee * len * precision) / ((100 * balanceOf(msg.sender) * precision) / _totalSupply)), "Insufficient payment provided to deposit.");
        }

        UserSalvorInfo memory userSalvorInfo = salvorUsers[msg.sender];
        UserInfo memory user = users[msg.sender];

        // Calculate the new balance after the deposit
        uint256 _previousAmount = userSalvorInfo.amount;
        uint256 _newAmount = _previousAmount + totalSalvorAmount;

        // Update the reward variables
        _updateReward();

        uint256 userVeARTBalance = balanceOf(msg.sender);
        uint256 currentRewardDebt = ((userVeARTBalance * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION);
        uint256 _pending = currentRewardDebt - user.rewardDebt;
        users[msg.sender].rewardDebt = currentRewardDebt;

        if (_pending > 0) {
            emit ClaimReward(msg.sender, _pending);
            _claimEarnings(msg.sender, _pending);
        }


        // Calculate the reward debt for the new balance
        uint256 _previousSalvorRewardDebt = userSalvorInfo.rewardDebt;
        salvorUsers[msg.sender].rewardDebt = (_newAmount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;


        // If the user had a non-zero balance before the deposit
        if (_previousAmount != 0) {
            // Calculate the pending reward for the previous balance
            uint256 _pendingSalvorReward = ((_previousAmount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - _previousSalvorRewardDebt;

            // If there is a pending reward, claim it
            if (_pendingSalvorReward != 0) {
                emit ClaimSalvorReward(msg.sender, _pendingSalvorReward);
                _claimEarnings(msg.sender, _pendingSalvorReward);
            }
        }
        salvorUsers[msg.sender].amount += totalSalvorAmount;
        totalSalvorSupply += totalSalvorAmount;
    }

    function _withdrawSalvors(address _receiver, uint256[] memory _tokenIds) internal {
        uint256 len = _tokenIds.length;
        UserSalvorInfo memory userSalvorInfo = salvorUsers[_receiver];
        UserInfo memory user = users[_receiver];
        uint256 totalSalvorAmount;
        for (uint256 i; i < len; ++i) {
            uint256 salvorPower = salvorOperator.getSalvorPower(_tokenIds[i]);
            require(salvorPower > 0, "The provided NFT does not have salvor power");
            require(salvorOwners[_tokenIds[i]] == _receiver, "The provided NFT does not belong to the sender");
            emit WithdrawSalvor(_receiver, _tokenIds[i]);
            salvorCollection.transferFrom(address(this), _receiver, _tokenIds[i]);
            totalSalvorAmount += salvorPower;
            delete salvorOwners[_tokenIds[i]];
        }

        // Calculate the new balance after the deposit
        uint256 _previousAmount = userSalvorInfo.amount;
        uint256 _newAmount = _previousAmount - totalSalvorAmount;

        // Update the reward variables
        _updateReward();

        uint256 userVeARTBalance = balanceOf(_receiver);
        uint256 currentRewardDebt = ((userVeARTBalance * accRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION);
        uint256 _pending = currentRewardDebt - user.rewardDebt;
        users[_receiver].rewardDebt = currentRewardDebt;

        if (_pending > 0) {
            emit ClaimReward(_receiver, _pending);
            _claimEarnings(_receiver, _pending);
        }

        uint256 _previousSalvorRewardDebt = userSalvorInfo.rewardDebt;
        salvorUsers[_receiver].rewardDebt = (_newAmount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION;

        uint256 _pendingSalvorReward = ((_previousAmount * accSalvorRewardPerShare) / ACC_REWARD_PER_SHARE_PRECISION) - _previousSalvorRewardDebt;

        // If there is a pending reward, claim it
        if (_pendingSalvorReward != 0) {
            emit ClaimSalvorReward(_receiver, _pendingSalvorReward);
            _claimEarnings(_receiver, _pendingSalvorReward);
        }

        salvorUsers[_receiver].amount -= totalSalvorAmount;
        totalSalvorSupply -= totalSalvorAmount;
    }

    /**
    * @notice Transfers a specified amount of Ethers from the contract to a user.
    * @dev If the specified amount is greater than the contract's Ether balance,
    * the remaining balance will be stored as failedBalance for the user, to be sent in future transactions.
    * @param _receiver The address of the recipient of the ART tokens.
    * @param _amount The amount of Ethers to be transferred.
    */
    function _claimEarnings(address _receiver, uint256 _amount) internal {
        address payable to = payable(_receiver);

        // get the current balance of the reward contract
        uint256 _rewardBalance = address(this).balance;
        _amount += users[_receiver].failedBalance;

        // check if the amount to be claimed is greater than the reward balance
        if (_amount > _rewardBalance) {
            // if yes, deduct the entire reward balance from the lastRewardBalance and transfer it to the user
            lastRewardBalance -= _rewardBalance;

            users[_receiver].failedBalance = _amount - _rewardBalance;

            if (_rewardBalance > 0) {
                (bool success, ) = to.call{value: _rewardBalance}("");
                require(success, "claim earning is failed");
            }
        } else {
            // if not, deduct the amount to be claimed from the lastRewardBalance and transfer it to the user
            lastRewardBalance -= _amount;
            users[_receiver].failedBalance = 0;
            (bool success, ) = to.call{value: _amount}("");
            require(success, "claim earning is failed");
        }
    }

    /**
    * @notice Transfers a specified amount of ART tokens from the contract to a user.
    * @dev If the specified amount is greater than the contract's ART balance,
    * the remaining balance will be stored as failedArtBalance for the user, to be sent in future transactions.
    * @param _receiver The address of the recipient of the ART tokens.
    * @param _amount The amount of ART tokens to be transferred.
    */
    function _claimARTEarnings(address _receiver, uint256 _amount) internal {
        uint256 _totalBalance = art.balanceOf(address(this)) - totalStakedARTAmount;
        _amount += users[_receiver].failedArtBalance;
        if (_amount > _totalBalance) {
            users[_receiver].failedArtBalance = _amount - _totalBalance;
            if (_totalBalance > 0) {
                art.safeTransfer(_receiver, _totalBalance);
            }
        } else {
            users[_receiver].failedArtBalance = 0;
            art.safeTransfer(_receiver, _amount);
        }
    }

    /**
    * @notice This function asserts that the address provided in the parameter is not a smart contract. 
    * If it is a smart contract, it verifies that it is included in the list of approved platforms.
    * @param _addr the address to be checked
    */
    function _assertNotContract(address _addr) private view {
        if (_addr != tx.origin) {
            require(_whitelistedPlatforms.contains(_addr), 'Error: Unauthorized smart contract access');
        }
    }



    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
	function _mint(address account, uint256 amount) internal {
		require(account != address(0), "ERC20: mint to the zero address");

		_beforeTokenTransfer(address(0), account, amount);

		_totalSupply += amount;
		_balances[account] += amount;
		emit Mint(account, amount);

		_afterTokenOperation(account, _balances[account]);
	}

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
	function _burn(address account, uint256 amount) internal {
		require(account != address(0), "ERC20: burn from the zero address");

		_beforeTokenTransfer(account, address(0), amount);

		uint256 accountBalance = _balances[account];
		require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
		unchecked {
			_balances[account] = accountBalance - amount;
		}
		_totalSupply -= amount;

		emit Burn(account, amount);

		_afterTokenOperation(account, _balances[account]);
	}

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
	function _beforeTokenTransfer(address from, address to, uint256 amount) internal {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
	function _afterTokenOperation(address account, uint256 newBalance) internal {}

    /**
    * performs a rounded multiplication of two uint256 values `x` and `y` 
    * by first multiplying them and then adding `WAD / 2` to the result before dividing by `WAD`.
    * The `WAD` constant is used as a divisor to control the precision of the result. 
    * The final result is rounded to the nearest integer towards zero,
    * if the result is exactly halfway between two integers it will be rounded to the nearest integer towards zero.
    */
    function _wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return ((x * y) + (WAD / 2)) / WAD;
    }
}