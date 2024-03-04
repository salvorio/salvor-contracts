// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

library LibLending {

    bytes constant orderTypeString = abi.encodePacked(
        "LoanOffer(",
        "address nftContractAddress,",
        "string salt,",
        "string traits,",
        "uint256 duration,",
        "uint256 amount,",
        "uint256 size",
        ")"
    );

    bytes32 constant ORDER_TYPEHASH = keccak256(orderTypeString);

    bytes constant tokenTypeString = abi.encodePacked(
        "Token(",
        "uint256 tokenId,",
        "string salt,",
        "string traits,",
        "uint256 blockNumber,"
        "address borrower,"
        "address nftContractAddress,",
        "address lender",
        ")"
    );

    bytes32 constant TOKEN_TYPEHASH = keccak256(tokenTypeString);

    struct LoanOffer {
        address nftContractAddress;
        string salt;
        string traits;
        uint duration;
        uint amount;
        uint size;
    }

    struct Token {
        uint256 tokenId;
        string salt;
        string traits;
        uint blockNumber;
        address borrower;
        address nftContractAddress;
        address lender;
    }

    function hash(LoanOffer memory loan) internal pure returns (bytes32) {
        return keccak256(abi.encode(
                ORDER_TYPEHASH,
                loan.nftContractAddress,
                keccak256(bytes(loan.salt)),
                keccak256(bytes(loan.traits)),
                loan.duration,
                loan.amount,
                loan.size
            ));
    }

    function hashKey(LoanOffer memory _loan) internal pure returns (bytes32) {
        return keccak256(abi.encode(_loan.nftContractAddress, _loan.salt));
    }

    function hashToken(Token memory token) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TOKEN_TYPEHASH,
            token.tokenId,
            keccak256(bytes(token.salt)),
            keccak256(bytes(token.traits)),
            token.blockNumber,
            token.borrower,
            token.nftContractAddress,
            token.lender
        ));
    }
}