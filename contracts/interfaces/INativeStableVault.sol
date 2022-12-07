// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface INativeStableVault {
    function depositNative() external payable;
    function withdrawNative(uint256 _amount) external returns (uint256);
}