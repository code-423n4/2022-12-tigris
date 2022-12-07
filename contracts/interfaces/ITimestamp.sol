// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ITimestamp {
    function time() external view returns (uint256);
    function set(uint) external;
}