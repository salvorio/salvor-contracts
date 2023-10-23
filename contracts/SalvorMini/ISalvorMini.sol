//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ISalvorMini is IERC721 {
    function getRarityLevel(uint256 _tokenId) external view returns (uint256);
    function burn(uint256 _tokenId) external;
    function mint(address _receiver, uint256 _rarityLevel) external returns (uint256);
    function totalSupply() external view returns (uint256);
}