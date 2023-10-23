//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import "./LibStructSalvor.sol";
interface ISalvorNFTCollection {
    function getSalvor(uint256 tokenId) external view returns (LibStructSalvor.Salvor memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address _from, address _to, uint256 tokenId) external;
}