//SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

interface IVRFCoordinator {
    function requestRandomWords(uint32 _amount) external returns (uint256);
}