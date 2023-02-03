// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface IBondNFT {
    function createLock(
        address _asset,
        uint256 _amount,
        uint256 _period,
        address _owner
    ) external returns(uint256 id);

    function extendLock(
        uint256 _id,
        address _asset,
        uint256 _amount,
        uint256 _period,
        address _sender
    ) external;

    function claim(
        uint256 _id,
        address _owner
    ) external returns(uint256 amount, address tigAsset);

    function claimDebt(
        address _owner,
        address _tigAsset
    ) external returns(uint256 amount);

    function release(
        uint256 _id,
        address _releaser
    ) external returns(uint256 amount, uint256 lockAmount, address asset, address _owner);

    function distribute(
        address _tigAsset,
        uint256 _amount
    ) external;

    function ownerOf(uint256 _id) external view returns (uint256);
    
    function totalAssets() external view returns (uint256);
    function getAssets() external view returns (address[] memory);
}