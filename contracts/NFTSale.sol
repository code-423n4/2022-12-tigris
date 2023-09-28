//SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC721 {
    function balanceOf(address) external view returns (uint256);
    function transferMany(address, uint[] memory) external;
    function claim(address) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint) external;
    function transferFrom(address, address, uint) external;
}

contract NFTSale is Ownable {

    uint256 public price;
    IERC721 public nft;
    IERC20 public token;

    uint[] public availableIds;

    constructor (IERC721 _nft, IERC20 _token) {
        nft = _nft;
        token = _token;
    }


    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
    }

    function available() external view returns (uint) {
        return nft.balanceOf(address(this));
    }

    function buy(uint256 _amount) external {
        require(_amount <= availableIds.length, "Not enough for sale");
        uint256 _tokenAmount = _amount*price;
        token.transferFrom(msg.sender, owner(), _tokenAmount);
        uint[] memory _sold = new uint[](_amount);
        for (uint256 i=0; i<_amount; i++) {
            _sold[i] = availableIds[(availableIds.length-i) - 1];
        }
        for (uint256 i=0; i<_amount; i++) {
            availableIds.pop();
        }
        nft.transferMany(msg.sender, _sold);
    }

    function recovertoken() external {
        token.transfer(owner(), token.balanceOf(address(this)));
    }

    function recoverNft() external onlyOwner {
        nft.transferMany(owner(), availableIds);
        availableIds = new uint[](0);
    }

    function setIds(uint[] calldata _ids) external onlyOwner {
        availableIds = _ids;
    }

    function claimPendingRev(address _tigAsset) external {
        nft.claim(_tigAsset);
        IERC20(_tigAsset).transfer(owner(), IERC20(_tigAsset).balanceOf(address(this)));
    }
}
