// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;


library LibRoyalty {
    // calculated royalty
    struct Part {
        address account; // receiver address
        uint256 value; // receiver amount
    }

    // royalty information
    struct Royalty {
        address account; // receiver address
        uint96 value; // percentage of the royalty
    }
}