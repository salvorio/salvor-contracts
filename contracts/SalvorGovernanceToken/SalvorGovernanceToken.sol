//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract SalvorGovernanceToken is ERC20, ERC20Snapshot, Ownable {
    bool public minted;

    constructor(string memory tokenName, string memory symbol) ERC20(tokenName, symbol) {
        minted = false;
    }

    function initialMint(address[] memory receivers, uint256[] memory values) external onlyOwner {
        require(!minted, "Tokens have already been minted");
        require(receivers.length == values.length, "Receivers-Values mismatch");

        minted = true;

        for (uint i = 0; i < receivers.length; i++) {
            _mint(receivers[i], values[i]);
        }

        emit SalvorTokenMinted();
    }

    function snapshot() external onlyOwner returns (uint256) {
        return _snapshot();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
    internal
    override(ERC20, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal override {
        super._mint(to, amount);
    }

    event SalvorTokenMinted();
}