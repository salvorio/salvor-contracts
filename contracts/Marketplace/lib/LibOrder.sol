// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "../../libs/LibShareholder.sol";

library LibOrder {

    bytes constant orderTypeString = abi.encodePacked(
        "Order(",
        "address nftContractAddress,",
        "string salt,",
        "uint256 tokenId,",
        "uint256 price,",
        "Shareholder[] shareholders"
        ")"
    );

    bytes constant shareholderItemTypeString = abi.encodePacked(
        "Shareholder(",
        "address account,",
        "uint96 value",
        ")"
    );

    bytes32 constant ORDER_TYPEHASH = keccak256(
        abi.encodePacked(orderTypeString, shareholderItemTypeString)
    );

    bytes32 constant SHAREHOLDER_TYPEHASH = keccak256(
        shareholderItemTypeString
    );

    struct Order {
        address nftContractAddress; // nft contract address
        string salt; // uuid to provide uniquness
        uint tokenId; // nft tokenId
        uint price; // listing price
        LibShareholder.Shareholder[] shareholders; // When the nft is sold then the price will be split to the shareholders.
    }

    function hash(Order memory order) internal pure returns (bytes32) {
        bytes32[] memory shareholderHashes = new bytes32[](order.shareholders.length);
        for (uint256 i = 0; i < order.shareholders.length; i++) {
            shareholderHashes[i] = _hashShareholderItem(order.shareholders[i]);
        }
        return keccak256(abi.encode(
                ORDER_TYPEHASH,
                order.nftContractAddress,
                keccak256(bytes(order.salt)),
                order.tokenId,
                order.price,
                keccak256(abi.encodePacked(shareholderHashes))
            ));
    }

    function _hashShareholderItem(LibShareholder.Shareholder memory shareholder) internal pure returns (bytes32) {
        return keccak256(abi.encode(
                SHAREHOLDER_TYPEHASH,
                shareholder.account,
                shareholder.value
            ));
    }

    function hashKey(Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order.nftContractAddress, order.salt));
    }
}