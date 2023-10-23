// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./LibRoyalty.sol";
/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IRoyalty {
    event RoyaltiesSet(uint256 indexed tokenId, LibRoyalty.Royalty[] royalties, LibRoyalty.Royalty[] previousRoyalties);

    event DefaultRoyaltiesSet(LibRoyalty.Royalty[] royalties, LibRoyalty.Royalty[] previousRoyalties);

    function getDefaultRoyalties() external view returns (LibRoyalty.Royalty[] memory);

    function getTokenRoyalties(uint256 _tokenId) external view returns (LibRoyalty.Royalty[] memory);

    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view returns (address receiver, uint256 royaltyAmount);

    function multiRoyaltyInfo(uint256 _tokenId, uint256 _salePrice) external view returns (LibRoyalty.Part[] memory);

    function setDefaultRoyaltyReceiver(address _defaultRoyaltyReceiver) external;

    function setDefaultRoyalties(LibRoyalty.Royalty[] memory _defaultRoyalties) external;

    function saveRoyalties(uint256 _tokenId, LibRoyalty.Royalty[] memory _royalties) external;
}
