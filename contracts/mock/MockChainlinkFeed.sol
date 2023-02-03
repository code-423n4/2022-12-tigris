// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

interface IPrice {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

contract MockChainlinkFeed is IPrice {

    int256 private price;

    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        return (18446744073709711689, price, 1675037985, 1675037985, 18446744073709711689);
    }

    function decimals() external pure returns (uint8) {
        return 10;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}