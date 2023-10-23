// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

// contains information about revenue share on each sale
library LibShareholder {
    struct Shareholder {
        address account; // receiver wallet address
        uint96 value; // percentage of share
    }
}
