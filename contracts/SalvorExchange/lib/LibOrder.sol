// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "../../libs/LibShareholder.sol";

library LibOrder {

    bytes constant batchOrderTypeString = abi.encodePacked(
        "BatchOrder(",
        "string salt,",
        "Order[] orders",
        ")"
    );

    bytes constant offerTypeString = abi.encodePacked(
        "Offer(",
        "address nftContractAddress,",
        "string salt,",
        "string traits,",
        "uint256 tokenId,",
        "uint256 bid,",
        "uint256 duration,",
        "uint256 size,",
        "uint256 startedAt,",
        "bool isCollectionOffer",
        ")"
    );

    bytes constant orderTypeString = abi.encodePacked(
        "Order(",
        "address nftContractAddress,",
        "string salt,",
        "uint256 tokenId,",
        "uint256 price,",
        "uint256 duration,",
        "uint256 startedAt",
        ")"
    );

    bytes constant tokenTypeString = abi.encodePacked(
        "Token(",
        "uint256 tokenId,",
        "string salt,",
        "string traits,",
        "uint256 blockNumber,"
        "address sender"
        ")"
    );

    bytes32 constant OFFER_TYPEHASH = keccak256(offerTypeString);

    bytes32 constant BATCH_ORDER_TYPEHASH = keccak256(abi.encodePacked(batchOrderTypeString, orderTypeString));

    bytes32 constant ORDER_TYPEHASH = keccak256(orderTypeString);

    bytes32 constant TOKEN_TYPEHASH = keccak256(tokenTypeString);

    struct Order {
        address nftContractAddress; // nft contract address
        string salt; // uuid to provide uniquness
        uint tokenId; // nft tokenId
        uint price; // listing price
        uint duration;
        uint startedAt;
    }

    struct BatchOrder {
        string salt; // uuid to provide uniquness
        Order[] orders; // When the nft is sold then the price will be split to the shareholders.
    }

    struct Offer {
        address nftContractAddress; // Address of the NFT contract.
        string salt; // Unique identifier to ensure the offer's uniqueness.
        string traits; // Specific traits or characteristics of the NFT, if applicable.
        uint tokenId; // The token ID of the NFT within the contract.
        uint bid; // The amount bid for the NFT.
        uint duration; // Duration of the offer in blocks or time units.
        uint size; // The size or quantity of the offer.
        uint startedAt; // Timestamp or block number indicating when the offer started.
        bool isCollectionOffer; // Indicates if the offer is for an entire collection.
    }

    struct Token {
        uint256 tokenId; // The token ID of the NFT.
        string salt; // Unique identifier associated with the token.
        string traits; // Specific traits or characteristics of the NFT.
        uint blockNumber; // The block number when the token was recorded or transferred.
        address sender; // The address that sent or created the token.
    }

    function hash(BatchOrder memory batchOrder) internal pure returns (bytes32) {
        bytes32[] memory orderHashes = new bytes32[](batchOrder.orders.length);
        for (uint256 i = 0; i < batchOrder.orders.length; i++) {
            orderHashes[i] = _hashOrderItem(batchOrder.orders[i]);
        }
        return keccak256(abi.encode(
                BATCH_ORDER_TYPEHASH,
                keccak256(bytes(batchOrder.salt)),
                keccak256(abi.encodePacked(orderHashes))
            ));
    }

    function _hashOrderItem(Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(
                ORDER_TYPEHASH,
                order.nftContractAddress,
                keccak256(bytes(order.salt)),
                order.tokenId,
                order.price,
                order.duration,
                order.startedAt
            ));
    }

    function hashKey(Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order.nftContractAddress, order.salt));
    }

    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            OFFER_TYPEHASH,
            offer.nftContractAddress,
            keccak256(bytes(offer.salt)),
            keccak256(bytes(offer.traits)),
            offer.tokenId,
            offer.bid,
            offer.duration,
            offer.size,
            offer.startedAt,
            offer.isCollectionOffer
        ));
    }

    function hashOfferKey(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(abi.encode(offer.nftContractAddress, offer.salt));
    }

    function hashToken(Token memory token) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TOKEN_TYPEHASH,
            token.tokenId,
            keccak256(bytes(token.salt)),
            keccak256(bytes(token.traits)),
            token.blockNumber,
            token.sender
        ));
    }
}