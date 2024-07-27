//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
// Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
// These functions can be used to verify that a message was signed by the holder of the private keys of a given address.
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
// is a standard for hashing and signing of typed structured data.
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";

import "../AssetManager/IAssetManager.sol";
import "./lib/LibLending.sol";

/**
* @title Salvor Lending
* @notice Operates on the Ethereum-based blockchain, providing a lending pool platform where users can lend and borrow NFTs. Each pool is characterized by parameters such as the duration of the loan, interest rate.
*/
contract SalvorLendingV2 is Initializable, ERC721HolderUpgradeable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    // Structure defining a lending pool
    struct LendingPool {
        uint256 duration;   // Duration of the loan in the pool in terms of a time unit (e.g., seconds, blocks)
        uint256 rate;       // Interest rate for the loan in the pool, represented as a percentage
        uint96 protocolFee; // Legacy field: Originally intended to represent the fee percentage collected by the protocol. Currently not in use, retained for backward compatibility and contract integrity.
        bool isActive;      // Status of the pool, indicating whether it is active (true) or not (false)
    }

    // Structure defining an individual loan
    struct Loan {
        address borrower;  // address of the borrower
        address lender;    // address of the lender
        uint256 amount;    // Amount of the loan in terms of the token or currency being lent
        uint256 duration;  // Duration of the loan, similar to the duration in LendingPool
        uint256 rate;      // Interest rate for this specific loan, similar to the rate in LendingPool
        uint256 startedAt; // Timestamp indicating when the loan started
    }

    struct DutchAuction {
        // duration of the auction
        uint256 duration;
        // drop interval timestamp. e.g 5 minutes
        uint256 dropInterval;
        // the auction starting time
        uint256 startTime;
        // maximum amount for the nft at the beginning of the auction
        uint256 startPrice;
        // minimum amount for the nft at the end of auction
        uint256 endPrice;
    }

    string private constant SIGNING_DOMAIN = "SalvorLending";
    string private constant SIGNATURE_VERSION = "2";
    using ECDSAUpgradeable for bytes32;

    // Mapping from an ERC721 collection address to a LendingPool structure, storing the lending pool configuration for each address
    mapping(address => LendingPool) public lendingPools;
    // Mapping storing loan details. The first key is the collection address, and the second key is the unique identifier for the loan
    mapping(address => mapping(uint256 => Loan)) public items;

    // Mapping to keep track of filled loan requests, identified by a unique bytes32 hash
    mapping(bytes32 => bool) public fills;

    // Mapping that stores the sizes of loans or assets, identified by a unique bytes32 hash
    mapping(bytes32 => uint256) public sizes;

    // Address of the validator, responsible for certain administrative functions or validations within the contract
    address public validator;

    // Address of the admin, holding administrative privileges over the contract
    address public admin;

    // Address of the asset manager, responsible for managing the assets within the lending pools
    address public assetManager;

    // Defines the range of blocks within which certain operations or validations must be performed
    uint256 public blockRange;

    // Duration of the auction in seconds.
    uint64 public auctionDuration;

    // Time interval between price drops in the Dutch auction.
    uint64 public dropInterval;

    // Mapping of token addresses to token IDs to their respective Dutch auction details.
    mapping(address => mapping(uint256 => DutchAuction)) public dutchAuctions;

    mapping(address => mapping(uint256 => uint256)) public delegatedAmounts;

    mapping(address => mapping(address => uint256)) public cancelOfferTimestamps;

    // events
    event SetPool(address indexed collection, uint96 protocolFee, uint256 duration, uint256 rate, bool isActive);
    event Extend(address indexed collection, uint256 indexed tokenId, string salt, uint256 amount, uint256 repaidAmount);
    event Delegate(address indexed collection, uint256 indexed tokenId, string salt, uint256 delegatedAmount, uint256 receivedAmount);
    event Borrow(address indexed collection, uint256 indexed tokenId, string salt, uint256 amount);
    event Repay(address indexed collection, uint256 indexed tokenId, uint256 repaidAmount);
    event ClearDebt(address indexed collection, uint256 indexed tokenId);
    event DutchAuctionMadeBid(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 amount, uint256 endPrice);
    event DutchAuctionCreated(
        address indexed collection,
        uint256 indexed tokenId,
        uint64 duration,
        uint64 dropInterval,
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime
    );
    event CancelOffer(address indexed user);
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __EIP712_init_unchained(SIGNING_DOMAIN, SIGNATURE_VERSION);
        __Ownable_init_unchained();
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
        __ERC721Holder_init_unchained();
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

    /**
    * @notice Sets a new admin address for the contract. This operation is restricted to the contract owner.
    * @param _admin The address to be set as the new admin. It must not be the zero address.
    */
    function setAdmin(address _admin) external onlyOwner addressIsNotZero(_admin) {
        admin = _admin;
    }

    /**
    * @notice Updates the block range parameter within the contract. This action can only be performed by the contract owner.
    * @param _blockRange The new block range value to be set.
    */
    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
    }

    /**
    * @notice Sets the duration of the auction.
    * @param _auctionDuration The duration of the auction in seconds.
    */
    function setAuctionDuration(uint64 _auctionDuration) external onlyOwner {
        auctionDuration = _auctionDuration;
    }

    /**
     * @notice Sets the interval between price drops in the Dutch auction.
     *         Note: Must set auction duration first.
     * @param _dropInterval The time interval between price drops in seconds.
     */
    function setDropInterval(uint64 _dropInterval) external onlyOwner {
        require(auctionDuration > _dropInterval, "Duration period exceed the limit");
        dropInterval = _dropInterval;
    }

    /**
    * @notice Assigns a new validator address. Restricted to actions by the contract owner.
    * @param _validator The new validator's address, which cannot be the zero address.
    */
    function setValidator(address _validator) external onlyOwner addressIsNotZero(_validator) {
        validator = _validator;
    }

    /**
    * @notice Sets a new asset manager address. Only the contract owner can perform this action.
    * @param _assetManager The address to be appointed as the new asset manager, must not be the zero address.
    */
    function setAssetManager(address _assetManager) external onlyOwner addressIsNotZero(_assetManager) {
        assetManager = _assetManager;
    }

    /**
    * @notice Configures or updates a lending pool for a specified collection. This function is accessible to the contract owner or the admin.
    * @param _collection The address of the NFT collection for which the lending pool is being set.
    * @param _protocolFee Fee associated with the protocol, expressed in basis points.
    * @param _duration The duration for which the pool will be active.
    * @param _rate The interest rate for the lending pool.
    * @param _isActive Boolean indicating whether the pool is active or not.
    */
    function setPool(address _collection, uint96 _protocolFee, uint256 _duration, uint256 _rate, bool _isActive) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        require(_duration > 0 && _duration % 86400 == 0, "day unit must be entered");
        lendingPools[_collection].duration = _duration;
        lendingPools[_collection].protocolFee = _protocolFee;
        lendingPools[_collection].rate = _rate;
        lendingPools[_collection].isActive = _isActive;
        IERC721Upgradeable(_collection).setApprovalForAll(assetManager, true);
        emit SetPool(_collection, _protocolFee, _duration, _rate, _isActive);
    }

    function batchDelegate(
        LibLendingV2.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLendingV2.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    )
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        require(len == _signatures.length && len == _tokens.length && len == _tokenSignatures.length, "inputs do not match");
        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);

        for (uint256 i; i < len; ++i) {
            payments[i] = delegate(_loanOffers[i], _signatures[i], _tokens[i],_tokenSignatures[i]);
        }
        IAssetManager(assetManager).payLendingDelegatedBatch(payments);
    }

    /**
    * @notice Allows batch borrowing of multiple loans in a single transaction. It enforces contract's operational status, non-reentrancy, and validation that the caller is not a contract.
    * Each loan offer in the batch must comply with the predefined limits.
    * @param _loanOffers Array of loan offers, each representing an individual loan agreement.
    * @param _signatures Array of signatures corresponding to each loan offer, validating the agreement.
    * @param _tokens Array of tokens associated with each loan offer.
    * @param _tokenSignatures Array of signatures corresponding to each token, ensuring authenticity.
    */
    function batchBorrow(
        LibLendingV2.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLendingV2.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    ) public whenNotPaused nonReentrant assertNotContract {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        require(len == _signatures.length && len == _tokens.length && len == _tokenSignatures.length, "inputs do not match");
        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);
        for (uint256 i; i < len; ++i) {
            payments[i] = borrow(_loanOffers[i], _signatures[i], _tokens[i], _tokenSignatures[i]);
        }
        IAssetManager(assetManager).payLendingBatchV2(payments);
    }

    /**
    * @notice Enables batch clearing of debts for multiple NFTs in a single transaction. Also ensures that the caller is not a contract. Limits the number of NFTs whose debts can be cleared in one call.
    * @param _nftContractAddresses Array of addresses for NFT contracts, each corresponding to a specific NFT.
    * @param _tokenIds Array of token IDs, each corresponding to a specific NFT within its contract, for which the debt is to be cleared.
    */
    function batchClearDebt(address[] calldata _nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = _nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        require(len == _tokenIds.length, "inputs do not match");
        for (uint256 i; i < len; ++i) {
            clearDebt(_nftContractAddresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice Enables batch repayment of loans for multiple NFTs in a single transaction.
    * It also enforces a limit on the number of NFTs for which loans can be repaid in one batch.
    * @param _nftContractAddresses Array of NFT contract addresses, each address corresponding to a specific NFT for which the loan is to be repaid.
    * @param _tokenIds Array of token IDs, each ID corresponding to a specific NFT within its contract, for which the loan is to be repaid.
    */
    function batchRepay(address[] calldata _nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = _nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        require(len == _tokenIds.length, "inputs do not match");
        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);
        for (uint256 i; i < len; ++i) {
            payments[i] = repay(_nftContractAddresses[i], _tokenIds[i]);
        }
        IAssetManager(assetManager).lendingRepayBatchV2(payments);
    }

    /**
    * @notice Allows batch repayment of loans with Ether for multiple NFTs in a single transaction.
    * @param _nftContractAddresses Array of NFT contract addresses, corresponding to specific NFTs for which the loans are being repaid.
    * @param _tokenIds Array of token IDs for the NFTs in their respective contracts.
    */
    function batchRepayETH(address[] calldata _nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    payable
    {
        uint256 len = _nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        require(len == _tokenIds.length, "inputs do not match");

        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);

        for (uint256 i; i < len; ++i) {
            payments[i] = repay(_nftContractAddresses[i], _tokenIds[i]);
        }
        IAssetManager(assetManager).lendingRepayBatchV2(payments);
    }

    /**
    * @notice Enables batch extension of multiple loans. It limits the number of loan offers that can be extended in one batch.
    * @param _loanOffers Array of loan offers to be extended.
    * @param _signatures Array of signatures corresponding to each loan offer.
    * @param _tokens Array of tokens associated with each loan offer.
    * @param _tokenSignatures Array of signatures corresponding to each token.
    */
    function batchExtend(
        LibLendingV2.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLendingV2.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    )
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        require(len == _signatures.length && len == _tokens.length && len == _tokenSignatures.length, "inputs do not match");

        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);

        for (uint256 i; i < len; ++i) {
            payments[i] = extend(_loanOffers[i], _signatures[i], _tokens[i],_tokenSignatures[i]);
        }
        IAssetManager(assetManager).payLendingBatchV2(payments);
    }

    /**
    * @notice Allows for the batch extension of multiple loans with Ether payment. It also enforces a limit on the number of loan offers that can be extended in one go.
    * @param _loanOffers Array of loan offers to be extended.
    * @param _signatures Array of signatures for each loan offer.
    * @param _tokens Array of tokens related to each loan offer.
    * @param _tokenSignatures Array of signatures for each token, confirming authenticity.
    */
    function batchExtendETH(
        LibLendingV2.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLendingV2.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    )
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    payable
    {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        require(len == _signatures.length && len == _tokens.length && len == _tokenSignatures.length, "inputs do not match");

        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        IAssetManager.LendingPaymentInfoV2[] memory payments = new IAssetManager.LendingPaymentInfoV2[](len);

        for (uint256 i; i < len; ++i) {
            payments[i] = extend(_loanOffers[i], _signatures[i], _tokens[i],_tokenSignatures[i]);
        }
        IAssetManager(assetManager).payLendingBatchV2(payments);
    }

    /**
    * @notice Allows a user to make a bid for a Dutch auction using ETH.
    * @param _nftContractAddress The address of the NFT contract.
    * @param _tokenId The ID of the token being bid on.
    */
    function makeBidForDutchAuctionETH(address _nftContractAddress, uint256 _tokenId)
    external
    payable
    {
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        makeBidForDutchAuction(_nftContractAddress, _tokenId);
    }

    /**
     * @notice Allows a bidder to make a bid for a Dutch auction.
     * @param _nftContractAddress The address of the NFT contract.
     * @param _tokenId The token ID of the NFT being auctioned.
     */
    function makeBidForDutchAuction(address _nftContractAddress, uint256 _tokenId)
    public
    whenNotPaused
    nonReentrant
    auctionStarted(_nftContractAddress, _tokenId)
    {
        address lender = items[_nftContractAddress][_tokenId].lender;
        require(lender != address(0), "NFT is not deposited");
        uint256 price = getDutchPrice(_nftContractAddress, _tokenId);
        emit DutchAuctionMadeBid(_nftContractAddress, _tokenId, lender, price, dutchAuctions[_nftContractAddress][_tokenId].endPrice);
        uint256 delegatedAmount = delegatedAmounts[_nftContractAddress][_tokenId];
        delegatedAmounts[_nftContractAddress][_tokenId] = 0;
        uint256 endPrice = dutchAuctions[_nftContractAddress][_tokenId].endPrice;
        IAssetManager(assetManager).dutchPayV2(_nftContractAddress, _tokenId, msg.sender, lender, price, endPrice, delegatedAmount);
        delete dutchAuctions[_nftContractAddress][_tokenId];
        delete items[_nftContractAddress][_tokenId];
    }

    function cancelAllOffers() external whenNotPaused {
        cancelOfferTimestamps[msg.sender][address(0x0)] = block.timestamp;
        emit CancelOffer(msg.sender);
    }

    /**
    * @notice the current dutch price by calculating the steps
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    function getDutchPrice(address _nftContractAddress, uint256 _tokenId) public view returns (uint256) {
        if (block.timestamp < dutchAuctions[_nftContractAddress][_tokenId].startTime) {
            return dutchAuctions[_nftContractAddress][_tokenId].startPrice;
        }

        if ((block.timestamp - dutchAuctions[_nftContractAddress][_tokenId].startTime) > dutchAuctions[_nftContractAddress][_tokenId].duration) {
            return dutchAuctions[_nftContractAddress][_tokenId].endPrice;
        } else {
            uint256 diffPrice = dutchAuctions[_nftContractAddress][_tokenId].startPrice - dutchAuctions[_nftContractAddress][_tokenId].endPrice;
            uint256 diffDate = block.timestamp - dutchAuctions[_nftContractAddress][_tokenId].startTime;
            uint256 dropsPerStep = diffPrice / (dutchAuctions[_nftContractAddress][_tokenId].duration / dutchAuctions[_nftContractAddress][_tokenId].dropInterval);
            uint256 steps = diffDate / dutchAuctions[_nftContractAddress][_tokenId].dropInterval;
            return dutchAuctions[_nftContractAddress][_tokenId].startPrice - (steps * dropsPerStep);
        }
    }

    /**
    * @notice Calculates the total repayment amount for a set of loans.
    * @param _nftContractAddresses The addresses of the NFT contracts for the loans.
    * @param _tokenIds The token IDs of the NFTs for the loans.
    * @return uint256 The total repayment amount for the specified loans.
    */
    function getCalculateRepayLoanAmount(address[] memory _nftContractAddresses, uint256[] memory _tokenIds) external view returns (uint256) {
        uint256 len = _nftContractAddresses.length;
        uint256 totalInterest;
        for (uint256 i; i < len; ++i) {
            Loan memory item = items[_nftContractAddresses[i]][_tokenIds[i]];
            totalInterest += _calculateRepayment(item.amount, item.rate, item.startedAt, item.duration);
        }
        return totalInterest;
    }

    function getRemainingAmount(LibLendingV2.LoanOffer memory offer) external view returns (uint256) {
        return offer.size - sizes[LibLendingV2.hash(offer)];
    }

    /**
    * @notice Retrieves the current chain ID of the blockchain where the contract is deployed.
    * @return id The current chain ID.
    */
    function getChainId() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    /**
    * @notice Validates a loan offer by checking the signature. This function is public and view only.
    * @param _loanOffer The loan offer to validate.
    * @param signature The signature associated with the loan offer.
    * @return The address of the signer of the loan offer.
    */
    function _validate(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibLendingV2.hash(_loanOffer);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Extends an existing loan offer. This function is internal and checks that the loan has not been cancelled.
    * @param _loanOffer The loan offer to be extended.
    * @param signature The signature of the lender for validation.
    * @param token The token associated with the NFT for the loan.
    * @param tokenSignature The signature for the token, ensuring its authenticity.
    */
    function extend(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature, LibLendingV2.Token memory token, bytes memory tokenSignature)
    internal
    returns (IAssetManager.LendingPaymentInfoV2 memory)
    {
        Loan memory item = items[_loanOffer.nftContractAddress][token.tokenId];
        require(item.borrower == msg.sender, "there is no collateralized item belongs to msg.sender");
        if (dutchAuctions[_loanOffer.nftContractAddress][token.tokenId].startTime > 0) {
            require(block.timestamp < dutchAuctions[_loanOffer.nftContractAddress][token.tokenId].startTime, "Auction has already started. Cannot proceed with the operation");
        }

        address lender = validateLoanOffer(_loanOffer, signature, token, tokenSignature);

        uint256 payment = _calculateRepayment(item.amount, item.rate, item.startedAt, item.duration);
        emit Extend(_loanOffer.nftContractAddress, token.tokenId, _loanOffer.salt, _loanOffer.amount, payment);

        address previousLender = item.lender;
        LendingPool memory lendingPool = lendingPools[_loanOffer.nftContractAddress];

        items[_loanOffer.nftContractAddress][token.tokenId].lender = lender;
        items[_loanOffer.nftContractAddress][token.tokenId].amount = _loanOffer.amount;
        items[_loanOffer.nftContractAddress][token.tokenId].duration = lendingPool.duration;
        items[_loanOffer.nftContractAddress][token.tokenId].rate = lendingPool.rate;
        items[_loanOffer.nftContractAddress][token.tokenId].startedAt = block.timestamp;

        uint256 endPrice = _loanOffer.amount + ((_loanOffer.amount * lendingPool.rate) / 1 ether);

        setDutchAuction(_loanOffer.nftContractAddress, token.tokenId, endPrice*3, endPrice, block.timestamp + lendingPool.duration);

        uint256 delegatedAmount = delegatedAmounts[_loanOffer.nftContractAddress][token.tokenId];
        delegatedAmounts[_loanOffer.nftContractAddress][token.tokenId] = 0;
        return IAssetManager.LendingPaymentInfoV2({
            lender: lender,
            borrower: msg.sender,
            previousLender: previousLender,
            collection: address(0x0),
            tokenId: 0,
            amount: _loanOffer.amount,
            repaymentAmount: payment,
            delegatedAmount: delegatedAmount
        });
    }

    function delegate(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature, LibLendingV2.Token memory token, bytes memory tokenSignature)
    internal
    returns (IAssetManager.LendingPaymentInfoV2 memory)
    {
        Loan memory item = items[_loanOffer.nftContractAddress][token.tokenId];
        require(item.lender == msg.sender, "there is no collateralized item belongs to msg.sender");
        if (dutchAuctions[_loanOffer.nftContractAddress][token.tokenId].startTime > 0) {
            require(block.timestamp < dutchAuctions[_loanOffer.nftContractAddress][token.tokenId].startTime, "Auction has already started. Cannot proceed with the operation");
        }

        address lender = validateLoanOfferToDelegate(_loanOffer, signature, token, tokenSignature);

        address previousLender = item.lender;

        items[_loanOffer.nftContractAddress][token.tokenId].lender = lender;
        uint256 payment = 0;
        uint256 remainingAmount = items[_loanOffer.nftContractAddress][token.tokenId].amount - delegatedAmounts[_loanOffer.nftContractAddress][token.tokenId];
        if (_loanOffer.amount >= remainingAmount) {
            payment = remainingAmount;
        } else {
            payment = _loanOffer.amount;
            delegatedAmounts[_loanOffer.nftContractAddress][token.tokenId] += (items[_loanOffer.nftContractAddress][token.tokenId].amount - _loanOffer.amount);
        }

        emit Delegate(_loanOffer.nftContractAddress, token.tokenId, _loanOffer.salt, delegatedAmounts[_loanOffer.nftContractAddress][token.tokenId], payment);

        return IAssetManager.LendingPaymentInfoV2({
            lender: lender,
            borrower: address(0x0),
            previousLender: previousLender,
            collection: address(0x0),
            tokenId: 0,
            amount: payment,
            repaymentAmount: 0,
            delegatedAmount: 0
        });
    }

    /**
    * @notice Allows borrowing against an NFT based on a loan offer. This function is internal and ensures the loan has not already been taken and not been cancelled.
    * @param _loanOffer The loan offer against which the NFT is being borrowed.
    * @param signature The lender's signature for validation.
    * @param token The token information of the NFT being used as collateral.
    * @param tokenSignature The signature validating the token's authenticity.
    */
    function borrow(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature, LibLendingV2.Token memory token, bytes memory tokenSignature)
    internal
    returns (IAssetManager.LendingPaymentInfoV2 memory)
    {
        require(items[_loanOffer.nftContractAddress][token.tokenId].startedAt == 0, "has been already borrowed");

        address lender = validateLoanOffer(_loanOffer, signature, token, tokenSignature);

        emit Borrow(_loanOffer.nftContractAddress, token.tokenId, _loanOffer.salt, _loanOffer.amount);

        items[_loanOffer.nftContractAddress][token.tokenId].borrower = msg.sender;
        items[_loanOffer.nftContractAddress][token.tokenId].lender = lender;
        items[_loanOffer.nftContractAddress][token.tokenId].amount = _loanOffer.amount;
        items[_loanOffer.nftContractAddress][token.tokenId].duration = lendingPools[_loanOffer.nftContractAddress].duration;
        items[_loanOffer.nftContractAddress][token.tokenId].rate = lendingPools[_loanOffer.nftContractAddress].rate;
        items[_loanOffer.nftContractAddress][token.tokenId].startedAt = block.timestamp;

        uint256 endPrice = _loanOffer.amount + ((_loanOffer.amount * lendingPools[_loanOffer.nftContractAddress].rate) / 1 ether);

        setDutchAuction(_loanOffer.nftContractAddress, token.tokenId, endPrice*3, endPrice, block.timestamp + lendingPools[_loanOffer.nftContractAddress].duration);

        return IAssetManager.LendingPaymentInfoV2({
            lender: lender,
            borrower: msg.sender,
            previousLender: address(0x0),
            collection: _loanOffer.nftContractAddress,
            tokenId: token.tokenId,
            amount: _loanOffer.amount,
            repaymentAmount: 0,
            delegatedAmount: 0
        });
    }

    /**
    * @notice Repays the loan for a specific NFT and returns the NFT to the borrower. This function is internal.
    * @param nftContractAddress The address of the NFT contract.
    * @param _tokenId The ID of the token (NFT) for which the loan is being repaid.
    */
    function repay(address nftContractAddress, uint256 _tokenId) internal returns(IAssetManager.LendingPaymentInfoV2 memory) {
        Loan memory item = items[nftContractAddress][_tokenId];

        require(item.borrower == msg.sender, "msg.sender is not borrower");
        if (dutchAuctions[nftContractAddress][_tokenId].startTime > 0) {
            require(block.timestamp < dutchAuctions[nftContractAddress][_tokenId].startTime, "Auction has already started. Cannot proceed with the operation");
        }

        uint256 payment = _calculateRepayment(item.amount, item.rate, item.startedAt, item.duration);

        emit Repay(nftContractAddress, _tokenId, payment);

        delete items[nftContractAddress][_tokenId];
        delete dutchAuctions[nftContractAddress][_tokenId];

        uint256 delegatedAmount = delegatedAmounts[nftContractAddress][_tokenId];
        delegatedAmounts[nftContractAddress][_tokenId] = 0;

        return IAssetManager.LendingPaymentInfoV2({
            borrower: item.borrower,
            lender: item.lender,
            previousLender: address(0x0),
            collection: nftContractAddress,
            tokenId: _tokenId,
            amount: payment,
            repaymentAmount: 0,
            delegatedAmount: delegatedAmount
        });
    }

    /**
    * @notice Clears the debt associated with a specific NFT after the loan period has finished. This function is internal.
    * @param nftContractAddress The address of the NFT contract.
    * @param _tokenId The ID of the token (NFT) for which the debt is being cleared.
    */
    function clearDebt(address nftContractAddress, uint256 _tokenId) internal {
        Loan memory item = items[nftContractAddress][_tokenId];

        require(item.lender == msg.sender, "msg.sender is not lender");
        if (dutchAuctions[nftContractAddress][_tokenId].startTime > 0) {
            require(block.timestamp > (dutchAuctions[nftContractAddress][_tokenId].startTime + dutchAuctions[nftContractAddress][_tokenId].duration), "auction period is not finished");
        } else {
            require(block.timestamp > (items[nftContractAddress][_tokenId].duration + items[nftContractAddress][_tokenId].startedAt), "loan period is not finished");
        }

        emit ClearDebt(nftContractAddress, _tokenId);
        delegatedAmounts[nftContractAddress][_tokenId] = 0;
        IAssetManager(assetManager).nftTransferFrom(address(this), item.lender, nftContractAddress, _tokenId);

        delete items[nftContractAddress][_tokenId];
        delete dutchAuctions[nftContractAddress][_tokenId];
    }

    /**
    * @notice allows to create a dutch auction.
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    * @param _startPrice the starting price at which the price will be decreased
    * @param _endPrice the ending price at which the price will be stop decreasing
    */
    function setDutchAuction(
        address _nftContractAddress,
        uint256 _tokenId,
        uint256 _startPrice,
        uint256 _endPrice,
        uint256 _startTime
    ) internal {
        dutchAuctions[_nftContractAddress][_tokenId].startTime = _startTime;
        dutchAuctions[_nftContractAddress][_tokenId].duration = auctionDuration;
        dutchAuctions[_nftContractAddress][_tokenId].dropInterval = dropInterval;
        dutchAuctions[_nftContractAddress][_tokenId].startPrice = _startPrice;
        dutchAuctions[_nftContractAddress][_tokenId].endPrice = _endPrice;

        emit DutchAuctionCreated(_nftContractAddress, _tokenId, auctionDuration, dropInterval, _startPrice, _endPrice, _startTime);
    }

    /**
    * @notice Validates a loan offer and corresponding token. This internal function ensures the loan offer and token meet various criteria including active pool, valid token signature, matching salts, sender authenticity, and signature expiry.
    * @param _loanOffer The loan offer to validate.
    * @param _token The token associated with the loan offer.
    * @param _tokenSignature The signature of the token.
    */
    function validateLoanOffer(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature, LibLendingV2.Token memory _token, bytes memory _tokenSignature) internal returns (address) {
        require(_loanOffer.amount > 0, "lend amount cannot be 0");
        require(lendingPools[_loanOffer.nftContractAddress].isActive, "pool is not active");
        require(_hashTypedDataV4(LibLendingV2.hashToken(_token)).recover(_tokenSignature) == validator, "token signature is not valid");
        require(keccak256(abi.encodePacked(_token.salt)) == keccak256(abi.encodePacked(_loanOffer.salt)), "salt does not match");
        require(_token.owner == msg.sender, "token signature does not belong to msg.sender");
        require(_loanOffer.nftContractAddress == _token.nftContractAddress, "contract address does not match");
        require(_token.blockNumber + blockRange > block.number, "token signature has been expired");
        require((block.timestamp - _loanOffer.startedAt) < _loanOffer.duration, "offer has expired");

        bytes32 hash = LibLendingV2.hash(_loanOffer);

        require(_loanOffer.size > sizes[hash], "size is filled");
        address lender = _validate(_loanOffer, signature);
        require(lender==_loanOffer.lender, "lender does not match with signed data");
        require(msg.sender != lender, "signer cannot borrow from own loan offer");
        require(lender == _token.lender, "token and loan offer owner does not match");
        require(cancelOfferTimestamps[lender][address(0x0)] < _loanOffer.startedAt, "offer is cancelled");

        sizes[hash] += 1;
        return lender;
    }

    function validateLoanOfferToDelegate(LibLendingV2.LoanOffer memory _loanOffer, bytes memory signature, LibLendingV2.Token memory _token, bytes memory _tokenSignature) internal returns (address) {
        require(_loanOffer.amount > 0, "lend amount cannot be 0");
        require(lendingPools[_loanOffer.nftContractAddress].isActive, "pool is not active");
        require(_hashTypedDataV4(LibLendingV2.hashToken(_token)).recover(_tokenSignature) == validator, "token signature is not valid");
        require(keccak256(abi.encodePacked(_token.salt)) == keccak256(abi.encodePacked(_loanOffer.salt)), "salt does not match");
        require(_token.owner == msg.sender, "token signature does not belong to msg.sender");
        require(_loanOffer.nftContractAddress == _token.nftContractAddress, "contract address does not match");
        require(_token.blockNumber + blockRange > block.number, "token signature has been expired");
        require((block.timestamp - _loanOffer.startedAt) < _loanOffer.duration, "offer has expired");

        bytes32 hash = LibLendingV2.hash(_loanOffer);

        require(_loanOffer.size > sizes[hash], "size is filled");
        address newLender = _validate(_loanOffer, signature);
        require(newLender==_loanOffer.lender, "lender does not match with signed data");
        require(msg.sender != newLender, "new lender and previous lender cannot be same");
        require(newLender == _token.lender, "token and loan offer owner does not match");
        require(cancelOfferTimestamps[newLender][address(0x0)] < _loanOffer.startedAt, "offer is cancelled");

        sizes[hash] += 1;
        return newLender;
    }

    /**
    * @notice Calculates the total repayment amount including interest. This internal pure function is used for calculating loan repayments.
    * @param _totalBid The principal amount of the loan.
    * @param _interest The interest rate applied to the loan.
    * @return The total repayment amount.
    */
    function _calculateRepayment(uint256 _totalBid, uint256 _interest, uint256 _startedAt, uint256 _duration) internal view returns (uint256) {
        uint256 elapsedDay = ((block.timestamp - _startedAt) / 86400) + 1;
        uint256 totalDays = _duration / 86400;
        if (totalDays < elapsedDay) {
            return _totalBid + ((_totalBid * _interest) / 1 ether);
        } else {
            return _totalBid + ((_totalBid * _interest * elapsedDay) / (1 ether * totalDays));
        }
    }

    /**
    * @notice Ensures that the function caller is not a smart contract, allowing only EOA (Externally Owned Accounts) calls.
    */
    modifier assertNotContract() {
        require(msg.sender == tx.origin, 'Error: Unauthorized smart contract access');
        _;
    }

    /**
    * @notice Ensures that a given address is not the zero address.
    * @param _address The address to check.
    */
    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }

    /**
    * @notice makes sure auction is started
    * @param _nftContractAddress nft contract address
    * @param _tokenId nft tokenId
    */
    modifier auctionStarted(address _nftContractAddress, uint256 _tokenId) {
        uint256 startTime = dutchAuctions[_nftContractAddress][_tokenId].startTime;

        require(block.timestamp > startTime, "Auction is not started");
        _;
    }
}