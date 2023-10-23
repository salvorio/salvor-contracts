//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../libs/LibShareholder.sol";

interface IPaymentManager {
    function payout(address payable _seller, address _nftContractAddress, uint256 _tokenId, LibShareholder.Shareholder[] memory _shareholders, uint96 _commissionPercentage) external payable;
    function getMaximumShareholdersLimit() external view returns (uint256);
    function depositFailedBalance(address _account) external payable;
    function getCommissionPercentage() external returns (uint96);
}