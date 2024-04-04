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
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../AssetManager/IAssetManager.sol";
import "./lib/LibLendingERC20.sol";

/**
* @title Salvor Lending ERC20
* @notice Operates on the Ethereum-based blockchain, providing a lending pool platform where users can lend and borrow NFTs. Each pool is characterized by parameters such as the duration of the loan, interest rate.
*/
contract SalvorLendingERC20 is Initializable, EIP712Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {

    // Structure defining an individual loan
    struct Loan {
        uint256 lentAmount;
        uint256 collateralizedAmount;
        uint256 duration;
        uint256 rate;
        uint256 startedAt;
    }

    string private constant SIGNING_DOMAIN = "SalvorLendingERC20";
    string private constant SIGNATURE_VERSION = "1";
    using ECDSAUpgradeable for bytes32;
    // borrower => collateralizedAsset => lender => salt => Loan
    mapping(address => mapping(address => mapping(address => mapping(string => Loan)))) public loans;

    // Mapping that stores the sizes of loans or assets, identified by a unique bytes32 hash
    mapping(bytes32 => uint256) public sizes;

    // Address of the validator, responsible for certain administrative functions or validations within the contract
    address public validator;

    // Address of the asset manager, responsible for managing the assets within the lending pools
    address public assetManager;

    // Defines the range of blocks within which certain operations or validations must be performed
    uint256 public blockRange;

    // Mapping to track which ERC20 token addresses are allowed as collateral for loans.
    mapping(address => bool) public allowedAssets;

    mapping(bytes32 => bool) public fills;

    // events
    event Borrow(address indexed borrower, address indexed collateralizedAsset, address indexed lender, string salt, uint256 collateralizedAmount, uint256 lentAmount);
    event Repay(address indexed borrower, address indexed collateralizedAsset, address indexed lender, string salt, uint256 repaidAmount);
    event ClearDebt(address indexed borrower, address indexed collateralizedAsset, address indexed lender, string salt, uint256 amount);
    event Cancel(address indexed collateralizedAsset, address indexed lender, string salt);
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
    * @notice Updates the block range parameter within the contract. This action can only be performed by the contract owner.
    * @param _blockRange The new block range value to be set.
    */
    function setBlockRange(uint256 _blockRange) external onlyOwner {
        blockRange = _blockRange;
    }

    /**
    * @notice Allows the contract owner to set whether an ERC20 token address is allowed as collateral.
    * @param asset The address of the ERC20 token to be set as allowed or disallowed.
    * @param isActive A boolean indicating whether the asset is allowed (true) or not (false).
    */
    function setAllowedAsset(address asset, bool isActive) external onlyOwner {
        allowedAssets[asset] = isActive;
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

    function _validate(LibLendingERC20.LoanOffer memory _loanOffer, bytes memory signature) public view returns (address) {
        bytes32 hash = LibLendingERC20.hash(_loanOffer);
        return _hashTypedDataV4(hash).recover(signature);
    }

    /**
    * @notice Allows a borrower to take out a loan by providing a valid loan offer, the corresponding signatures, and the token details.
    * @param _loanOffer The loan offer struct containing the loan terms.
    * @param signature The signature of the lender verifying the loan offer.
    * @param token The token struct containing the details of the ERC20 token used for the loan.
    * @param tokenSignature The signature of the borrower verifying the token details.
    */
    function borrow(LibLendingERC20.LoanOffer memory _loanOffer, bytes memory signature, LibLendingERC20.Token memory token, bytes memory tokenSignature)
        nonReentrant
        whenNotPaused
        external
    {
        Loan storage loan = loans[msg.sender][_loanOffer.collateralizedAsset][_loanOffer.lender][_loanOffer.salt];
        require(loan.startedAt == 0, "has been already borrowed");

        validateLoanOffer(_loanOffer, signature, token, tokenSignature);

        uint256 collateralizedAmount = (token.amount * 1 ether) / _loanOffer.price;

        emit Borrow(msg.sender, _loanOffer.collateralizedAsset, _loanOffer.lender, _loanOffer.salt, collateralizedAmount, token.amount);
        SafeERC20Upgradeable.safeTransferFrom(IERC20Upgradeable(_loanOffer.collateralizedAsset), msg.sender, address(this), collateralizedAmount);
        IAssetManager(assetManager).payERC20Lending(_loanOffer.lender, msg.sender, token.amount);

        loan.rate = _loanOffer.rate;
        loan.lentAmount = token.amount;
        loan.collateralizedAmount = collateralizedAmount;
        loan.startedAt = block.timestamp;
        loan.duration = _loanOffer.duration;
    }

    /**
    * @notice Allows a borrower to repay an active loan, returning the collateral and settling the debt.
    * @param _collateralizedAsset The address of the ERC20 token used as collateral for the loan.
    * @param _lender The address of the lender.
    * @param _salt A unique identifier for the loan, used to differentiate between loans with the same borrower, lender, and collateral.
    */
    function repay(address _collateralizedAsset, address _lender, string memory _salt) whenNotPaused nonReentrant public {
        Loan memory loan = loans[msg.sender][_collateralizedAsset][_lender][_salt];

        require(loan.startedAt > 0, "there is not any active loan");

        uint256 payment = calculateRepayment(msg.sender, _collateralizedAsset, _lender, _salt);

        emit Repay(msg.sender, _collateralizedAsset, _lender, _salt, payment);
        IAssetManager(assetManager).transferFrom(msg.sender, _lender, payment);
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_collateralizedAsset), msg.sender, loan.collateralizedAmount);
        delete loans[msg.sender][_collateralizedAsset][_lender][_salt];
    }

    /**
	* @notice Allows a borrower to repay an active loan using ETH, which is then converted to the ERC20 token used as collateral.
    * @param _collateralizedAsset The address of the ERC20 token used as collateral for the loan.
    * @param _lender The address of the lender.
    * @param _salt A unique identifier for the loan, used to differentiate between loans with the same borrower, lender, and collateral.
    */
    function repayETH(address _collateralizedAsset, address _lender, string memory _salt) external payable {
        IAssetManager(assetManager).deposit{ value: msg.value }(msg.sender);
        repay(_collateralizedAsset, _lender, _salt);
    }

    /**
    * @notice Allows a lender to claim the collateral of a loan if the borrower has not repaid the loan after the loan period has ended.
    * @param _collateralizedAsset The address of the ERC20 token used as collateral for the loan.
    * @param _borrower The address of the borrower.
    * @param _salt A unique identifier for the loan, used to differentiate between loans with the same borrower, lender, and collateral.
    */
    function clearDebt(address _collateralizedAsset, address _borrower, string memory _salt) whenNotPaused nonReentrant external {
        Loan memory loan = loans[_borrower][_collateralizedAsset][msg.sender][_salt];

        require(loan.startedAt > 0, "there is not any active loan");
        require(block.timestamp > (loan.duration + loan.startedAt), "loan period is not finished");

        emit ClearDebt(_borrower, _collateralizedAsset, msg.sender, _salt, loan.collateralizedAmount);
        SafeERC20Upgradeable.safeTransfer(IERC20Upgradeable(_collateralizedAsset), msg.sender, loan.collateralizedAmount);

        delete loans[_borrower][_collateralizedAsset][msg.sender][_salt];
    }

    function cancelOffer(LibLendingERC20.LoanOffer memory loanOffer, bytes memory signature) whenNotPaused nonReentrant external {
        require(loanOffer.startedAt > 0, "non existent offer");
        address lender = _validate(loanOffer, signature);
        require(msg.sender == lender, "msg.sender is not authorized");
        require(loanOffer.lender == lender, "lender does not match");

        bytes32 hash = LibLendingERC20.hash(loanOffer);

        require(!fills[hash], "order has been already cancelled");
        fills[hash] = true;

        emit Cancel(loanOffer.collateralizedAsset, loanOffer.lender, loanOffer.salt);
    }

    /**
    * @notice Validates a loan offer and the associated token details provided by the borrower.
    * @dev This function checks various conditions such as the allowed assets, loan and token amounts, loan duration, and signatures.
    * @param _loanOffer The loan offer struct containing the loan terms.
    * @param signature The signature of the lender verifying the loan offer.
    * @param _token The token struct containing the details of the ERC20 token used for the loan.
    * @param _tokenSignature The signature of the borrower verifying the token details.
    */
    function validateLoanOffer(LibLendingERC20.LoanOffer memory _loanOffer, bytes memory signature, LibLendingERC20.Token memory _token, bytes memory _tokenSignature) internal {
        require(allowedAssets[_loanOffer.collateralizedAsset], "collateralized asset is not allowed");
        require(_loanOffer.amount >= 1 ether, "insufficient lent amount");
        require(_loanOffer.duration >= 86400, "at least a day");
        require(_token.amount >= 1 ether, "insufficient amount requested");
        bytes32 hash = LibLendingERC20.hash(_loanOffer);
        require(hash == _token.orderHash, "hash does not match");
        address lender = _validate(_loanOffer, signature);
        require(msg.sender != lender, "signer cannot borrow from own loan offer");
        require(_loanOffer.lender == lender, "lender does not match");
        require(msg.sender == _token.borrower, "token and borrower does not match");
        require(_hashTypedDataV4(LibLendingERC20.hashToken(_token)).recover(_tokenSignature) == validator, "token signature is not valid");
        require(_token.blockNumber + blockRange > block.number, "token signature has been expired");
        sizes[hash] += _token.amount;
        require(_loanOffer.amount >= sizes[hash], "size is filled");
        require(!fills[hash], "offer has been cancelled");
    }

    /**
    * @notice Generates a hash for a loan offer using the library's hashing function.
    * @param _loanOffer The loan offer struct containing the loan terms.
    * @return The hash of the loan offer.
    */
    function hashOrder(LibLendingERC20.LoanOffer memory _loanOffer) external pure returns(bytes32) {
        return LibLendingERC20.hash(_loanOffer);
    }

    /**
    * @notice Calculates the repayment amount for a loan based on the elapsed time and the agreed interest rate.
    * @param _borrower The address of the borrower.
    * @param _collateralizedAsset The address of the ERC20 token used as collateral for the loan.
    * @param _lender The address of the lender.
    * @param _salt A unique identifier for the loan, used to differentiate between loans with the same borrower, lender, and collateral.
    * @return The total repayment amount, including the principal and accrued interest.
    */
    function calculateRepayment(address _borrower, address _collateralizedAsset, address _lender, string memory _salt) public view returns (uint256) {
        Loan memory loan = loans[_borrower][_collateralizedAsset][_lender][_salt];

        uint256 elapsedDay = ((block.timestamp - loan.startedAt) / 86400) + 1;
        uint256 totalDays = loan.duration / 86400;
        if (totalDays <= elapsedDay) {
            return loan.lentAmount + ((loan.lentAmount * loan.rate) / 1 ether);
        } else {
            return loan.lentAmount + ((loan.lentAmount * loan.rate * elapsedDay) / (1 ether * totalDays));
        }
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