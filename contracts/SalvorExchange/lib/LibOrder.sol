// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

library LibOrderV2 {

    bytes constant batchOrderTypeString = abi.encodePacked(
        "BatchOrder(",
        "string salt,",
        "address seller,",
        "Order[] orders",
        ")"
    );

    bytes constant offerTypeString = abi.encodePacked(
        "Offer(",
        "address nftContractAddress,",
        "address buyer,",
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
        "uint256 blockNumber,",
        "address sender,",
        "address nftContractAddress,",
        "string uuid,",
        "string salt,",
        "string traits",
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
        string salt; // uuid to provide uniqness
        address seller;
        Order[] orders; // When the nft is sold then the price will be split to the shareholders.
    }

    struct Offer {
        address nftContractAddress;
        address buyer;
        string salt;
        string traits;
        uint tokenId;
        uint bid;
        uint duration;
        uint size;
        uint startedAt;
        bool isCollectionOffer;
    }

    struct Token {
        uint tokenId;
        uint blockNumber;
        address sender;
        address nftContractAddress;
        string uuid;
        string salt;
        string traits;
    }

    function hash(BatchOrder memory batchOrder) internal pure returns (bytes32) {
        bytes32[] memory orderHashes = new bytes32[](batchOrder.orders.length);
        for (uint256 i = 0; i < batchOrder.orders.length; i++) {
            orderHashes[i] = _hashOrderItem(batchOrder.orders[i]);
        }
        return keccak256(abi.encode(
            BATCH_ORDER_TYPEHASH,
            keccak256(bytes(batchOrder.salt)),
            batchOrder.seller,
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

    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            OFFER_TYPEHASH,
            offer.nftContractAddress,
            offer.buyer,
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

    function hashToken(Token memory token) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TOKEN_TYPEHASH,
            token.tokenId,
            token.blockNumber,
            token.sender,
            token.nftContractAddress,
            keccak256(bytes(token.uuid)),
            keccak256(bytes(token.salt)),
            keccak256(bytes(token.traits))
        ));
    }
}