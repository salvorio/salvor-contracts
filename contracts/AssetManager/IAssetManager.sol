// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

interface IAssetManager {
	function deposit(address _user) external payable;
	function transferFrom(address _from, address _to, uint256 _amount) external;
	function payLandingFee(address _user, uint256 _price) external returns(uint256);
	function payMP(address _buyer, address _seller, address _collection, uint256 _tokenId, uint256 _price) external;
	function nftTransferFrom(address _from, address _to, address _collection, uint256 _tokenId) external;
}
