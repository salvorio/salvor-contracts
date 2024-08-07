// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

interface IAssetManager {
	struct PaymentInfo {
		address buyer;
		address seller;
		address collection;
		uint256 tokenId;
		uint256 price;
	}
	struct LendingPaymentInfo {
		address lender;
		address previousLender;
		address borrower;
		address collection;
		uint256 tokenId;
		uint256 amount;
		uint256 repaymentAmount;
	}
	struct LendingPaymentInfoV2 {
		address lender;
		address previousLender;
		address borrower;
		address collection;
		uint256 tokenId;
		uint256 amount;
		uint256 repaymentAmount;
		uint256 delegatedAmount;
	}
	function deposit(address _user) external payable;
	function lendingRepayBatch(LendingPaymentInfo[] memory _transfers) external;
	function payLendingBatch(LendingPaymentInfo[] memory _lendingPayments) external;
	function dutchPay(address _nftContractAddress, uint256 _tokenId, address bidder, address lender, uint256 bid, uint256 endPrice) external;
	function payLendingDelegatedBatch(LendingPaymentInfoV2[] memory _lendingPayments) external;
	function dutchPayV2(address _nftContractAddress, uint256 _tokenId, address bidder, address lender, uint256 bid, uint256 endPrice, uint256 delegatedAmount) external;
	function lendingRepayBatchV2(LendingPaymentInfoV2[] memory _transfers) external;
	function payLendingBatchV2(LendingPaymentInfoV2[] memory _lendingPayments) external;
	function payMP(address _buyer, address _seller, address _collection, uint256 _tokenId, uint256 _price) external;
	function nftTransferFrom(address _from, address _to, address _collection, uint256 _tokenId) external;
	function payMPBatch(PaymentInfo[] memory _payments) external;
	function transferFrom(address _from, address _to, uint256 _amount) external;
	function payERC20Lending(address _lender, address _borrower, uint256 _amount) external;
}