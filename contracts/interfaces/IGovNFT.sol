// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

interface IGovNFT {
    function distribute(address _tigAsset, uint256 _amount) external;
    function transferMany(address _to, uint[] calldata _ids) external;
    function transferFromMany(address _from, address _to, uint[] calldata _ids) external;
    function claim(address _tigAsset) external;
    function pending(address user, address _tigAsset) external view returns (uint256);
}