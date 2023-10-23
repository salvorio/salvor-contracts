// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "../SalvorOperator/ISalvorOperator.sol";


contract VRFCoordinator is VRFConsumerBaseV2, Ownable, Pausable {
	using EnumerableSet for EnumerableSet.AddressSet;

	struct VRFRequest {
		bool requested;
		bool handled;
		address platform;
		uint256 randomWord;
	}
	address vrfCoordinator;
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
	mapping(uint256 => VRFRequest) public vrfRequests;

	EnumerableSet.AddressSet private adminPlatforms;



	event VRFSet(address _vrfCoordinator, bytes32 _keyHash, uint64 _subscriptionId, uint32 _callbackGasLimit);
	event PlatformAdded(address indexed platform);
	event PlatformRemoved(address indexed platform);

	constructor(address _vrfCoordinator) VRFConsumerBaseV2(_vrfCoordinator){}

	function addAdminPlatform(address _platform) external onlyOwner {
		require(!adminPlatforms.contains(_platform), "already added");
		adminPlatforms.add(_platform);
		emit PlatformAdded(_platform);
	}

	function removeAdminPlatform(address _platform) external onlyOwner {
		require(adminPlatforms.contains(_platform), "not added");
		adminPlatforms.remove(_platform);
		emit PlatformRemoved(_platform);
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

	function requestRandomWords(uint32 _amount) external returns (uint256) {
		require(adminPlatforms.contains(msg.sender), "Only the admin contract can operate");
		uint256 requestId = VRFCoordinatorV2Interface(vrfCoordinator).requestRandomWords(keyHash, subscriptionId, requestConfirmations, callbackGasLimit, _amount);
		vrfRequests[requestId].requested = true;
		vrfRequests[requestId].platform = msg.sender;
		return requestId;
	}

	/// @dev Callback triggered by the VRF coordinator
	/// @param _randomWords Array of random numbers provided by the VRF coordinator
	function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
		ISalvorOperator(vrfRequests[_requestId].platform).callbackRandomWord(_requestId, _randomWords);
	}
}
