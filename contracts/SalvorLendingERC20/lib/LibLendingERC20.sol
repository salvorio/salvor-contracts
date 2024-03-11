// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

library LibLendingERC20 {

    bytes constant orderTypeString = abi.encodePacked(
        "LoanOffer(",
        "address lender,",
        "address collateralizedAsset,",
        "string salt,",
        "uint256 amount,",
        "uint256 price,",
        "uint256 startedAt,",
        "uint256 duration,",
        "uint256 rate"
        ")"
    );

    bytes32 constant ORDER_TYPEHASH = keccak256(orderTypeString);

    bytes constant tokenTypeString = abi.encodePacked(
        "Token(",
        "bytes32 orderHash,",
        "uint256 blockNumber,",
        "uint256 amount,",
        "address borrower"
        ")"
    );

    bytes32 constant TOKEN_TYPEHASH = keccak256(tokenTypeString);

    struct LoanOffer {
        address lender;
        address collateralizedAsset;
        string salt;
        uint amount;
        uint price;
        uint startedAt;
        uint duration;
        uint rate;
    }

    struct Token {
        bytes32 orderHash;
        uint blockNumber;
        uint amount;
        address borrower;
    }

    function hash(LoanOffer memory loan) internal pure returns (bytes32) {
        return keccak256(abi.encode(
                ORDER_TYPEHASH,
                loan.lender,
                loan.collateralizedAsset,
                keccak256(bytes(loan.salt)),
                loan.amount,
                loan.price,
                loan.startedAt,
                loan.duration,
                loan.rate
            ));
    }

    function hashToken(Token memory token) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TOKEN_TYPEHASH,
            token.orderHash,
            token.blockNumber,
            token.amount,
            token.borrower
        ));
    }
}