// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../Royalty/Royalty.sol";
import "../Royalty/LibRoyalty.sol";

/// @title SalvorLaunchpad
/// @author Salvor
/// @notice Implements a simple minting NFT contract with an allowlist and public sale phase.
contract SalvorLaunchpad is ERC721, ERC721Enumerable, VRFConsumerBaseV2, Royalty, Ownable, Pausable, ReentrancyGuard {
	using Counters for Counters.Counter;
	using Strings for uint256;

	enum Phase {
		NotStarted,
		Allowlist,
		PublicSale,
		Ended
	}

	struct AddressData {
		// Realistically, 2**64-1 is more than enough.
		uint64 balance;
		// Keeps track of mint count with minimal overhead for tokenomics.
		uint64 numberMinted;
		// Keeps track of burn count with minimal overhead for tokenomics.
		uint64 numberBurned;
	}

	struct LaunchpadConfig {
		address projectOwner;
		address royaltyReceiver;
		uint256 maxPerAddressDuringMint;
		uint256 collectionSize;
		uint256 amountForAllowlist;
		uint256 amountForDevs;
	}

	struct Range {
		int128 start;
		int128 end;
	}


	Counters.Counter private _tokenIds;

	bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;

	/// @notice The collection size (e.g 10000)
	uint256 public collectionSize;

	/// @notice Amount of NFTs reserved for the project owner (e.g 200)
	/// @dev It can be minted any time via `devMint`
	uint256 public amountForDevs;

	/// @notice Amount of NFTs available for the allowlist mint (e.g 1000)
	uint256 public amountForAllowlist;

	/// @notice Max amount of NFTs an address can mint in public phases
	uint256 public maxPerAddressDuringMint;

	/// @notice The fees collected by Salvor on the sale benefits
	/// @dev In basis points e.g 100 for 1%
	uint256 public feePercent;

	/// @notice The address to which the fees on the sale will be sent
	address public feeCollector;

	/// @notice Batch reveal contract
	bool public isRevealingPhaseStarted;

	/// @notice Token URI after collection reveal
	string public baseURI;

	/// @notice Token URI before the collection reveal
	string public unrevealedURI;

	/// @notice The amount of NFTs each allowed address can mint during
	/// the pre-mint or allowlist mint
	mapping(address => uint256) public allowlist;

	/// @notice Tracks the amount of NFTs minted by `projectOwner`
	uint256 public amountMintedByDevs;

	/// @notice Tracks the amount of NFTs minted on Allowlist phase
	uint256 public amountMintedDuringAllowlist;

	/// @notice Tracks the amount of NFTs minted on Public Sale phase
	uint256 public amountMintedDuringPublicSale;

	/// @notice Start time of the allowlist mint in seconds
	uint256 public allowlistStartTime;

	/// @notice Start time of the public sale in seconds
	/// @dev A timestamp greater than the allowlist mint start
	uint256 public publicSaleStartTime;

	/// @notice End time of the public sale in seconds
	/// @dev A timestamp greater than the public sale start
	uint256 public publicSaleEndTime;

	/// @notice Price of one NFT for people on the mint list
	/// @dev allowlistPrice is scaled to 1e18
	uint256 public allowlistPrice;

	/// @notice Price of one NFT during the public sale
	/// @dev salePrice is scaled to 1e18
	uint256 public salePrice;

	address vrfCoordinator;

	// Mapping owner address to address data
	mapping(address => AddressData) private _addressData;

	/// @notice Size of the batch reveal
	/// @dev Must divide collectionSize
	uint256 revealBatchSize;

	/// @notice Timestamp for the start of the reveal process
	/// @dev Can be set to zero for immediate reveal after token mint
	uint256 revealStartTime;

	/// @notice Time interval for gradual reveal
	/// @dev Can be set to zero in order to reveal the collection all at once
	uint256 revealInterval;

	/// @notice Randomized seeds used to shuffle TokenURIs by launchpeg
	mapping(uint256 => uint256) public batchToSeed;

	/// @notice Last token that has been revealed by launchpeg
	uint256 public lastTokenReveal;

	/// @dev Size of the array that will store already taken URIs numbers by launchpeg
	uint256 public rangeLength;

	/// @notice Chainlink subscription ID
	uint64 public subscriptionId;

	/// @notice The gas lane to use, which specifies the maximum gas price to bump to.
	/// For a list of available gas lanes on each network,
	/// see https://docs.chain.link/docs/vrf-contracts/#configurations
	bytes32 public keyHash;

	/// @notice Depends on the number of requested values that you want sent to the
	/// fulfillRandomWords() function. Storing each word costs about 20,000 gas,
	/// so 100,000 is a safe default for this example contract. Test and adjust
	/// this limit based on the network that you select, the size of the request,
	/// and the processing of the callback request in the fulfillRandomWords()
	/// function.
	uint32 public callbackGasLimit;

	/// @notice Number of block confirmations that the coordinator will wait before triggering the callback
	/// The default is 3
	uint16 public constant requestConfirmations = 3;

	/// @notice Next batch that will be revealed by VRF (if activated) by launchpeg
	uint256 public nextBatchToReveal;

	/// @notice True when force revealed has been triggered for the given launchpeg
	/// @dev VRF will not be used anymore if a batch has been force revealed
	bool public hasBeenForceRevealed;

	/// @notice Has the random number for a batch already been asked by launchpeg
	/// @dev Prevents people from spamming the random words request
	/// and therefore reveal more batches than expected
	mapping(uint256 => bool) public vrfRequestedForBatch;

	event Reveal(uint256 batchNumber, uint256 batchSeed);
	event RevealBatchSizeSet(uint256 revealBatchSize);
	event RevealStartTimeSet(uint256 revealStartTime);
	event RevealIntervalSet(uint256 revealInterval);
	event VRFSet(address _vrfCoordinator, bytes32 _keyHash, uint64 _subscriptionId, uint32 _callbackGasLimit);
	event Initialized(uint256 allowlistStartTime, uint256 publicSaleStartTime, uint256 publicSaleEndTime, uint256 allowlistPrice, uint256 salePrice);
	event DevMint(address indexed sender, uint256 quantity);
	event Mint(address indexed sender, uint256 quantity, uint256 price, uint256 startTokenId, Phase phase);
	event AvaxWithdraw(address indexed sender, uint256 amount, uint256 fee);
	event BaseURISet(string baseURI);
	event UnrevealedURISet(string unrevealedURI);
	event AllowlistSeeded();
	event AllowlistStartTimeSet(uint256 allowlistStartTime);
	event PublicSaleStartTimeSet(uint256 publicSaleStartTime);
	event PublicSaleEndTimeSet(uint256 publicSaleEndTime);

	modifier isEOA() {
		require(tx.origin == msg.sender, "Unauthorized");
		_;
	}

	/// @notice Checks if the current phase matches the required phase
	modifier atPhase(Phase _phase) {
		require(currentPhase() == _phase, "WrongPhase");
		_;
	}

	/// @notice Phase time can be updated if it has been initialized and
	// the time has not passed
	modifier isTimeUpdateAllowed(uint256 _phaseTime) {
		if (_phaseTime == 0) {
			// revert Launchpeg__NotInitialized();
			require(false, "");
		}
		if (_phaseTime <= block.timestamp) {
			// revert Launchpeg__WrongPhase();
			require(false, "");
		}
		_;
	}

	/// @notice Checks if new time is equal to or after block timestamp
	modifier isNotBeforeBlockTimestamp(uint256 _newTime) {
		if (_newTime < block.timestamp) {
			// revert Launchpeg__InvalidPhases();
			require(false, "");
		}
		_;
	}

	constructor(
		string memory tokenName,
		string memory symbol,
		uint96 _feePercent,
		address _feeCollector,
		address _vrfCoordinator,
		LaunchpadConfig memory _launchpad,
		LibRoyalty.Royalty[] memory _defaultRoyalties
	)
	ERC721(tokenName, symbol)
	VRFConsumerBaseV2(_vrfCoordinator)
	Royalty(_defaultRoyalties, 2500) {
		if (_launchpad.collectionSize == 0 || ((_launchpad.amountForDevs + _launchpad.amountForAllowlist) > _launchpad.collectionSize)) {
			// revert Launchpeg__LargerCollectionSizeNeeded();
			require(false, "");
		}
		if (_launchpad.maxPerAddressDuringMint > _launchpad.collectionSize) {
			// revert Launchpeg__InvalidMaxPerAddressDuringMint();
			require(false, "");
		}

		setDefaultRoyaltyReceiver(_launchpad.royaltyReceiver);

		collectionSize = _launchpad.collectionSize;
		maxPerAddressDuringMint = _launchpad.maxPerAddressDuringMint;
		amountForDevs = _launchpad.amountForDevs;
		amountForAllowlist = _launchpad.amountForAllowlist;

		feePercent = _feePercent;
		feeCollector = _feeCollector;
	}

	/// @notice Set VRF configuration
	/// @param _vrfCoordinator Chainlink coordinator address
	/// @param _keyHash Keyhash of the gas lane wanted
	/// @param _subscriptionId Chainlink subscription ID
	/// @param _callbackGasLimit Max gas used by the coordinator callback
	function setVRF(address _vrfCoordinator, bytes32 _keyHash, uint64 _subscriptionId, uint32 _callbackGasLimit) external onlyOwner {
		if (_vrfCoordinator == address(0)) {
			// revert Launchpeg__InvalidCoordinator();
			require(false, "");
		}

		(,uint32 _maxGasLimit,bytes32[] memory s_provingKeyHashes) = VRFCoordinatorV2Interface(_vrfCoordinator).getRequestConfig();

		// 20_000 is the cost of storing one word, callback cost will never be lower than that
		if (_callbackGasLimit > _maxGasLimit || _callbackGasLimit < 20_000) {
			// revert Launchpeg__InvalidCallbackGasLimit();
			require(false, "");
		}

		bool keyHashFound;
		for (uint256 i; i < s_provingKeyHashes.length; i++) {
			if (s_provingKeyHashes[i] == _keyHash) {
				keyHashFound = true;
				break;
			}
		}

		if (!keyHashFound) {
			// revert Launchpeg__InvalidKeyHash();
			require(false, "");
		}

		(, , , address[] memory consumers) = VRFCoordinatorV2Interface(_vrfCoordinator).getSubscription(_subscriptionId);

		bool isInConsumerList;
		for (uint256 i; i < consumers.length; i++) {
			if (consumers[i] == address(this)) {
				isInConsumerList = true;
				break;
			}
		}

		if (!isInConsumerList) {
			// revert Launchpeg__IsNotInTheConsumerList();
			require(false, "");
		}
		keyHash = _keyHash;
		subscriptionId = _subscriptionId;
		callbackGasLimit = _callbackGasLimit;
		vrfCoordinator = _vrfCoordinator;

		emit VRFSet(_vrfCoordinator, _keyHash, _subscriptionId, _callbackGasLimit);
	}


	/**
	* @notice allows the contract owner to update the default royalty receiver.
    * defaultRoyaltyReceiver specifies the royalty receiver for the platforms that supports only single royalty receiver.
    * @param _defaultRoyaltyReceiver royalty receiver address
    */
	function setDefaultRoyaltyReceiver(address _defaultRoyaltyReceiver) public override onlyOwner {
		_setDefaultRoyaltyReceiver(_defaultRoyaltyReceiver);
	}

	/**
	* @notice allows the contract owner to update the default royalties that includes multi royalty information.
    * The contract owner can apply default royalties to all nft’s that don’t include any royalty specifically.
    * Total amount of royalty percentages cannot be higher than %25.
    * @param _defaultRoyalties list of the royalties that contains percentages for each account
    */
	function setDefaultRoyalties(LibRoyalty.Royalty[] memory _defaultRoyalties) external override onlyOwner {
		_setDefaultRoyalties(_defaultRoyalties);
	}

	/**
	* @notice allows the contract owner to update the royalties for a specific nft.
    * Total amount of royalty percentages cannot be higher than %25.
    * @param _tokenId nft tokenId
    * @param _royalties list of the royalties that contains percentages for each account
    */
	function saveRoyalties(uint256 _tokenId, LibRoyalty.Royalty[] memory _royalties) external override onlyOwner {
		require(ownerOf(_tokenId) == owner(), "token does not belongs to contract owner");
		_saveRoyalties(_tokenId, _royalties);
	}

	/// @notice Initialize the two phases of the sale
	/// @dev Can only be called once
	/// @param _allowlistStartTime Allowlist mint start time in seconds
	/// @param _publicSaleStartTime Public sale start time in seconds
	/// @param _publicSaleEndTime Public sale end time in seconds
	/// @param _allowlistPrice Price of the allowlist sale in Avax
	/// @param _salePrice Price of the public sale in Avax
	function initializePhases(
		uint256 _allowlistStartTime,
		uint256 _publicSaleStartTime,
		uint256 _publicSaleEndTime,
		uint256 _allowlistPrice,
		uint256 _salePrice
	) external onlyOwner atPhase(Phase.NotStarted) {
		if (
			_allowlistStartTime < block.timestamp ||
			_publicSaleStartTime < _allowlistStartTime ||
			_publicSaleEndTime < _publicSaleStartTime
		) {
			// revert Launchpeg__InvalidPhases();
			require(false, "");
		}

		if (_allowlistPrice > _salePrice) {
			// revert Launchpeg__InvalidAllowlistPrice();
			require(false, "");
		}

		salePrice = _salePrice;
		allowlistPrice = _allowlistPrice;

		allowlistStartTime = _allowlistStartTime;
		publicSaleStartTime = _publicSaleStartTime;
		publicSaleEndTime = _publicSaleEndTime;

		emit Initialized(
			allowlistStartTime,
			publicSaleStartTime,
			publicSaleEndTime,
			allowlistPrice,
			salePrice
		);
	}

	/// @notice Initialize batch reveal. Leave undefined to disable
	/// batch reveal for the collection.
	/// @dev Can only be set once. Cannot be initialized once sale has ended.
	function initializeBatchReveal() external onlyOwner {
		if (isRevealingPhaseStarted) {
			// revert Launchpeg__BatchRevealAlreadyInitialized();
			require(false, "");
		}
		// Disable once sale has ended
		if (publicSaleEndTime > 0 && block.timestamp >= publicSaleEndTime) {
			// revert Launchpeg__WrongPhase();
			require(false, "");
		}
		isRevealingPhaseStarted = true;
	}

	/// @notice Set amount of NFTs mintable per address during the allowlist phase
	/// @param _addresses List of addresses allowed to mint during the allowlist phase
	/// @param _numNfts List of NFT quantities mintable per address
	function seedAllowlist(
		address[] calldata _addresses,
		uint256[] calldata _numNfts
	) external onlyOwner {
		uint256 addressesLength = _addresses.length;
		if (addressesLength != _numNfts.length) {
			// revert Launchpeg__WrongAddressesAndNumSlotsLength();
			require(false, "");
		}
		for (uint256 i; i < addressesLength; i++) {
			allowlist[_addresses[i]] = _numNfts[i];
		}

		emit AllowlistSeeded();
	}

	/// @notice Set the base URI
	/// @dev This sets the URI for revealed tokens
	/// Only callable by project owner
	/// @param _baseURI Base URI to be set
	function setBaseURI(string calldata _baseURI) external onlyOwner {
		baseURI = _baseURI;
		emit BaseURISet(baseURI);
	}

	/// @notice Set the unrevealed URI
	/// @dev Only callable by project owner
	/// @param _unrevealedURI Unrevealed URI to be set
	function setUnrevealedURI(string calldata _unrevealedURI)
	external
	onlyOwner
	{
		unrevealedURI = _unrevealedURI;
		emit UnrevealedURISet(unrevealedURI);
	}

	/// @notice Set the allowlist start time. Can only be set after phases
	/// have been initialized.
	/// @dev Only callable by owner
	/// @param _allowlistStartTime New allowlist start time
	function setAllowlistStartTime(uint256 _allowlistStartTime)
	external
	onlyOwner
	isTimeUpdateAllowed(allowlistStartTime)
	isNotBeforeBlockTimestamp(_allowlistStartTime)
	{
		if (
			publicSaleStartTime < _allowlistStartTime
		) {
			// revert Launchpeg__InvalidPhases();
			require(false, "");
		}
		allowlistStartTime = _allowlistStartTime;
		emit AllowlistStartTimeSet(_allowlistStartTime);
	}

	/// @notice Set the public sale start time. Can only be set after phases
	/// have been initialized.
	/// @dev Only callable by owner
	/// @param _publicSaleStartTime New public sale start time
	function setPublicSaleStartTime(uint256 _publicSaleStartTime)
		external
		onlyOwner
		isTimeUpdateAllowed(publicSaleStartTime)
		isNotBeforeBlockTimestamp(_publicSaleStartTime)
	{
		if (
			_publicSaleStartTime < allowlistStartTime ||
			publicSaleEndTime < _publicSaleStartTime
		) {
			// revert Launchpeg__InvalidPhases();
			require(false, "");
		}

		publicSaleStartTime = _publicSaleStartTime;
		emit PublicSaleStartTimeSet(_publicSaleStartTime);
	}

	/// @notice Set the public sale end time. Can only be set after phases
	/// have been initialized.
	/// @dev Only callable by owner
	/// @param _publicSaleEndTime New public sale end time
	function setPublicSaleEndTime(uint256 _publicSaleEndTime)
		external
		onlyOwner
		isTimeUpdateAllowed(publicSaleEndTime)
		isNotBeforeBlockTimestamp(_publicSaleEndTime)
	{
		if (_publicSaleEndTime < publicSaleStartTime) {
			// revert Launchpeg__InvalidPhases();
			require(false, "");
		}
		publicSaleEndTime = _publicSaleEndTime;
		emit PublicSaleEndTimeSet(_publicSaleEndTime);
	}

	/// @notice Returns the current phase
	/// @return phase Current phase
	function currentPhase() public view returns (Phase) {
		if (
			allowlistStartTime == 0 ||
			publicSaleStartTime == 0 ||
			publicSaleEndTime == 0 ||
			block.timestamp < allowlistStartTime
		) {
			return Phase.NotStarted;
		} else if (totalSupply() >= collectionSize) {
			return Phase.Ended;
		} else if (
			block.timestamp >= allowlistStartTime &&
			block.timestamp < publicSaleStartTime
		) {
			return Phase.Allowlist;
		} else if (
			block.timestamp >= publicSaleStartTime &&
			block.timestamp < publicSaleEndTime
		) {
			return Phase.PublicSale;
		}
		return Phase.Ended;
	}

	/// @notice Mint NFTs to the project owner
	/// @dev Can only mint up to `amountForDevs`
	/// @param _quantity Quantity of NFTs to mint
	function devMint(uint256 _quantity) external whenNotPaused {
		if (totalSupply() + _quantity > collectionSize) {
			// revert Launchpeg__MaxSupplyReached();
			require(false, "");
		}
		if (amountMintedByDevs + _quantity > amountForDevs) {
			// revert Launchpeg__MaxSupplyForDevReached();
			require(false, "");
		}
		amountMintedByDevs = amountMintedByDevs + _quantity;
		_batchMint(msg.sender, _quantity, maxPerAddressDuringMint);
		emit DevMint(msg.sender, _quantity);
	}

	/// @notice Mint NFTs during the allowlist mint
	/// @param _quantity Quantity of NFTs to mint
	function allowlistMint(uint256 _quantity) external payable whenNotPaused atPhase(Phase.Allowlist) {
		if (_quantity > allowlist[msg.sender]) {
			// revert Launchpeg__NotEligibleForAllowlistMint();
			require(false, "");
		}
		if ((amountMintedDuringAllowlist + _quantity) > amountForAllowlist) {
			// revert Launchpeg__MaxSupplyReached();
			require(false, "");
		}
		allowlist[msg.sender] -= _quantity;
		uint256 price = allowlistPrice;
		uint256 totalCost = price * _quantity;

		_batchMint(msg.sender, _quantity, maxPerAddressDuringMint);
		amountMintedDuringAllowlist += _quantity;
		emit Mint(
			msg.sender,
			_quantity,
			price,
			_totalMinted() - _quantity,
			Phase.Allowlist
		);
		_refundIfOver(totalCost);
	}

	/// @notice Mint NFTs during the public sale
	/// @param _quantity Quantity of NFTs to mint
	function publicSaleMint(uint256 _quantity) external payable isEOA whenNotPaused atPhase(Phase.PublicSale) {
		if (numberMinted(msg.sender) + _quantity > maxPerAddressDuringMint) {
			// revert Launchpeg__CanNotMintThisMany();
			require(false, "");
		}
		// ensure sufficient supply for devs. note we can skip this check
		// in prior phases as long as they do not exceed the phase allocation
		// and the total phase allocations do not exceed collection size
		uint256 remainingDevAmt = amountForDevs - amountMintedByDevs;
		if ((totalSupply() + remainingDevAmt + _quantity) > collectionSize) {
			// revert Launchpeg__MaxSupplyReached();
			require(false, "");
		}
		uint256 price = salePrice;
		uint256 total = price * _quantity;

		mint(msg.sender, _quantity);


		amountMintedDuringPublicSale += _quantity;
		emit Mint(msg.sender, _quantity, price, _totalMinted() - _quantity, Phase.PublicSale);
		_refundIfOver(total);
	}

	/// @notice Withdraw AVAX to the given recipient
	/// @param _to Recipient of the earned AVAX
	function withdrawAVAX(address _to) external nonReentrant whenNotPaused {
		uint256 amount = address(this).balance;
		uint256 fee;
		bool sent;

		if (feePercent > 0) {
			fee = (amount * feePercent) / 10000;
			amount = amount - fee;

			(sent, ) = feeCollector.call{value: fee}("");
			if (!sent) {
				// revert Launchpeg__TransferFailed();
				require(false, "");
			}
		}

		(sent, ) = _to.call{value: amount}("");
		if (!sent) {
			// revert Launchpeg__TransferFailed();
			require(false, "");
		}

		emit AvaxWithdraw(_to, amount, fee);
	}

	/// @notice Returns the Uniform Resource Identifier (URI) for `tokenId` token.
	/// @param _id Token id
	/// @return URI Token URI
	function tokenURI(uint256 _id) public view override(ERC721) returns (string memory) {
		if (_id >= lastTokenReveal) {
			return unrevealedURI;
		} else {
			return
			string(
				abi.encodePacked(baseURI, getShuffledTokenId(_id).toString(), "")
			);
		}
	}

	/// @notice Returns the number of NFTs minted by a specific address
	/// @param _owner The owner of the NFTs
	/// @return numberMinted Number of NFTs minted
	function numberMinted(address _owner) public view returns (uint256) {
		return uint256(_addressData[_owner].numberMinted);
	}

	/// @dev Returns true if this contract implements the interface defined by
	/// `interfaceId`. See the corresponding
	/// https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
	/// to learn more about how these IDs are created.
	/// This function call must use less than 30 000 gas.
	/// @param _interfaceId InterfaceId to consider. Comes from type(InterfaceContract).interfaceId
	/// @return isInterfaceSupported True if the considered interface is supported
	function supportsInterface(bytes4 _interfaceId)
		public
		view
		virtual
		override(ERC721, ERC721Enumerable, Royalty)
		returns (bool)
	{
		if (_interfaceId == _INTERFACE_ID_EIP2981) {
			return true;
		}
		return ERC721.supportsInterface(_interfaceId) || super.supportsInterface(_interfaceId);
	}

	/// @dev Verifies that enough AVAX has been sent by the sender and refunds the extra tokens if any
	/// @param _price The price paid by the sender for minting NFTs
	function _refundIfOver(uint256 _price) internal {
		if (msg.value < _price) {
			// revert Launchpeg__NotEnoughAVAX(msg.value);
			require(false, "");
		}
		if (msg.value > _price) {
			(bool success, ) = msg.sender.call{value: msg.value - _price}("");
			if (!success) {
				// revert Launchpeg__TransferFailed();
				require(false, "");
			}
		}
	}

	/// @dev Mint in batches of up to `_maxBatchSize`. Used to control
	/// gas costs for subsequent transfers in ERC721A contracts.
	/// @param _sender address to mint NFTs to
	/// @param _quantity No. of NFTs to mint
	/// @param _maxBatchSize Max no. of NFTs to mint in a batch
	function _batchMint(address _sender, uint256 _quantity, uint256 _maxBatchSize) private {
		uint256 numChunks = _quantity / _maxBatchSize;
		for (uint256 i; i < numChunks; ++i) {
			mint(_sender, _maxBatchSize);
		}
		uint256 remainingQty = _quantity % _maxBatchSize;
		if (remainingQty != 0) {
			mint(_sender, remainingQty);
		}
	}

	function mint(address _to, uint256 _quantity) internal {
		_addressData[_to].balance += uint64(_quantity);
		_addressData[_to].numberMinted += uint64(_quantity);

		uint256 updatedIndex = _tokenIds.current();
		uint256 end = updatedIndex + _quantity;
		do {
			++updatedIndex;
			_tokenIds.increment();
			_mint(_to, _tokenIds.current());
		} while (updatedIndex != end);
	}

	/**
	* Returns the total amount of tokens minted in the contract.
	*/
	function _totalMinted() internal view returns (uint256) {
		return _tokenIds.current();
	}

	function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override(ERC721, ERC721Enumerable) {
		super._beforeTokenTransfer(from, to, tokenId);
	}

	/// @dev Verify that batch reveal is configured for the given launchpeg
	modifier batchRevealInitialized() {
		if (!isRevealingPhaseStarted) {
			// revert Launchpeg__BatchRevealNotInitialized();
			require(false, "");
		}
		_;
	}

	/// @dev Verify that batch reveal hasn't started for the given launchpeg
	modifier revealNotStarted() {
		if (lastTokenReveal != 0) {
			// revert Launchpeg__BatchRevealStarted();
			require(false, "");
		}
		_;
	}

	/// @dev Configure batch reveal for a given launch
	/// @param _revealBatchSize Size of the batch reveal
	/// @param _revealStartTime Batch reveal start time
	/// @param _revealInterval Batch reveal interval
	function configure(uint256 _revealBatchSize, uint256 _revealStartTime, uint256 _revealInterval) external onlyOwner revealNotStarted() {
		_setRevealBatchSize(_revealBatchSize);
		_setRevealStartTime(_revealStartTime);
		_setRevealInterval(_revealInterval);
	}

	/// @notice Set the reveal batch size. Can only be set after
	/// batch reveal has been initialized and before a batch has
	/// been revealed.
	/// @param _revealBatchSize New reveal batch size
	function setRevealBatchSize(uint256 _revealBatchSize) public onlyOwner batchRevealInitialized() revealNotStarted() {
		_setRevealBatchSize(_revealBatchSize);
	}

	/// @notice Set the reveal batch size
	/// @param _revealBatchSize New reveal batch size
	function _setRevealBatchSize(uint256 _revealBatchSize) internal {
		if (_revealBatchSize == 0) {
			// revert Launchpeg__InvalidBatchRevealSize();
			require(false, "");
		}
		if (collectionSize % _revealBatchSize != 0 || _revealBatchSize > collectionSize) {
			// revert Launchpeg__InvalidBatchRevealSize();
			require(false, "");
		}
		rangeLength = (collectionSize / _revealBatchSize) * 2;
		revealBatchSize = _revealBatchSize;
		emit RevealBatchSizeSet(_revealBatchSize);
	}

	/// @notice Set the batch reveal start time. Can only be set after
	/// batch reveal has been initialized and before a batch has
	/// been revealed.
	/// @param _revealStartTime New batch reveal start time
	function setRevealStartTime(uint256 _revealStartTime) public onlyOwner batchRevealInitialized() revealNotStarted() {
		_setRevealStartTime(_revealStartTime);
	}

	/// @notice Set the batch reveal start time.
	/// @param _revealStartTime New batch reveal start time
	function _setRevealStartTime(uint256 _revealStartTime) internal {
		// probably a mistake if the reveal is more than 100 days in the future
		if (_revealStartTime > block.timestamp + 8_640_000) {
			// revert Launchpeg__InvalidRevealDates();
			require(false, "");
		}
		revealStartTime = _revealStartTime;
		emit RevealStartTimeSet(_revealStartTime);
	}

	/// @notice Set the batch reveal interval. Can only be set after
	/// batch reveal has been initialized and before a batch has
	/// been revealed.
	/// @param _revealInterval New batch reveal interval
	function setRevealInterval(uint256 _revealInterval) public onlyOwner batchRevealInitialized() revealNotStarted() {
		_setRevealInterval(_revealInterval);
	}

	/// @notice Set the batch reveal interval.
	/// @param _revealInterval New batch reveal interval
	function _setRevealInterval(uint256 _revealInterval) internal {
		// probably a mistake if reveal interval is longer than 10 days
		if (_revealInterval > 864_000) {
			// revert Launchpeg__InvalidRevealDates();
			require(false, "");
		}
		revealInterval = _revealInterval;
		emit RevealIntervalSet(_revealInterval);
	}

	// Forked from openzeppelin
	/// @dev Returns the smallest of two numbers.
	/// @param _a First number to consider
	/// @param _b Second number to consider
	/// @return min Minimum between the two params
	function _min(int128 _a, int128 _b) internal pure returns (int128) {
		return _a < _b ? _a : _b;
	}

	/// @notice Fills the range array
	/// @dev Ranges include the start but not the end [start, end)
	/// @param _ranges initial range array
	/// @param _start beginning of the array to be added
	/// @param _end end of the array to be added
	/// @param _lastIndex last position in the range array to consider
	/// @param _intCollectionSize collection size
	/// @return newLastIndex new lastIndex to consider for the future range to be added
	function _addRange(
		Range[] memory _ranges,
		int128 _start,
		int128 _end,
		uint256 _lastIndex,
		int128 _intCollectionSize
	) private view returns (uint256) {
		uint256 positionToAssume = _lastIndex;
		for (uint256 j; j < _lastIndex; j++) {
			int128 rangeStart = _ranges[j].start;
			int128 rangeEnd = _ranges[j].end;
			if (_start < rangeStart && positionToAssume == _lastIndex) {
				positionToAssume = j;
			}
			if (
				(_start < rangeStart && _end > rangeStart) ||
				(rangeStart <= _start && _end <= rangeEnd) ||
				(_start < rangeEnd && _end > rangeEnd)
			) {
				int128 length = _end - _start;
				_start = _min(_start, rangeStart);
				_end = _start + length + (rangeEnd - rangeStart);
				_ranges[j] = Range(-1, -1); // Delete
			}
		}
		for (uint256 pos = _lastIndex; pos > positionToAssume; pos--) {
			_ranges[pos] = _ranges[pos - 1];
		}
		_ranges[positionToAssume] = Range(
			_start,
			_min(_end, _intCollectionSize)
		);
		_lastIndex++;
		if (_end > _intCollectionSize) {
			_addRange(
				_ranges,
				0,
				_end - _intCollectionSize,
				_lastIndex,
				_intCollectionSize
			);
			_lastIndex++;
		}
		return _lastIndex;
	}

	/// @dev Adds the last batch into the ranges array
	/// @param _lastBatch Batch number to consider
	/// @param _revealBatchSize Reveal batch size
	/// @param _intCollectionSize Collection size
	/// @param _rangeLength Range length
	/// @return ranges Ranges array filled with every URI taken by batches smaller or equal to lastBatch
	function _buildJumps(
		uint256 _lastBatch,
		uint256 _revealBatchSize,
		int128 _intCollectionSize,
		uint256 _rangeLength
	) private view returns (Range[] memory) {
		Range[] memory ranges = new Range[](_rangeLength);
		uint256 lastIndex;
		for (uint256 i; i < _lastBatch; i++) {
			int128 start = int128(int256(_getFreeTokenId(batchToSeed[i], ranges, _intCollectionSize)));
			int128 end = start + int128(int256(_revealBatchSize));
			lastIndex = _addRange(
				ranges,
				start,
				end,
				lastIndex,
				_intCollectionSize
			);
		}
		return ranges;
	}

	/// @dev Gets the random token URI number from tokenId
	/// @param _startId Token Id to consider
	/// @return uriId Revealed Token URI Id
	function getShuffledTokenId(uint256 _startId) internal view returns (uint256) {
		uint256 batch = _startId / revealBatchSize;
		Range[] memory ranges = new Range[](rangeLength);
		int128 intCollectionSize = int128(int256(collectionSize));

		ranges = _buildJumps(batch, revealBatchSize, intCollectionSize, rangeLength);

		uint256 positionsToMove = (_startId % revealBatchSize) +
		batchToSeed[batch];

		return _getFreeTokenId(positionsToMove, ranges, intCollectionSize);
	}


	/// @dev Gets the shifted URI number from tokenId and range array
	/// @param _positionsToMoveStart Token URI offset if none of the URI Ids were taken
	/// @param _ranges Ranges array built by _buildJumps()
	/// @param _intCollectionSize Collection size
	/// @return uriId Revealed Token URI Id
	function _getFreeTokenId(uint256 _positionsToMoveStart, Range[] memory _ranges, int128 _intCollectionSize) private view returns (uint256) {
		int128 positionsToMove = int128(int256(_positionsToMoveStart));
		int128 id;

		for (uint256 round = 0; round < 2; round++) {
			for (uint256 i; i < rangeLength; i++) {
				int128 start = _ranges[i].start;
				int128 end = _ranges[i].end;
				if (id < start) {
					int128 finalId = id + positionsToMove;
					if (finalId < start) {
						return uint256(uint128(finalId));
					} else {
						positionsToMove -= start - id;
						id = end;
					}
				} else if (id < end) {
					id = end;
				}
			}
			if ((id + positionsToMove) >= _intCollectionSize) {
				positionsToMove -= _intCollectionSize - id;
				id = 0;
			}
		}
		return uint256(uint128(id + positionsToMove));
	}

	/// @dev Sets batch seed for specified batch number
	/// @param _batchNumber Batch number that needs to be revealed
	/// @param _collectionSize Collection size
	/// @param _revealBatchSize Reveal batch size
	function _setBatchSeed(uint256 _batchNumber, uint256 _collectionSize, uint256 _revealBatchSize) internal {
		uint256 randomness = uint256(
			keccak256(
				abi.encode(
					msg.sender,
					tx.gasprice,
					block.number,
					block.timestamp,
					block.difficulty,
					blockhash(block.number - 1),
					address(this)
				)
			)
		);

		// not perfectly random since the folding doesn't match bounds perfectly, but difference is small
		batchToSeed[_batchNumber] = randomness % (_collectionSize - (_batchNumber * _revealBatchSize));
	}

	/// @dev Returns true if a batch can be revealed
	/// @param _totalSupply Number of token already minted
	/// @return hasToRevealInfo Returns a bool saying whether a reveal can be triggered or not
	/// and the number of the next batch that will be revealed
	function hasBatchToReveal(uint256 _totalSupply) public view returns (bool, uint256) {
		uint256 lastTokenRevealed = lastTokenReveal;
		uint256 batchNumber = lastTokenRevealed / revealBatchSize;

		// We don't want to reveal other batches if a VRF random words request is pending
		if (
			block.timestamp < (revealStartTime + batchNumber * revealInterval) ||
			_totalSupply < lastTokenRevealed + revealBatchSize ||
			vrfRequestedForBatch[batchNumber]
		) {
			return (false, batchNumber);
		}

		return (true, batchNumber);
	}

	/// @dev Reveals next batch if possible
	/// @dev If using VRF, the reveal happens on the coordinator callback call
	/// @param _totalSupply Number of token already minted
	function revealNextBatch(uint256 _totalSupply) external isEOA whenNotPaused {

		uint256 batchNumber;
		bool canReveal;
		(canReveal, batchNumber) = hasBatchToReveal(_totalSupply);

		if (!canReveal) {
			// revert Launchpeg__RevealNextBatchNotAvailable();
			require(false, "");
		}

		VRFCoordinatorV2Interface(vrfCoordinator)
			.requestRandomWords(keyHash, subscriptionId, requestConfirmations, callbackGasLimit, 1);
		vrfRequestedForBatch[batchNumber] = true;
	}

	/// @dev Callback triggered by the VRF coordinator
	/// @param _randomWords Array of random numbers provided by the VRF coordinator
	function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
		if (hasBeenForceRevealed) {
			// revert Launchpeg__HasBeenForceRevealed();
			require(false, "");
		}

		uint256 _batchToReveal = nextBatchToReveal++;
		uint256 _revealBatchSize = revealBatchSize;
		uint256 _seed = _randomWords[0] %
		(collectionSize - (_batchToReveal * _revealBatchSize));

		batchToSeed[_batchToReveal] = _seed;
		lastTokenReveal += _revealBatchSize;

		emit Reveal(_batchToReveal, batchToSeed[_batchToReveal]);
	}

	/// @dev Force reveal, should be restricted to owner
	function forceReveal() external onlyOwner {
		uint256 batchNumber;
		unchecked {
			batchNumber = lastTokenReveal / revealBatchSize;
			lastTokenReveal += revealBatchSize;
		}

		_setBatchSeed(batchNumber, collectionSize, revealBatchSize);
		hasBeenForceRevealed = true;
		emit Reveal(batchNumber, batchToSeed[batchNumber]);
	}
}