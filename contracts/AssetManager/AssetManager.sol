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
import {IAssetManager} from "./IAssetManager.sol";

/**
 * @title Asset Manager Contract for NFT Transactions
 */
contract AssetManager is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    struct Royalty {
        bool isEnabled;
        address receiver;
        uint96 percentage;
    }

    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    EnumerableSetUpgradeable.AddressSet private _whitelistedPlatforms;

    mapping(address => uint256) public biddingWallets;

    bytes4 private constant _INTERFACE_ID_EIP2981 = 0x2a55205a;

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

    // Stores the pending royalty amounts for each collection address.
    mapping(address => uint256) public pendingRoyalties;

    // Stores the total pending fee amount to be collected by the platform.
    uint256 public pendingFee;

    // events
    event Fund(address indexed user, uint256 amount, bool isExternal);
    event TransferFrom(address indexed user, address indexed to, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, bool isExternal);
    event FailedTransfer(address indexed receiver, uint256 amount);
    event WithdrawnFailedBalance(uint256 amount);
    event WithdrawnPendingRoyalty(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
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
    * @notice Allows the withdrawal of the pending protocol fee and sends it to the treasury.
     */
    function withdrawPendingFee() public {
        uint256 amount = pendingFee;
        pendingFee = 0;
        sendProtocolFeeToTreasure(amount);
    }

    /**
    * @notice Allows the withdrawal of pending royalty amounts for a specified NFT contract address.
    * @param _address The address of the NFT contract.
    */
    function withdrawRoyaltyAmount(address _address) external whenNotPaused nonReentrant {
        uint256 amount = pendingRoyalties[_address];

        require(amount > 0, "no credits to withdraw");
        require(royalties[_address].receiver != address(0x0), "receiver must be set");

        pendingRoyalties[_address] = 0;
        (bool successfulWithdraw, ) = payable(royalties[_address].receiver).call{value: amount}("");
        require(successfulWithdraw, "withdraw failed");
        emit WithdrawnPendingRoyalty(amount);
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
        withdrawPendingFee();
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
        withdrawPendingFee();
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
     * @notice Processes batch payments for marketplace transactions.
     * @param payments An array of PaymentInfo structs containing payment details for each transaction.
     */
    function payMPBatch(IAssetManager.PaymentInfo[] memory payments) external whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        uint96 _commissionPercentage = protocolFees[msg.sender];

        uint256 len = payments.length;
        uint64 i;
        for (; i < len; ++i) {
            require(biddingWallets[payments[i].buyer] >= payments[i].price, "Insufficient balance");
            uint256 fee =  _getPortionOfBid(payments[i].price, _commissionPercentage);
            uint256 royaltyAmount = _saveRoyaltyAmount(payments[i].collection, payments[i].seller, payments[i].price);
            require((royaltyAmount + fee) <= payments[i].price, "royalty and fee cannot be higher then main price");

            pendingFee += fee;

            biddingWallets[payments[i].buyer] -= payments[i].price;
            uint256 transferAmount = (payments[i].price - fee - royaltyAmount);
            biddingWallets[payments[i].seller] += transferAmount;
            emit TransferFrom(payments[i].buyer, payments[i].seller, transferAmount);
            IERC721Upgradeable(payments[i].collection).safeTransferFrom(payments[i].seller, payments[i].buyer, payments[i].tokenId);
        }
    }

    /**
    * @notice Allows batch payment for lending transactions.
    * @param payments An array of LendingPaymentInfo structs containing payment details.
    */
    function payLendingBatch(IAssetManager.LendingPaymentInfo[] memory payments) external whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        uint96 _commissionPercentage = protocolFees[msg.sender];

        uint256 len = payments.length;
        uint64 i;
        for (; i < len; ++i) {
            require(biddingWallets[payments[i].lender] >= payments[i].amount, "Insufficient balance");
            uint256 fee =  _getPortionOfBid(payments[i].amount, _commissionPercentage);

            pendingFee += fee;

            biddingWallets[payments[i].lender] -= payments[i].amount;
            biddingWallets[payments[i].borrower] += (payments[i].amount - fee);

            emit TransferFrom(payments[i].lender, payments[i].borrower, (payments[i].amount - fee));
            if (payments[i].repaymentAmount > 0) {
                require(biddingWallets[payments[i].borrower] >= payments[i].repaymentAmount, "Insufficient balance");
                biddingWallets[payments[i].borrower] -= payments[i].repaymentAmount;
                biddingWallets[payments[i].previousLender] += payments[i].repaymentAmount;
                emit TransferFrom(payments[i].borrower, payments[i].previousLender, payments[i].repaymentAmount);
            }

            if (payments[i].collection != address(0x0)) {
                IERC721Upgradeable(payments[i].collection).safeTransferFrom(payments[i].borrower, msg.sender, payments[i].tokenId);
            }
        }
    }

    /**
    * @notice Allows batch repayment for lending transactions.
    * @param payments An array of LendingPaymentInfo structs containing repayment details.
    */
    function lendingRepayBatch(IAssetManager.LendingPaymentInfo[] memory payments) external whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        uint256 len = payments.length;
        uint64 i;
        for (; i < len; ++i) {
            require(biddingWallets[payments[i].borrower] >= payments[i].amount, "Insufficient balance");
            emit TransferFrom(payments[i].borrower, payments[i].lender, payments[i].amount);
            biddingWallets[payments[i].borrower] -= payments[i].amount;
            biddingWallets[payments[i].lender] += payments[i].amount;
            IERC721Upgradeable(payments[i].collection).safeTransferFrom(msg.sender, payments[i].borrower, payments[i].tokenId);
        }
    }

    function payERC20Lending(address lender, address borrower, uint256 amount) external whenNotPaused {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        uint96 _commissionPercentage = protocolFees[msg.sender];
        require(biddingWallets[lender] >= amount, "Insufficient balance");
        uint256 fee =  _getPortionOfBid(amount, _commissionPercentage);

        pendingFee += fee;

        biddingWallets[lender] -= amount;
        biddingWallets[borrower] += (amount - fee);

        emit TransferFrom(lender, borrower, (amount - fee));
    }

    /**
	* @notice Processes the payment for a Dutch auction.
    * @param _nftContractAddress The address of the NFT contract.
    * @param _tokenId The token ID of the NFT being auctioned.
    * @param bidder The address of the bidder.
    * @param lender The address of the lender.
    * @param bid The amount of the bid.
    * @param endPrice The final price of the auction.
    */
    function dutchPay(address _nftContractAddress, uint256 _tokenId, address bidder, address lender, uint256 bid, uint256 endPrice) external whenNotPaused nonReentrant {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");
        require(biddingWallets[bidder] >= bid, "Insufficient balance");

        IERC721Upgradeable(_nftContractAddress).safeTransferFrom(msg.sender, bidder, _tokenId);


        uint256 fee = _getPortionOfBid(bid - endPrice, 5000);

        pendingFee += fee;

        uint256 transferredAmount = bid - fee;

        emit TransferFrom(bidder, lender, transferredAmount);

        biddingWallets[bidder] -= transferredAmount;
        biddingWallets[lender] += transferredAmount;
    }

    /**
     * @notice Sends the collected protocol fee to the treasury.
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
     * @param _from The address of the current owner of the NFT.
     * @param _to The address to which the NFT will be transferred.
     * @param _collection The address of the NFT collection contract.
     * @param _tokenId The token ID of the NFT to be transferred.
     */
    function nftTransferFrom(address _from, address _to, address _collection, uint256 _tokenId) external {
        require(_isPlatformWhitelisted(msg.sender), "not allowed");

        IERC721Upgradeable(_collection).safeTransferFrom(_from, _to, _tokenId);
    }

    /**
     * @notice Transfers multiple NFTs from the caller to a specified address.
     * @param _addresses An array of addresses of the NFT contracts.
     * @param _tokenIds An array of token IDs corresponding to the NFTs to be transferred.
     * @param _to The address to which the NFTs will be transferred.
     */
    function batchTransfer(address[] calldata _addresses, uint256[] calldata _tokenIds, address _to) external {
        uint256 len = _addresses.length;
        require(len <= 50, "exceeded the limits");
        require(len == _tokenIds.length, "addresses and tokenIds inputs does not match");
        for (uint64 i; i < len; ++i) {
            IERC721Upgradeable(_addresses[i]).safeTransferFrom(msg.sender, _to, _tokenIds[i]);
        }
    }

    /**
     * @notice Calculates and saves the royalty amount for a given sale, if applicable.
     * @param _nftContractAddress The address of the NFT contract.
     * @param _seller The address of the seller of the NFT.
     * @param price The sale price of the NFT.
     * @return uint256 The royalty amount to be saved.
     */
    function _saveRoyaltyAmount(address _nftContractAddress, address _seller, uint256 price) internal returns (uint256) {
        Royalty memory royalty = royalties[_nftContractAddress];
        if (royalty.isEnabled) {
            address royaltyReceiver = royalty.receiver;
            uint256 royaltyAmount = _getPortionOfBid(price, royalty.percentage);
            if (royaltyReceiver != _seller && royaltyReceiver != address(0)) {
                pendingRoyalties[_nftContractAddress] += royaltyAmount;
                // _safeTransferTo(payable(royaltyReceiver), royaltyAmount);
                return royaltyAmount;
            }
        }

        return 0;
    }

    /**
    * @notice Attempts to safely transfer Ether to a recipient. If the transfer fails, the amount is recorded for later withdrawal.
    * @param _recipient The address of the recipient.
    * @param _amount The amount of Ether to transfer.
    */
    function _safeTransferTo(address _recipient, uint256 _amount) internal {
        (bool success, ) = payable(_recipient).call{value: _amount, gas: 20000}("");
        // if it fails, it updates their credit balance so they can withdraw later
        if (!success) {
            failedTransferBalance[_recipient] += _amount;
            emit FailedTransfer(_recipient, _amount);
        }
    }

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

    function _getPortionOfBid(uint256 _totalBid, uint256 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    /**
    * @notice checks the given value is not zero address
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}