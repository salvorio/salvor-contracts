//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

interface ISalvorOperator {
    struct Salvor {
        uint32 level;
        uint32 rarityScore;
    }
    function callbackRandomWord(uint256 _requestId, uint256[] calldata _randomWords) external;
    function getSalvorPower(uint256 _tokenId) external view returns (uint256);
    function getSalvorAttribute(uint256 _tokenId) external view returns (Salvor memory);
}