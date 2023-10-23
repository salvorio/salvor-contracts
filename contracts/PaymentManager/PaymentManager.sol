//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "../Royalty/IRoyalty.sol";
import "../NFTCollectible/INFTCollectible.sol";
import "../Royalty/LibRoyalty.sol";
import "../libs/LibShareholder.sol";

/**
* @title PaymentManager
* @notice PaymentManager is a payment protocol that manages the payments.
* Every marketplace contract (auctions and marketplace) requests the PaymentManager to transfer commissions,
* royalties and revenue shares.
* Only allowed contracts can reach the PaymentManager.
* And also the contract address must be set on every marketplace contract as a paymentManager address.
*/
contract PaymentManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    struct CollectionRoyalty {
        bool isEnabled;
        address receiver;
        uint96 percentage;
    }
    bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;
    /**
    * @notice allows the whitelisted contracts to run payout.
    */
    EnumerableSetUpgradeable.AddressSet private _whitelistedPlatforms;

    /**
    * @notice failed transfer amounts for each account are accumulated in this mapping.
    * e.g failedTransferBalance[bidder_address] = failed_balance;
    */
    mapping(address => uint256) public failedTransferBalance;

    /**
    * @notice the commission rate.
    */
    uint96 public commissionPercentage;

    /**
    * @notice the address that commission amounts will be transferred.
    */
    address payable public companyWallet;

    /**
    * @notice Restricts the maximum number of sharers
    */
    uint256 public maximumShareholdersLimit;

    /**
    * @notice Restricts the maximum number of royalty receivers
    */
    uint256 public maximumRoyaltyReceiversLimit;


    address payable public veARTAddress;

    // The percentage of income to be allocated to veART contract.
    uint96 public veARTPercentage;

    mapping(address => CollectionRoyalty) public collectionRoyalties;

    event RoyaltyReceived(address indexed collection, uint256 indexed tokenId, address _seller, address indexed royaltyReceiver, uint256 amount);
    event ShareReceived(address indexed collection, uint256 indexed tokenId, address _seller, address indexed shareReceiver, uint256 amount);
    event FailedTransfer(address indexed receiver, uint256 amount);
    event WithdrawnFailedBalance(uint256 amount);
    event CompanyWalletSet(address indexed companyWalletset);
    event CommissionPercentageSet(uint96 commissionPercentage);
    event MaximumRoyaltyReceiversLimitSet(uint256 maximumRoyaltyReceiversLimit);
    event MaximumShareholdersLimitSet(uint256 maximumShareholdersLimit);
    event PlatformAdded(address indexed platform);
    event PlatformRemoved(address indexed platform);
    event CommissionSent(address indexed collection, uint256 indexed tokenId, address _seller, uint256 commission, uint256 _price);
    event PayoutCompleted(address indexed collection, uint256 indexed tokenId, address indexed _seller, uint256 _price);
    event SetVeARTPercentage(uint96 _veARTPercentage);
    event SetVeARTAddress(address indexed veARTAddress);
    event SetCollectionRoyalty(address indexed collection, address indexed receiver, uint96 percentage, bool isEnabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize() public initializer {
        __Ownable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __Pausable_init_unchained();
        maximumShareholdersLimit = 5;
        maximumRoyaltyReceiversLimit = 5;
    }

    /**
    * @notice sets the percentage of income to be allocated to the veART contract
    * @param _veARTPercentage The percentage of income to be allocated to veART contract.
    */
    function setVeARTCommissionPercentage(uint96 _veARTPercentage) external onlyOwner {
        veARTPercentage = _veARTPercentage;
        emit SetVeARTPercentage(_veARTPercentage);
    }

    /**
    * @notice sets the percentage of income to be allocated to the veART contract
    * @param _address The percentage of income to be allocated to veART contract.
    */
    function setVeARTAddress(address _address) external onlyOwner {
        veARTAddress = payable(_address);
        emit SetVeARTAddress(_address);
    }

    /**
    * @notice Sets the royalty percentage and status for a specific collection address.
    * @param _address The address of the collection to set the royalty for.
    * @param _percentage The percentage of royalties to be set for the collection.
    * @param _isEnabled The status of the royalty to be set for the collection.
    */
    function setCollectionRoyalty(address _address, address _receiver, uint96 _percentage, bool _isEnabled) external onlyOwner {
        CollectionRoyalty memory collectionRoyalty = collectionRoyalties[_address];
        collectionRoyalty.percentage = _percentage;
        collectionRoyalty.isEnabled = _isEnabled;
        collectionRoyalty.receiver = _receiver;
        collectionRoyalties[_address] = collectionRoyalty;
        emit SetCollectionRoyalty(_address, _receiver, _percentage, _isEnabled);
    }

    /**
    * @notice adds a platform to use critical functions like 'payout'
    * @param _platform related marketplace contract address
    */
    function addPlatform(address _platform) external onlyOwner {
        require(!_whitelistedPlatforms.contains(_platform), "already whitelisted");
        _whitelistedPlatforms.add(_platform);
        emit PlatformAdded(_platform);
    }

    /**
    * @notice allows the owner to remove a contract address to restrict the payout method.
    * @param _platform related marketplace contract address
    */
    function removePlatform(address _platform) external onlyOwner {
        require(_whitelistedPlatforms.contains(_platform), "not whitelisted");
        _whitelistedPlatforms.remove(_platform);
        emit PlatformRemoved(_platform);
    }

    /**
    * @notice allows the owner to set a commission receiver address.
    * @param _companyWallet wallet address
    */
    function setCompanyWallet(address payable _companyWallet) external onlyOwner {
        companyWallet = _companyWallet;
        emit CompanyWalletSet(_companyWallet);
    }

    /**
    * @notice Allows the owner to change maximumRoyaltyReceiversLimit.
    * @param _maximumRoyaltyReceiversLimit royalty receivers limit
    */
    function setMaximumRoyaltyReceiversLimit(uint256 _maximumRoyaltyReceiversLimit) external onlyOwner {
        maximumRoyaltyReceiversLimit = _maximumRoyaltyReceiversLimit;
        emit MaximumRoyaltyReceiversLimitSet(_maximumRoyaltyReceiversLimit);
    }

    /**
    * @notice Allows the owner to change maximumShareholdersLimit.
    * @param _maximumShareholdersLimit shareholders limit
    */
    function setMaximumShareholdersLimit(uint256 _maximumShareholdersLimit) external onlyOwner {
        maximumShareholdersLimit = _maximumShareholdersLimit;
        emit MaximumShareholdersLimitSet(_maximumShareholdersLimit);
    }

    /**
    * @notice Allows the owner to change commission rates.
    * @param _commissionPercentage commission percentage
    */
    function setCommissionPercentage(uint96 _commissionPercentage) external onlyOwner {
        commissionPercentage = _commissionPercentage;
        emit CommissionPercentageSet(_commissionPercentage);
    }

    /**
    * @notice returns commission percentage
    */
    function getCommissionPercentage() external view returns(uint96) {
        return commissionPercentage;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
    * @notice process the payment for the allowed requests. Process is completed in 3 steps; commission transfer, royalty transfers and revenue share transfers.
    * Commission Transfer: if commission rate higher than 0, the amount of commission is deducted from the main amount. The remaining amount will be processed at royalty transfers.
    * Royalty Transfer: Firstly checks whether the nft contract address supports multi royalty or not. If supported, the royalties will be sent to each user defined for the nft. If not, it runs the single royalty protocol for the nft and sends calculated royalty to the receiver. The remaining amount will be processed at revenue share.
    * Revenue Share: Remaining amount split into the accounts that defined on _shareholders parameter.
    * @param _seller an address the payment will be sent
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function payout(
        address payable _seller,
        address _nftContractAddress,
        uint256 _tokenId,
        LibShareholder.Shareholder[] memory _shareholders,
        uint96 _commissionPercentage
    ) external payable whenNotPaused nonReentrant {
        require(maximumShareholdersLimit >= _shareholders.length, "reached maximum shareholder count");
        require(_isPlatformWhitelisted(msg.sender), "not allowed to reach payout");
        uint256 remainder = msg.value;
        uint256 price = msg.value;
        // commission step
        uint256 commission = _getPortionOfBid(price, _commissionPercentage);
        if (commission > 0) {
            remainder -= commission;
            emit CommissionSent(_nftContractAddress, _tokenId, _seller, commission, price);
            if (veARTAddress != address(0x0)) {
                uint256 veArtComissionPart = _getPortionOfBid(commission, veARTPercentage);
                commission -= veArtComissionPart;
                _safeTransferTo(veARTAddress, veArtComissionPart);
            }
            _safeTransferTo(companyWallet, commission);
        }

        // royalty step

        remainder = _sendRoyalties(_nftContractAddress, _tokenId, _seller, price, remainder);

        // revenue share step
        // remaining price will be split into the shareholders
        if (_shareholders.length > 0) {
            uint256 sellerTotalShare = remainder;
            for (uint i = 0; i < _shareholders.length; i++) {
                if (_shareholders[i].account != address(0)) {
                    uint256 share = _getPortionOfBid(sellerTotalShare, _shareholders[i].value);
                    remainder -= share;
                    _safeTransferTo(_shareholders[i].account, share);
                    emit ShareReceived(_nftContractAddress, _tokenId, _seller, _shareholders[i].account, share);
                }
            }
        }

        // if still there is a remainder amount then send to the seller
        if (remainder > 0) {
            _safeTransferTo(_seller, remainder);
        }
        emit PayoutCompleted(_nftContractAddress, _tokenId, _seller, remainder);
    }

    function depositFailedBalance(address _address) external payable {
        require(_isPlatformWhitelisted(msg.sender), "not allowed platform");
        require(_address != address(0), "Given address must be a non-zero address");
        failedTransferBalance[_address] += msg.value;
    }

    /**
    * @notice failed transfers are stored in `failedTransferBalance`. In the case of failure, users can withdraw failed balances.
    */
    function withdrawFailedCredits(address _address) external whenNotPaused nonReentrant {
        uint256 amount = failedTransferBalance[_address];

        require(amount > 0, "no credits to withdraw");

        failedTransferBalance[_address] = 0;
        (bool successfulWithdraw, ) = payable(_address).call{value: amount}("");
        require(successfulWithdraw, "withdraw failed");
        emit WithdrawnFailedBalance(amount);
    }

    function viewWhitelistedPlatforms() external view returns (address[] memory) {
        uint256 size = _whitelistedPlatforms.length();
        address[] memory addresses = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            addresses[i] = _whitelistedPlatforms.at(i);
        }

        return addresses;
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
    * @notice returns maximumShareholdersLimit
    */
    function getMaximumShareholdersLimit() external view returns (uint256) {
        return maximumShareholdersLimit;
    }

    function _sendRoyalties(address _nftContractAddress, uint256 _tokenId, address _seller, uint256 price, uint256 _remainder) internal returns (uint256) {
        CollectionRoyalty memory collectionRoyalty = collectionRoyalties[_nftContractAddress];
        if (collectionRoyalty.isEnabled) {
            address royaltyReceiver = collectionRoyalty.receiver;
            uint256 royaltyAmount = _getPortionOfBid(price, collectionRoyalty.percentage);
            if (royaltyReceiver != _seller && royaltyReceiver != address(0)) {
                _remainder -= royaltyAmount;
                emit RoyaltyReceived(_nftContractAddress, _tokenId, _seller, royaltyReceiver, royaltyAmount);
                _safeTransferTo(payable(royaltyReceiver), royaltyAmount);
            }
        } else {
            // first check the multi royalty is supported
            if (IERC721Upgradeable(_nftContractAddress).supportsInterface(type(IRoyalty).interfaceId)) {
                LibRoyalty.Part[] memory calculatedParts = IRoyalty(_nftContractAddress).multiRoyaltyInfo(_tokenId, price);
                require(maximumRoyaltyReceiversLimit >= calculatedParts.length, "reached maximum royalty receiver count");
                if (INFTCollectible(_nftContractAddress).owner() != _seller) {
                    for (uint i = 0; i < calculatedParts.length; i++) {
                        if (calculatedParts[i].account != address(0)) {
                            require(_remainder >= calculatedParts[i].value, "royalty amount cannot be higher than original price");
                            _remainder -= calculatedParts[i].value;
                            emit RoyaltyReceived(_nftContractAddress, _tokenId, _seller, calculatedParts[i].account, calculatedParts[i].value);
                            _safeTransferTo(payable(calculatedParts[i].account), calculatedParts[i].value);
                        }
                    }
                }
                // if the multi royalty not supported check single royalty is supported
            } else if (IERC721Upgradeable(_nftContractAddress).supportsInterface(_INTERFACE_ID_EIP2981)) {
                (address royaltyReceiver, uint256 royaltyAmount) = IRoyalty(_nftContractAddress).royaltyInfo(_tokenId, price);
                if (royaltyReceiver != _seller && royaltyReceiver != address(0)) {
                    _remainder -= royaltyAmount;
                    emit RoyaltyReceived(_nftContractAddress, _tokenId, _seller, royaltyReceiver, royaltyAmount);
                    _safeTransferTo(payable(royaltyReceiver), royaltyAmount);
                }
            }
        }

        return _remainder;
    }

    /**
    * @notice checks the received platform is whitelisted
    * @param _platform contract address
    */
    function _isPlatformWhitelisted(address _platform) internal view returns (bool) {
        return _whitelistedPlatforms.contains(_platform);
    }

    function _safeTransferTo(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        // if it fails, it updates their credit balance so they can withdraw later
        if (!success) {
            failedTransferBalance[_recipient] += _amount;
            emit FailedTransfer(_recipient, _amount);
        }
    }

    function _getPortionOfBid(uint256 _totalBid, uint256 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }
}