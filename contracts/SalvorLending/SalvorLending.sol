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

contract SalvorLending is Initializable, ERC721HolderUpgradeable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    struct LendingPool {
        uint256 duration;
        uint256 rate;
        uint96 protocolFee;
        bool isActive;
    }

    struct Loan {
        address borrower;
        address lender;
        uint256 amount;
        uint256 duration;
        uint256 rate;
        uint256 startedAt;
    }

    string private constant SIGNING_DOMAIN = "SalvorLending";
    string private constant SIGNATURE_VERSION = "1";
    using ECDSAUpgradeable for bytes32;

    mapping(address => LendingPool) public lendingPools;
    mapping(address => mapping(uint256 => Loan)) public items;

    mapping(bytes32 => bool) public fills;

    mapping(bytes32 => uint256) public sizes;

    address public validator;

    address public admin;

    address public assetManager;

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setAdmin(address _admin) external onlyOwner addressIsNotZero(_admin) {
        admin = _admin;
    }

    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
    }

    function setValidator(address _validator) external onlyOwner addressIsNotZero(_validator) {
        validator = _validator;
    }

    function setAssetManager(address _assetManager) external onlyOwner addressIsNotZero(_assetManager) {
        assetManager = _assetManager;
    }

	function setPool(address _collection, uint96 _protocolFee, uint256 _duration, uint256 _rate, bool _isActive) external {
        require(msg.sender == owner() || msg.sender == admin, "not authorized");
        lendingPools[_collection].duration = _duration;
        lendingPools[_collection].protocolFee = _protocolFee;
        lendingPools[_collection].rate = _rate;
        lendingPools[_collection].isActive = _isActive;
        IERC721Upgradeable(_collection).setApprovalForAll(assetManager, true);
        emit SetPool(_collection, _protocolFee, _duration, _rate, _isActive);
    }

    function cancelLoans(LibLending.LoanOffer[] calldata _loanOffers, bytes[] calldata _signatures) external onlyOwner whenNotPaused nonReentrant {
        uint256 len = _loanOffers.length;
        for (uint256 i; i < len; ++i) {
            cancelLoan(_loanOffers[i], _signatures[i]);
        }
    }


    function cancelLoan(LibLending.LoanOffer calldata _loanOffer, bytes memory _signature)
        internal
        onlySigner(_validate(_loanOffer, _signature))
        isNotCancelled(LibLending.hashKey(_loanOffer))
    {
        bytes32 loanKeyHash = LibLending.hashKey(_loanOffer);
        fills[loanKeyHash] = true;
        emit CancelLoan(_loanOffer.nftContractAddress, _loanOffer.salt, loanKeyHash);
    }

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

    function clearDebt(address nftContractAddress, uint256 _tokenId) internal {
        address lender = items[nftContractAddress][_tokenId].lender;
        require(lender == msg.sender, "msg.sender is not lender");
        require((block.timestamp - items[nftContractAddress][_tokenId].startedAt) > items[nftContractAddress][_tokenId].duration, "loan period is not finished");

        emit ClearDebt(nftContractAddress, _tokenId);

        IAssetManager(assetManager).nftTransferFrom(address(this), lender, nftContractAddress, _tokenId);

        delete items[nftContractAddress][_tokenId];
    }

    function getChainId() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    function _validate(LibLending.LoanOffer memory _loanOffer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibLending.hash(_loanOffer);
        return _hashTypedDataV4(hash).recover(signature);
    }

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

    function _getPortionOfBid(uint256 _totalBid, uint96 _percentage) internal pure returns (uint256) { return (_totalBid * (_percentage)) / 10000; }

    function _calculateRepayment(uint256 _totalBid, uint256 _interest) internal pure returns (uint256) {
        return _totalBid + ((_totalBid * (_interest)) / 1 ether);
    }

    modifier assertNotContract() {
        require(msg.sender == tx.origin, 'Error: Unauthorized smart contract access');
        _;
    }

    modifier onlySigner(address _signer) {
        require(msg.sender == _signer, "Only signer");
        _;
    }

    modifier isNotCancelled(bytes32 _orderKeyHash) {
        require(!fills[_orderKeyHash], "order has already redeemed or cancelled");
        _;
    }

    modifier addressIsNotZero(address _address) {
        require(_address != address(0), "Given address must be a non-zero address");
        _;
    }
}