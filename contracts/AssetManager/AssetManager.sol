//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "../VeArt/IVeArt.sol";
import "../Royalty/IRoyalty.sol";

/**
 * @title Asset Manager Contract for NFT Transactions
 */
contract AssetManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // Structure to manage royalty information.
    struct Royalty {
        bool isEnabled;
        address receiver;
        uint96 percentage;
    }

    // Utilizing EnumerableSetUpgradeable for managing whitelisted platforms.
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    EnumerableSetUpgradeable.AddressSet private _whitelistedPlatforms;

    // Mapping to track bidding wallets.
    mapping(address => uint256) public biddingWallets;

    // EIP-2981 standard interface ID for royalties.
    bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;

    // Addresses for veArt.
    address public veArt;

    // Mapping to track royalty management.
    mapping(address => Royalty) public royalties;

    // Default royalty percentage.
    uint96 public defaultRoyalty;

    // Protocol fees for different platforms.
    mapping(address => uint96) public protocolFees;

    // Track failed transfer balances.
    mapping(address => uint256) public failedTransferBalance;

    // Toggle for commission discount.
    bool public commissionDiscountEnabled;

    // Administrator address.
    address public admin;

    // events
    event Fund(address indexed user, uint256 amount, bool isExternal);
    event TransferFrom(address indexed user, address indexed to, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, bool isExternal);
    event RoyaltyReceived(address indexed collection, uint256 indexed tokenId, address _seller, address indexed royaltyReceiver, uint256 amount);
    event FailedTransfer(address indexed receiver, uint256 amount);
    event WithdrawnFailedBalance(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    // Fallback function to receive Ether.
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

    /**
    * @notice Sets a new admin address for the contract. This operation is restricted to the contract owner.
    * @param _admin The address to be set as the new admin. It must not be the zero address.
    */
    function setAdmin(address _admin) external onlyOwner addressIsNotZero(_admin) {
        admin = _admin;
    }

    // Function to set the VeArt address.
    function setVeArtAddress(address _veArt) external onlyOwner addressIsNotZero(_veArt) {
        veArt = _veArt;
    }

    // Function to set the default royalty percentage.
    function setDefaultRoyalty(uint96 _defaultRoyalty) external onlyOwner {
        defaultRoyalty = _defaultRoyalty;
    }

    // Function to enable or disable commission discount.
    function setCommissionDiscount(bool _isEnabled) external onlyOwner {
        commissionDiscountEnabled = _isEnabled;
    }

    // Function to set or update the royalty configuration for a collection.
    function setCollectionRoyalty(address _address, address _receiver, uint96 _percentage, bool _isEnabled) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        Royalty memory royalty = royalties[_address];
        royalty.percentage = _percentage;
        royalty.isEnabled = _isEnabled;
        royalty.receiver = _receiver;
        royalties[_address] = royalty;
    }

    // Function to set the protocol fee for a platform.
    function setProtocolFee(address _platform, uint96 _protocolFee) external onlyOwner {
        protocolFees[_platform] = _protocolFee;
    }

    /**
    * @notice adds a platform to use critical functions like 'payout'
    * @param _platform related marketplace contract address
    */
    function addPlatform(address _platform) external addressIsNotZero(_platform) onlyOwner {
        require(!_whitelistedPlatforms.contains(_platform), "already whitelisted");
        _whitelistedPlatforms.add(_platform);
    }

    /**
    * @notice allows the owner to remove a contract address to restrict the payout method.
    * @param _platform related marketplace contract address
    */
    function removePlatform(address _platform) external onlyOwner {
        require(_whitelistedPlatforms.contains(_platform), "not whitelisted");
        _whitelistedPlatforms.remove(_platform);
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

    /**
    * @notice Allows to the msg.sender deposit funds to the biddingWallet balance.
    */
    function deposit() external payable whenNotPaused {
        emit Fund(msg.sender, msg.value, false);
        biddingWallets[msg.sender] += msg.value;
    }

    /**
     * @notice Withdraws a specified amount from msg.sender's bidding wallet.
     * @param _amount The amount to be withdrawn from the bidding wallet.
     */
    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        uint256 existingBalance = biddingWallets[msg.sender];
        require(existingBalance >= _amount, "Balance is insufficient for a withdrawal");
        biddingWallets[msg.sender] -= _amount;

        payable(msg.sender).transfer(_amount);
        emit Withdraw(msg.sender, _amount, false);
    }

    /**
     * @notice Allows platforms to deposit Ether on behalf of a user into their bidding wallet.
     * @param _user The address of the user for whom the deposit is being made.
     */
    function deposit(address _user) external payable whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");

        emit Fund(_user, msg.value, true);
        biddingWallets[_user] += msg.value;
    }

    /**
     * @notice Transfers a specified amount from one user's bidding wallet to another.
     * @param _from The address from which the amount is being transferred.
     * @param _to The address to which the amount is being transferred.
     * @param _amount The amount of Ether to transfer.
     */
    function transferFrom(address _from, address _to, uint256 _amount) external whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");

        require(biddingWallets[_from] >= _amount, "Insufficient balance");
        emit TransferFrom(_from, _to, _amount);
        biddingWallets[_from] -= _amount;
        biddingWallets[_to] += _amount;
    }

    /**
     * @notice Facilitates a marketplace purchase, transferring funds, paying royalties and fees, and transferring NFT ownership.
     * @param _buyer The address of the buyer in the transaction.
     * @param _seller The address of the seller in the transaction.
     * @param _collection The address of the NFT collection.
     * @param _tokenId The ID of the NFT being transacted.
     * @param _price The sale price of the NFT.
     */
    function payMP(address _buyer, address _seller, address _collection, uint256 _tokenId, uint256 _price) external {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        require(biddingWallets[_buyer] >= _price, "Insufficient balance");

        uint96 _commissionPercentage = protocolFees[msg.sender];

        uint256 fee =  _calculateFee(_seller, _price, _commissionPercentage);
        sendProtocolFeeToTreasure(fee);

        uint256 royaltyAmount = _sendRoyalty(_collection, _tokenId, _seller, _price);

        require((royaltyAmount + fee) <= _price, "royalty and fee cannot be higher then main price");

        biddingWallets[_buyer] -= _price;

        uint256 transferAmount = (_price - fee - royaltyAmount);
        biddingWallets[_seller] += transferAmount;
        emit TransferFrom(_buyer, _seller, transferAmount);

        IERC721Upgradeable(_collection).safeTransferFrom(_seller, _buyer, _tokenId);
    }

    /**
     * @notice Calculates and processes a lending fee for a transaction.
     * @param _from The address from which the fee is being charged.
     * @param _price The price of the transaction for which the fee is calculated.
     * @return The amount of the fee processed.
     */
    function payLandingFee(address _from, uint256 _price) external returns(uint256) {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");

        uint96 _commissionPercentage = protocolFees[msg.sender];

        uint256 fee =  _calculateFee(_from, _price, _commissionPercentage);
        require(biddingWallets[_from] >= fee, "Insufficient balance");

        sendProtocolFeeToTreasure(fee);

        biddingWallets[_from] -= fee;
        emit Withdraw(_from, fee, true);

        return fee;
    }

    /**
     * @notice Internal function to send protocol fees to a treasury.
     * @param _fee The amount of the fee to be sent.
     */
    function sendProtocolFeeToTreasure(uint256 _fee) internal {
        if (_fee > 0) {
            (bool success, ) = veArt.call{value: _fee}("");
            require(success, "transfer to treasure is failed");
        }
    }

    /**
     * @notice Transfers an NFT from one address to another.
     * @param _from The address from which the NFT is being transferred.
     * @param _to The address to which the NFT is being transferred.
     * @param _collection The address of the NFT collection.
     * @param _tokenId The ID of the NFT being transferred.
     */
    function nftTransferFrom(address _from, address _to, address _collection, uint256 _tokenId) external {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");

        IERC721Upgradeable(_collection).safeTransferFrom(_from, _to, _tokenId);
    }

    /**
     * @notice Allows batch transfer of multiple NFTs.
     * @param _addresses Array of NFT collection addresses.
     * @param _tokenIds Array of NFT token IDs corresponding to the addresses.
     * @param _to The destination address for the NFTs.
     */
    function batchTransfer(address[] calldata _addresses, uint256[] calldata _tokenIds, address _to) external {
        uint256 len = _addresses.length;
        require(len <= 50, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            IERC721Upgradeable(_addresses[i]).safeTransferFrom(msg.sender, _to, _tokenIds[i]);
        }
    }

    /**
     * @notice Calculates the fee based on the commission percentage, potentially applying a discount based on the user's VeArt balance.
     * @param _user The address of the user for whom the fee is being calculated.
     * @param _price The price of the transaction.
     * @param _commissionPercentage The initial commission percentage.
     * @return The calculated fee.
     */
    function _calculateFee(address _user, uint256 _price, uint96 _commissionPercentage) internal view returns (uint256) {
        if (commissionDiscountEnabled) {
            uint256 userBalance = IVeArt(veArt).balanceOf(_user);
            uint256 totalSupply = IVeArt(veArt).totalSupply();

            uint256 userShare =  10000 * userBalance / totalSupply;
            if (userShare >= 100) {
                _commissionPercentage = 0;
            } else if (userShare >= 10) {
                _commissionPercentage -= uint96(_getPortionOfBid(_commissionPercentage, ((userShare - 10) * 6000 / 90) + 1000));
            }
        }
        return _getPortionOfBid(_price, _commissionPercentage);
    }

    /**
     * @notice Calculates and sends the royalty payment for an NFT transaction.
     * @param _nftContractAddress The address of the NFT contract.
     * @param _tokenId The ID of the NFT.
     * @param _seller The address of the seller.
     * @param price The price of the NFT.
     * @return The amount of royalty paid.
     */
    function _sendRoyalty(address _nftContractAddress, uint256 _tokenId, address _seller, uint256 price) internal returns (uint256) {
        Royalty memory royalty = royalties[_nftContractAddress];
        if (royalty.isEnabled) {
            address royaltyReceiver = royalty.receiver;
            uint256 royaltyAmount = _getPortionOfBid(price, royalty.percentage);
            if (royaltyReceiver != _seller && royaltyReceiver != address(0)) {
                emit RoyaltyReceived(_nftContractAddress, _tokenId, _seller, royaltyReceiver, royaltyAmount);
                _safeTransferTo(payable(royaltyReceiver), royaltyAmount);
                return royaltyAmount;
            }
        } else {
            if (IERC721Upgradeable(_nftContractAddress).supportsInterface(_INTERFACE_ID_EIP2981) && defaultRoyalty > 0) {
                uint256 royaltyAmount = _getPortionOfBid(price, defaultRoyalty);
                (address royaltyReceiver,) = IRoyalty(_nftContractAddress).royaltyInfo(_tokenId, price);
                if (royaltyReceiver != _seller && royaltyReceiver != address(0)) {
                    emit RoyaltyReceived(_nftContractAddress, _tokenId, _seller, royaltyReceiver, royaltyAmount);
                    _safeTransferTo(payable(royaltyReceiver), royaltyAmount);
                    return royaltyAmount;
                }
            }
        }

        return 0;
    }

    /**
     * @notice Safely transfers Ether to a recipient and handles failed transfers.
     * @param _recipient The address of the recipient.
     * @param _amount The amount of Ether to be transferred.
     */
    function _safeTransferTo(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        // if it fails, it updates their credit balance so they can withdraw later
        if (!success) {
            failedTransferBalance[_recipient] += _amount;
            emit FailedTransfer(_recipient, _amount);
        }
    }

    /**
     * @notice Returns the contract's Ether balance.
     * @return The Ether balance of the contract.
     */
    function balance() external view returns (uint) {
        return address(this).balance;
    }

    /**
    * @notice checks the received platform is whitelisted
    * @param _platform contract address
    */
    function _isPlatformWhitelisted(address _platform) internal view returns (bool) {
        return _whitelistedPlatforms.contains(_platform);
    }

    /**
     * @notice Calculates a portion of a bid based on a given percentage.
     * @param _totalBid The total bid amount.
     * @param _percentage The percentage to calculate from the total bid.
     * @return The calculated portion of the bid.
     */
    function _getPortionOfBid(uint256 _totalBid, uint256 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    /**
    * @notice checks the given value is not zero address
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}