//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../Royalty/LibRoyalty.sol";

interface INFTCollectible {
    function mint(string memory _tokenUri, LibRoyalty.Royalty[] memory _royalties) external returns (uint256);
    function owner() external returns (address);
    function getSalvorPowerMinMax() external returns (uint256, uint256);
}