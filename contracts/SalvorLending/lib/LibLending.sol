// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

library LibLendingV2 {

    bytes constant offerTypeString = abi.encodePacked(
        "LoanOffer(",
        "address nftContractAddress,",
        "address lender,",
        "string salt,",
        "string traits,",
        "uint256 duration,",
        "uint256 amount,",
        "uint256 size,",
        "uint256 startedAt",
        ")"
    );

    bytes32 constant OFFER_TYPEHASH = keccak256(offerTypeString);

    bytes constant tokenTypeString = abi.encodePacked(
        "Token(",
        "uint256 tokenId,",
        "string salt,",
        "string traits,",
        "uint256 blockNumber,",
        "address owner,",
        "address nftContractAddress,",
        "address lender",
        ")"
    );

    bytes32 constant TOKEN_TYPEHASH = keccak256(tokenTypeString);

    struct LoanOffer {
        address nftContractAddress;
        address lender;
        string salt;
        string traits;
        uint duration;
        uint amount;
        uint size;
        uint startedAt;
    }

    struct Token {
        uint256 tokenId;
        string salt;
        string traits;
        uint blockNumber;
        address owner;
        address nftContractAddress;
        address lender;
    }

    function hash(LoanOffer memory loanOffer) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            OFFER_TYPEHASH,
            loanOffer.nftContractAddress,
            loanOffer.lender,
            keccak256(bytes(loanOffer.salt)),
            keccak256(bytes(loanOffer.traits)),
            loanOffer.duration,
            loanOffer.amount,
            loanOffer.size,
            loanOffer.startedAt
        ));
    }

    function hashToken(Token memory token) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TOKEN_TYPEHASH,
            token.tokenId,
            keccak256(bytes(token.salt)),
            keccak256(bytes(token.traits)),
            token.blockNumber,
            token.owner,
            token.nftContractAddress,
            token.lender
        ));
    }
}