//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "../SalvorCollection/ISalvorCollection.sol";
import "../SalvorMini/ISalvorMini.sol";


contract SalvorOperator is ERC721HolderUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, OwnableUpgradeable {
    struct VRFRequest {
        bool requested;
        bool handled;
        bool isOnChain;
        uint256 tokenId;
        uint256 randomWord;
    }
    struct Breed {
        uint256 requestId;
        uint32 index;
        address owner;
        uint256 startedAt;
        uint256 endedAt;
    }
    struct BreedingPrice {
        uint256 count;
        uint256 price;
    }
    struct Salvor {
        uint32 level;
        uint32 rarityScore;
    }
    address public veArtAddress;
    address public salvorAddress;
    address public salvorMiniAddress;
    address public adminWallet;
    address payable public companyWallet;

    uint256 public minBreedingDuration;
    mapping(uint32 => BreedingPrice) public breedingSteps;
    uint32 public currentBreedingStep;
    uint256 public totalMinted;

    uint256 public requestIds;

    /**
    * @notice failed transfer amounts are accumulated.
    */
    uint256 public failedTransferBalance;
    // requestId -> index of amount -> vrfRequest
    mapping(uint256 => mapping(uint256 => VRFRequest)) public vrfRequests;
    // tokenId -> breed
    mapping(uint256 => Breed) public breeds;
    // tokenId -> salvor
    mapping(uint256 => Salvor) public salvors;
    // level -> rarityScore -> rarityLevelIndex -> rate
    mapping(uint32 => mapping(uint32 => mapping(uint32 => uint96))) public miniRates;

    // rarityScore -> level -> salvorPower
    mapping(uint32 => mapping(uint32 => uint256)) public salvorPowers;
    // rarityScore -> level -> price
    mapping(uint32 => mapping(uint32 => uint256)) public levelPrices;

    uint96 public companyWalletPercentage;

    event CompanyWalletSet(address indexed companyWalletset);
    event SetCompanyWalletPercentage(uint96 _veARTPercentage);
    event RndRequest(uint256 indexed requestId, uint256 amount);
    event TotalMintedReset();
    event StakeSalvor(uint256 indexed tokenId, uint256 indexed requestId);
    event BreedMini(uint256 indexed tokenId, uint256 indexed requestId, uint256 indexed miniTokenId, uint256 rarityLevel, uint96 rate, bool isMinted);
    event RebreedMini(uint256 indexed tokenId, uint256 indexed requestId, uint256 indexed miniTokenId, uint256 rarityLevel, uint96 rate, bool isMinted);
    event RebreedStakeSalvor(uint256 indexed tokenId, uint256 indexed requestId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _veArtAddress, address _salvorAddress, address _salvorMiniAddress, address _adminWallet) public initializer {
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
        veArtAddress = _veArtAddress;
        salvorAddress = _salvorAddress;
        salvorMiniAddress = _salvorMiniAddress;
        adminWallet = _adminWallet;

        // 24 hours
        minBreedingDuration = 86400;
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


    function setCompanyWalletPercentage(uint96 _companyWalletPercentage) external onlyOwner {
        companyWalletPercentage = _companyWalletPercentage;
        emit SetCompanyWalletPercentage(_companyWalletPercentage);
    }

    function setCompanyWallet(address _companyWallet) external onlyOwner {
        companyWallet = payable(_companyWallet);
        emit CompanyWalletSet(_companyWallet);
    }

    function setDropRates(uint32 _level, uint32 rarityScore, uint96[] calldata rates) external onlyOwner {
        require(rates.length == 3, "Invalid input length");
        uint96 total;
        for (uint32 i=0; i<3; i++) {
            total += rates[i];
            miniRates[_level][rarityScore][i] = rates[i];
        }
        require(total <= 10000, "Invalid drop rate total");
    }

    function setMinBreedingDuration(uint256 _minBreedingDuration) external onlyOwner {
        minBreedingDuration = _minBreedingDuration;
    }

    function setBreedingPrices(uint32 _step, uint256 _count, uint256 _breedingPrice) external onlyOwner {
        breedingSteps[_step].count = _count;
        breedingSteps[_step].price = _breedingPrice;
    }

    function setAdminWallet(address _adminWallet) external onlyOwner {
        adminWallet = _adminWallet;
    }

    function setSalvorMiniAddress(address _salvorMiniAddress) external onlyOwner {
        salvorMiniAddress = _salvorMiniAddress;
    }

    function resetTotalMinted() external onlyOwner {
        totalMinted = 0;
        emit TotalMintedReset();
    }

    function setSalvorPowers(uint32[] calldata _levels, uint32[] calldata _rarityScores, uint256[] calldata _powers) external onlyOwner {
        uint256 len = _levels.length;
        for (uint8 i = 0; i < len; i++) {
            salvorPowers[_rarityScores[i]][_levels[i]] = _powers[i];
        }
    }

    function setSalvorUpgradePrices(uint32[] calldata _rarityScores, uint32[] calldata _levels, uint256[] calldata prices) external onlyOwner {
        uint256 len = _levels.length;
        for (uint8 i = 0; i < len; i++) {
            levelPrices[_rarityScores[i]][_levels[i]] = prices[i];
        }
    }

    function setSalvorAttributes(uint256[] calldata _nftTokenIds, uint32[] calldata _levels, uint32[] calldata _rarityScores) external onlyOwner {
        uint256 len = _nftTokenIds.length;
        for (uint256 i = 0; i < len; i++) {
            salvors[_nftTokenIds[i]].level = _levels[i];
            salvors[_nftTokenIds[i]].rarityScore = _rarityScores[i];
        }
    }

    function stake(uint256[] calldata _tokenIds) external payable nonReentrant whenNotPaused {
        uint32 len = uint32(_tokenIds.length);
        require(len <= 20, "Too many tokens to breed at once");
        require(msg.value >= (len * breedingSteps[currentBreedingStep].price), "Insufficient funds to breed");
        uint256 payment = msg.value;
        if (companyWallet != address(0x0)) {
            uint256 companyWalletPart = _getPortionOfBid(payment, companyWalletPercentage);
            payment -= companyWalletPart;
            _safeTransferTo(companyWallet, companyWalletPart);
        }
        if (payment > 0) {
            _safeTransferTo(veArtAddress, payment);
        }

        uint256 requestId = ++requestIds;
        emit RndRequest(requestId, len);

        for (uint32 i = 0; i<len; i++) {
            uint256 _tokenId = _tokenIds[i];
            emit StakeSalvor(_tokenId, requestId);

            require(IERC721Upgradeable(salvorAddress).ownerOf(_tokenId) == msg.sender, "The provided NFT does not belong to the sender");
            IERC721Upgradeable(salvorAddress).safeTransferFrom(msg.sender, address(this), _tokenId);

            require(salvors[_tokenId].rarityScore > 0, "The provided NFT needs to have a rarity score.");

            breeds[_tokenId].owner = msg.sender;
            breeds[_tokenId].startedAt = block.timestamp;
            breeds[_tokenId].endedAt = block.timestamp + minBreedingDuration;
            breeds[_tokenId].requestId = requestId;
            breeds[_tokenId].index = i;

            vrfRequests[requestId][i].tokenId = _tokenId;
            vrfRequests[requestId][i].requested = true;
        }
    }

    function breedMini(uint256[] calldata _tokenIds) external nonReentrant whenNotPaused {
        uint32 len = uint32(_tokenIds.length);
        require(len <= 20, "Too many tokens to rebreed at once");
        uint256 counter;

        for (uint32 i; i<len; i++) {
            uint256 _tokenId = _tokenIds[i];
            Breed memory breed = breeds[_tokenId];
            require(breed.startedAt > 0, "No breeding action initiated");
            require(breed.owner == msg.sender, "The provided NFT does not belong to the sender");
            require(breed.endedAt <= block.timestamp, "Breeding result not available yet");

            uint32 level = salvors[_tokenId].level;
            uint32 rarityScore = salvors[_tokenId].rarityScore;

            uint96 commonDropRate = miniRates[level][rarityScore][0];
            uint96 epicDropRate = miniRates[level][rarityScore][1];
            uint96 legendaryDropRate = miniRates[level][rarityScore][2];

            if (!vrfRequests[breed.requestId][breed.index].handled && vrfRequests[breed.requestId][breed.index].requested) {
                _setRandomWord(breed.requestId, breed.index);
            }

            uint96 randomWord = uint96(vrfRequests[breed.requestId][breed.index].randomWord % 10000);

            uint256 rarityLevel;
            if (randomWord <= commonDropRate) {
                rarityLevel = 4;
            } else if (randomWord <= (commonDropRate + epicDropRate)) {
                rarityLevel = 12;
            } else if (randomWord <= (commonDropRate + epicDropRate + legendaryDropRate)) {
                rarityLevel = 60;
            }
            if (rarityLevel > 0) {
                counter++;
                uint256 generatedMiniTokenId = ISalvorMini(salvorMiniAddress).mint(breed.owner, rarityLevel);
                emit BreedMini(_tokenId, breed.requestId, generatedMiniTokenId, rarityLevel, randomWord, true);
            } else {
                emit BreedMini(_tokenId, breed.requestId, 0, 0, randomWord, false);
            }
            delete breeds[_tokenId];
            IERC721Upgradeable(salvorAddress).safeTransferFrom(address(this), msg.sender, _tokenId);
        }
        totalMinted += counter;
        if (totalMinted > breedingSteps[currentBreedingStep].count) {
            currentBreedingStep++;
        }
    }

    function rebreed(uint256[] calldata _tokenIds) external payable nonReentrant whenNotPaused {
        uint32 len = uint32(_tokenIds.length);
        require(len <= 20, "Too many tokens to rebreed at once");

        uint256 counter;
        require(msg.value >= (len * breedingSteps[currentBreedingStep].price), "Insufficient funds to breed");
        uint256 payment = msg.value;
        if (companyWallet != address(0x0)) {
            uint256 companyWalletPart = _getPortionOfBid(payment, companyWalletPercentage);
            payment -= companyWalletPart;
            _safeTransferTo(companyWallet, companyWalletPart);
        }
        if (payment > 0) {
            _safeTransferTo(veArtAddress, payment);
        }
        uint256 requestId = ++requestIds;
        emit RndRequest(requestId, len);
        for (uint256 i; i<len; i++) {
            uint256 _tokenId = _tokenIds[i];
            Breed memory breed = breeds[_tokenId];
            require(breed.startedAt > 0, "No breeding action initiated");
            require(breed.owner == msg.sender, "The provided NFT does not belong to the sender");
            require(breed.endedAt <= block.timestamp, "Breeding result not available yet");

            uint32 level = salvors[_tokenId].level;
            uint32 rarityScore = salvors[_tokenId].rarityScore;

            uint96 commonDropRate = miniRates[level][rarityScore][0];
            uint96 epicDropRate = miniRates[level][rarityScore][1];
            uint96 legendaryDropRate = miniRates[level][rarityScore][2];

            if (!vrfRequests[breed.requestId][breed.index].handled && vrfRequests[breed.requestId][breed.index].requested) {
                _setRandomWord(breed.requestId, breed.index);
            }

            uint96 randomWord = uint96(vrfRequests[breed.requestId][breed.index].randomWord % 10000);

            uint256 rarityLevel;
            if (randomWord <= commonDropRate) {
                rarityLevel = 4;
            } else if (randomWord <= (commonDropRate + epicDropRate)) {
                rarityLevel = 12;
            } else if (randomWord <= (commonDropRate + epicDropRate + legendaryDropRate)) {
                rarityLevel = 60;
            }
            if (rarityLevel > 0) {
                counter++;
                uint256 generatedMiniTokenId = ISalvorMini(salvorMiniAddress).mint(breed.owner, rarityLevel);
                emit RebreedMini(_tokenId, breed.requestId, generatedMiniTokenId, rarityLevel, randomWord, true);
            } else {
                emit RebreedMini(_tokenId, breed.requestId, 0, 0, randomWord, false);
            }
            emit RebreedStakeSalvor(_tokenId, requestId);
            breeds[_tokenId].startedAt = block.timestamp;
            breeds[_tokenId].endedAt = block.timestamp + minBreedingDuration;
            breeds[_tokenId].requestId = requestId;

            vrfRequests[requestId][i].tokenId = _tokenId;
            vrfRequests[requestId][i].requested = true;
        }
        totalMinted += counter;
        if (totalMinted > breedingSteps[currentBreedingStep].count) {
            currentBreedingStep++;
        }
    }

    function upgradeSalvor(uint256 _tokenId, uint32 amount) external payable nonReentrant whenNotPaused {
        require(amount > 0, "must be higher than 0");
        require(IERC721Upgradeable(salvorAddress).ownerOf(_tokenId) == msg.sender, "The provided NFT does not belong to the sender");
        uint32 currentLevel = salvors[_tokenId].level;
        uint32 rarityScore = salvors[_tokenId].rarityScore;
        uint256 totalPrice;
        for (uint32 i; i<amount; i++) {
            totalPrice += levelPrices[rarityScore][currentLevel+i+1];
        }
        require(msg.value >= totalPrice, "Insufficient funds to upgrade");

        uint256 payment = msg.value;
        if (companyWallet != address(0x0)) {
            uint256 companyWalletPart = _getPortionOfBid(payment, companyWalletPercentage);
            payment -= companyWalletPart;
            _safeTransferTo(companyWallet, companyWalletPart);
        }
        if (payment > 0) {
            _safeTransferTo(veArtAddress, payment);
        }
        salvors[_tokenId].level += amount;
    }

    function callbackRandomWord(uint256 _requestId, uint256[] calldata _randomWords) external {
        require(msg.sender == adminWallet, "Unauthorized user, only the adminWallet address is allowed");
        for (uint256 i; i<_randomWords.length; i++) {
            require(!vrfRequests[_requestId][i].handled, "Error: This request has already been handled.");
            uint256 randomWord = uint256(
                keccak256(
                    abi.encode(
                        _requestId,
                        tx.gasprice,
                        block.number,
                        block.timestamp,
                        block.difficulty,
                        blockhash(block.number - 1),
                        i,
                        _randomWords[i]
                    )
                )
            );
            vrfRequests[_requestId][i].randomWord = randomWord;
            vrfRequests[_requestId][i].handled = true;
        }
    }

    function getSalvorAttribute(uint256 _tokenId) external view returns (Salvor memory) {
        return salvors[_tokenId];
    }

    function getSalvorPower(uint256 _tokenId) public view returns (uint256) {
        Salvor memory salvor = salvors[_tokenId];
        return salvorPowers[salvor.rarityScore][salvor.level];
    }

    function _setRandomWord(uint256 _requestId, uint256 _index) internal {
        uint256 randomWord = uint256(
            keccak256(
                abi.encode(
                    _requestId,
                    msg.sender,
                    tx.gasprice,
                    block.number,
                    block.timestamp,
                    block.difficulty,
                    blockhash(block.number - 1),
                    _index,
                    address(this)
                )
            )
        );
        vrfRequests[_requestId][_index].randomWord = randomWord;
        vrfRequests[_requestId][_index].handled = true;
        vrfRequests[_requestId][_index].isOnChain = true;
    }

    function _getPortionOfBid(uint256 _totalBid, uint256 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    function _safeTransferTo(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        if (!success) {
            failedTransferBalance += _amount;
        }
    }
}
