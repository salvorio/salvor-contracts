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
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";

import "../NFTCollectible/INFTCollectible.sol";
import "../PaymentManager/IPaymentManager.sol";
import "../AssetManager/IAssetManager.sol";
import "./lib/LibLending.sol";
import "../libs/LibShareholder.sol";

/**
* @title Salvor Lending
* @notice Operates on the Ethereum-based blockchain, providing a lending pool platform where users can lend and borrow NFTs. Each pool is characterized by parameters such as the duration of the loan, interest rate.
*/
contract SalvorLending is Initializable, ERC721HolderUpgradeable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
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

    string private constant SIGNING_DOMAIN = "SalvorLending";
    string private constant SIGNATURE_VERSION = "1";
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

    // events
    event SetPool(address indexed collection, uint96 protocolFee, uint256 duration, uint256 rate, bool isActive);
    event CancelLoan(address indexed collection, string salt, bytes32 hash);
    event Extend(address indexed collection, uint256 indexed tokenId, string salt, uint256 amount, uint256 fee, uint256 repaidAmount);
    event Borrow(address indexed collection, uint256 indexed tokenId, string salt, uint256 amount, uint256 fee);
    event Repay(address indexed collection, uint256 indexed tokenId, uint256 repaidAmount);
    event ClearDebt(address indexed collection, uint256 indexed tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

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
        lendingPools[_collection].duration = _duration;
        lendingPools[_collection].protocolFee = _protocolFee;
        lendingPools[_collection].rate = _rate;
        lendingPools[_collection].isActive = _isActive;
        IERC721Upgradeable(_collection).setApprovalForAll(assetManager, true);
        emit SetPool(_collection, _protocolFee, _duration, _rate, _isActive);
    }

    /**
    * @notice Allows the contract owner to cancel multiple loans. This function is only operational when the contract is not paused and is protected against reentrancy.
    * @param _loanOffers Array of loan offers to be cancelled.
    * @param _signatures Array of signatures corresponding to each loan offer.
    */
    function cancelLoans(LibLending.LoanOffer[] calldata _loanOffers, bytes[] calldata _signatures) external onlyOwner whenNotPaused nonReentrant {
        uint256 len = _loanOffers.length;
        for (uint256 i; i < len; ++i) {
            cancelLoan(_loanOffers[i], _signatures[i]);
        }
    }

    /**
    * @notice Internal function to cancel an individual loan. It verifies the signer's authorization and ensures the loan has not been cancelled previously.
    * @param _loanOffer The loan offer to be cancelled.
    * @param _signature Signature associated with the loan offer.
    */
    function cancelLoan(LibLending.LoanOffer calldata _loanOffer, bytes memory _signature)
    internal
    onlySigner(_validate(_loanOffer, _signature))
    isNotCancelled(LibLending.hashKey(_loanOffer))
    {
        bytes32 loanKeyHash = LibLending.hashKey(_loanOffer);
        fills[loanKeyHash] = true;
        emit CancelLoan(_loanOffer.nftContractAddress, _loanOffer.salt, loanKeyHash);
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
        LibLending.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLending.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    ) public whenNotPaused nonReentrant assertNotContract {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            borrow(_loanOffers[i], _signatures[i], _tokens[i], _tokenSignatures[i]);
        }
    }

    /**
    * @notice Enables batch clearing of debts for multiple NFTs in a single transaction. Also ensures that the caller is not a contract. Limits the number of NFTs whose debts can be cleared in one call.
    * @param nftContractAddresses Array of addresses for NFT contracts, each corresponding to a specific NFT.
    * @param _tokenIds Array of token IDs, each corresponding to a specific NFT within its contract, for which the debt is to be cleared.
    */
    function batchClearDebt(address[] calldata nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            clearDebt(nftContractAddresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice Enables batch repayment of loans for multiple NFTs in a single transaction.
    * It also enforces a limit on the number of NFTs for which loans can be repaid in one batch.
    * @param nftContractAddresses Array of NFT contract addresses, each address corresponding to a specific NFT for which the loan is to be repaid.
    * @param _tokenIds Array of token IDs, each ID corresponding to a specific NFT within its contract, for which the loan is to be repaid.
    */
    function batchRepay(address[] calldata nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            repay(nftContractAddresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice Allows batch repayment of loans with Ether for multiple NFTs in a single transaction.
    * @param nftContractAddresses Array of NFT contract addresses, corresponding to specific NFTs for which the loans are being repaid.
    * @param _tokenIds Array of token IDs for the NFTs in their respective contracts.
    */
    function batchRepayETH(address[] calldata nftContractAddresses, uint256[] calldata _tokenIds)
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    payable
    {
        uint256 len = nftContractAddresses.length;
        require(len <= 20, "exceeded the limits");
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        for (uint64 i; i < len; ++i) {
            repay(nftContractAddresses[i], _tokenIds[i]);
        }
    }

    /**
    * @notice Enables batch extension of multiple loans. It limits the number of loan offers that can be extended in one batch.
    * @param _loanOffers Array of loan offers to be extended.
    * @param _signatures Array of signatures corresponding to each loan offer.
    * @param _tokens Array of tokens associated with each loan offer.
    * @param _tokenSignatures Array of signatures corresponding to each token.
    */
    function batchExtend(
        LibLending.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLending.Token[] calldata _tokens,
        bytes[] calldata _tokenSignatures
    )
    whenNotPaused
    nonReentrant
    assertNotContract
    external
    {
        uint256 len = _loanOffers.length;
        require(len <= 20, "exceeded the limits");
        for (uint64 i; i < len; ++i) {
            extend(_loanOffers[i], _signatures[i], _tokens[i],_tokenSignatures[i]);
        }
    }

    /**
    * @notice Allows for the batch extension of multiple loans with Ether payment. It also enforces a limit on the number of loan offers that can be extended in one go.
    * @param _loanOffers Array of loan offers to be extended.
    * @param _signatures Array of signatures for each loan offer.
    * @param _tokens Array of tokens related to each loan offer.
    * @param _tokenSignatures Array of signatures for each token, confirming authenticity.
    */
    function batchExtendETH(
        LibLending.LoanOffer[] calldata _loanOffers,
        bytes[] calldata _signatures,
        LibLending.Token[] calldata _tokens,
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
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        for (uint64 i; i < len; ++i) {
            extend(_loanOffers[i], _signatures[i], _tokens[i],_tokenSignatures[i]);
        }
    }

    /**
    * @notice Extends an existing loan offer. This function is internal and checks that the loan has not been cancelled.
    * @param _loanOffer The loan offer to be extended.
    * @param signature The signature of the lender for validation.
    * @param token The token associated with the NFT for the loan.
    * @param tokenSignature The signature for the token, ensuring its authenticity.
    */
    function extend(LibLending.LoanOffer memory _loanOffer, bytes memory signature, LibLending.Token memory token, bytes memory tokenSignature)
    internal
    isNotCancelled(LibLending.hashKey(_loanOffer))
    {
        require(items[_loanOffer.nftContractAddress][token.tokenId].borrower == msg.sender, "there is no collateralized item belongs to msg.sender");

        validateLoanOffer(_loanOffer, token, tokenSignature);

        address lender = _validate(_loanOffer, signature);
        require(msg.sender != lender, "signer cannot borrow from own loan offer");


        uint256 fee = IAssetManager(assetManager).payLandingFee(lender, _loanOffer.amount);

        IAssetManager(assetManager).transferFrom(lender, msg.sender, _loanOffer.amount - fee);

        uint256 payment = _calculateRepayment(items[_loanOffer.nftContractAddress][token.tokenId].amount, items[_loanOffer.nftContractAddress][token.tokenId].rate);
        emit Extend(_loanOffer.nftContractAddress, token.tokenId, _loanOffer.salt, _loanOffer.amount, fee, payment);

        // payment sent to previous lender
        IAssetManager(assetManager).transferFrom(msg.sender, items[_loanOffer.nftContractAddress][token.tokenId].lender, payment);

        items[_loanOffer.nftContractAddress][token.tokenId].lender = lender;
        items[_loanOffer.nftContractAddress][token.tokenId].amount = _loanOffer.amount;
        items[_loanOffer.nftContractAddress][token.tokenId].duration = lendingPools[_loanOffer.nftContractAddress].duration;
        items[_loanOffer.nftContractAddress][token.tokenId].rate = lendingPools[_loanOffer.nftContractAddress].rate;
        items[_loanOffer.nftContractAddress][token.tokenId].startedAt = block.timestamp;
    }

    /**
    * @notice Allows borrowing against an NFT based on a loan offer. This function is internal and ensures the loan has not already been taken and not been cancelled.
    * @param _loanOffer The loan offer against which the NFT is being borrowed.
    * @param signature The lender's signature for validation.
    * @param token The token information of the NFT being used as collateral.
    * @param tokenSignature The signature validating the token's authenticity.
    */
    function borrow(LibLending.LoanOffer memory _loanOffer, bytes memory signature, LibLending.Token memory token, bytes memory tokenSignature)
    internal
    isNotCancelled(LibLending.hashKey(_loanOffer))
    {
        require(items[_loanOffer.nftContractAddress][token.tokenId].startedAt == 0, "has been already borrowed");

        validateLoanOffer(_loanOffer, token, tokenSignature);

        address lender = _validate(_loanOffer, signature);
        require(msg.sender != lender, "signer cannot redeem own coupon");

        IAssetManager(assetManager).nftTransferFrom(msg.sender, address(this), _loanOffer.nftContractAddress, token.tokenId);

        uint256 fee = IAssetManager(assetManager).payLandingFee(lender, _loanOffer.amount);
        emit Borrow(_loanOffer.nftContractAddress, token.tokenId, _loanOffer.salt, _loanOffer.amount, fee);

        IAssetManager(assetManager).transferFrom(lender, msg.sender, _loanOffer.amount - fee);

        items[_loanOffer.nftContractAddress][token.tokenId].borrower = msg.sender;
        items[_loanOffer.nftContractAddress][token.tokenId].lender = lender;
        items[_loanOffer.nftContractAddress][token.tokenId].amount = _loanOffer.amount;
        items[_loanOffer.nftContractAddress][token.tokenId].duration = lendingPools[_loanOffer.nftContractAddress].duration;
        items[_loanOffer.nftContractAddress][token.tokenId].rate = lendingPools[_loanOffer.nftContractAddress].rate;
        items[_loanOffer.nftContractAddress][token.tokenId].startedAt = block.timestamp;
    }

    /**
    * @notice Repays the loan for a specific NFT and returns the NFT to the borrower. This function is internal.
    * @param nftContractAddress The address of the NFT contract.
    * @param _tokenId The ID of the token (NFT) for which the loan is being repaid.
    */
    function repay(address nftContractAddress, uint256 _tokenId) internal {
        address borrower = items[nftContractAddress][_tokenId].borrower;
        address lender = items[nftContractAddress][_tokenId].lender;
        require(borrower == msg.sender, "msg.sender is not borrower");

        uint256 payment = _calculateRepayment(items[nftContractAddress][_tokenId].amount, items[nftContractAddress][_tokenId].rate);

        emit Repay(nftContractAddress, _tokenId, payment);

        IAssetManager(assetManager).transferFrom(borrower, lender, payment);

        IAssetManager(assetManager).nftTransferFrom(address(this), borrower, nftContractAddress, _tokenId);

        delete items[nftContractAddress][_tokenId];
    }

    /**
    * @notice Clears the debt associated with a specific NFT after the loan period has finished. This function is internal.
    * @param nftContractAddress The address of the NFT contract.
    * @param _tokenId The ID of the token (NFT) for which the debt is being cleared.
    */
    function clearDebt(address nftContractAddress, uint256 _tokenId) internal {
        address lender = items[nftContractAddress][_tokenId].lender;
        require(lender == msg.sender, "msg.sender is not lender");
        require((block.timestamp - items[nftContractAddress][_tokenId].startedAt) > items[nftContractAddress][_tokenId].duration, "loan period is not finished");

        emit ClearDebt(nftContractAddress, _tokenId);

        IAssetManager(assetManager).nftTransferFrom(address(this), lender, nftContractAddress, _tokenId);

        delete items[nftContractAddress][_tokenId];
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
    function _validate(LibLending.LoanOffer memory _loanOffer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibLending.hash(_loanOffer);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Validates a loan offer and corresponding token. This internal function ensures the loan offer and token meet various criteria including active pool, valid token signature, matching salts, sender authenticity, and signature expiry.
    * @param _loanOffer The loan offer to validate.
    * @param _token The token associated with the loan offer.
    * @param _tokenSignature The signature of the token.
    */
    function validateLoanOffer(LibLending.LoanOffer memory _loanOffer, LibLending.Token memory _token, bytes memory _tokenSignature) internal {
        require(_loanOffer.amount > 0, "lend amount cannot be 0");
        require(lendingPools[_loanOffer.nftContractAddress].isActive, "pool is not active");
        require(_hashTypedDataV4(LibLending.hashToken(_token)).recover(_tokenSignature) == validator, "token signature is not valid");
        require(keccak256(abi.encodePacked(_token.salt)) == keccak256(abi.encodePacked(_loanOffer.salt)), "salt does not match");
        require(_token.sender == msg.sender, "token signature does not belong to msg.sender");
        require(_token.blockNumber + blockRange > block.number, "token signature has been expired");

        bytes32 hash = LibLending.hashKey(_loanOffer);

        require(_loanOffer.size > sizes[hash], "size is filled");
        sizes[hash] += 1;
    }

    /**
    * @notice Calculates a portion of a bid based on a percentage. This internal pure function is used for fee calculations.
    * @param _totalBid The total bid amount.
    * @param _percentage The percentage to calculate the portion of the bid.
    * @return The calculated portion of the bid.
    */
    function _getPortionOfBid(uint256 _totalBid, uint96 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    /**
    * @notice Calculates the total repayment amount including interest. This internal pure function is used for calculating loan repayments.
    * @param _totalBid The principal amount of the loan.
    * @param _interest The interest rate applied to the loan.
    * @return The total repayment amount.
    */
    function _calculateRepayment(uint256 _totalBid, uint256 _interest) internal pure returns (uint256) {
        return _totalBid + ((_totalBid * (_interest)) / 1 ether);
    }

    /**
    * @notice Ensures that the function caller is not a smart contract, allowing only EOA (Externally Owned Accounts) calls.
    */
    modifier assertNotContract() {
        require(msg.sender == tx.origin, 'Error: Unauthorized smart contract access');
        _;
    }

    /**
    * @notice Ensures that the function caller is the specified signer.
    * @param _signer The address required to be the function caller.
    */
    modifier onlySigner(address _signer) {
        require(msg.sender == _signer, "Only signer");
        _;
    }

    /**
    * @notice Checks that a given order has not been cancelled or already redeemed.
    * @param _orderKeyHash The hash key of the order.
    */
    modifier isNotCancelled(bytes32 _orderKeyHash) {
        require(!fills[_orderKeyHash], "order has already redeemed or cancelled");
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
}