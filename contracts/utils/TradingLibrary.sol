//SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/IPosition.sol";

interface IPrice {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

struct PriceData {
    address provider;
    bool isClosed;
    uint256 asset;
    uint256 price;
    uint256 spread;
    uint256 timestamp;
}

library TradingLibrary {

    using ECDSA for bytes32;

    uint256 constant DIVISION_CONSTANT = 1e10;
    uint256 constant CHAINLINK_PRECISION = 2e8;

    /**
    * @notice returns position profit or loss
    * @param _direction true if long
    * @param _currentPrice current price
    * @param _price opening price
    * @param _leverage position leverage
    * @param _margin collateral amount
    * @param accInterest funding fees
    * @return _positionSize position size
    * @return _payout payout trader should get
    */
    function pnl(bool _direction, uint256 _currentPrice, uint256 _price, uint256 _margin, uint256 _leverage, int256 accInterest) external pure returns (uint256 _positionSize, int256 _payout) {
        uint256 _initPositionSize = _margin * _leverage / 1e18;
        if (_direction && _currentPrice >= _price) {
            _payout = int256(_margin) + int256(_initPositionSize * (1e18 * _currentPrice / _price - 1e18)/1e18) + accInterest;
        } else if (_direction && _currentPrice < _price) {
            _payout = int256(_margin) - int256(_initPositionSize * (1e18 - 1e18 * _currentPrice / _price)/1e18) + accInterest;
        } else if (!_direction && _currentPrice <= _price) {
            _payout = int256(_margin) + int256(_initPositionSize * (1e18 - 1e18 * _currentPrice / _price)/1e18) + accInterest;
        } else {
            _payout = int256(_margin) - int256(_initPositionSize * (1e18 * _currentPrice / _price - 1e18)/1e18) + accInterest;
        }
        _positionSize = _initPositionSize * _currentPrice / _price;
    }

    /**
    * @notice returns position liquidation price
    * @param _direction true if long
    * @param _tradePrice opening price
    * @param _leverage position leverage
    * @param _margin collateral amount
    * @param _accInterest funding fees
    * @param _liqPercent liquidation percent
    * @return _liqPrice liquidation price
    */
    function liqPrice(bool _direction, uint256 _tradePrice, uint256 _leverage, uint256 _margin, int _accInterest, uint256 _liqPercent) public pure returns (uint256 _liqPrice) {
        if (_direction) {
            _liqPrice = _tradePrice - ((_tradePrice*1e18/_leverage) * uint(int(_margin)+_accInterest) / _margin) * _liqPercent / DIVISION_CONSTANT;
        } else {
            _liqPrice = _tradePrice + ((_tradePrice*1e18/_leverage) * uint(int(_margin)+_accInterest) / _margin) * _liqPercent / DIVISION_CONSTANT;
        }
    }

    /**
    * @notice uses liqPrice() and returns position liquidation price
    * @param _positions positions contract address
    * @param _id position id
    * @param _liqPercent liquidation percent
    */
    function getLiqPrice(address _positions, uint256 _id, uint256 _liqPercent) external view returns (uint256) {
        IPosition.Trade memory _trade = IPosition(_positions).trades(_id);
        return liqPrice(_trade.direction, _trade.price, _trade.leverage, _trade.margin, _trade.accInterest, _liqPercent);
    }

    /**
    * @notice verifies that price is signed by a whitelisted node
    * @param _validSignatureTimer seconds allowed before price is old
    * @param _asset position asset
    * @param _chainlinkEnabled is chainlink verification is on
    * @param _chainlinkFeed address of chainlink price feed
    * @param _priceData PriceData object
    * @param _signature signature returned from oracle
    * @param _isNode mapping of allowed nodes
    */
    function verifyPrice(
        uint256 _validSignatureTimer,
        uint256 _asset,
        bool _chainlinkEnabled,
        address _chainlinkFeed,
        PriceData calldata _priceData,
        bytes calldata _signature,
        mapping(address => bool) storage _isNode
    )
        external view
    {
        address _provider = (
            keccak256(abi.encode(_priceData))
        ).toEthSignedMessageHash().recover(_signature);
        require(_provider == _priceData.provider, "BadSig");
        require(_isNode[_provider], "!Node");
        require(_asset == _priceData.asset, "!Asset");
        require(!_priceData.isClosed, "Closed");
        require(block.timestamp >= _priceData.timestamp, "FutSig");
        require(block.timestamp <= _priceData.timestamp + _validSignatureTimer, "ExpSig");
        require(_priceData.price > 0, "NoPrice");
        if (_chainlinkEnabled && _chainlinkFeed != address(0)) {
            (uint80 roundId, int256 assetChainlinkPriceInt, , uint256 updatedAt, uint80 answeredInRound) = IPrice(_chainlinkFeed).latestRoundData();
            if (answeredInRound >= roundId && updatedAt > 0 && assetChainlinkPriceInt != 0) {
                uint256 assetChainlinkPrice = uint256(assetChainlinkPriceInt) * 10**(18 - IPrice(_chainlinkFeed).decimals());
                require(
                    _priceData.price < assetChainlinkPrice+assetChainlinkPrice*CHAINLINK_PRECISION/DIVISION_CONSTANT , "!chainlinkPrice"
                );
                require(
                    _priceData.price > assetChainlinkPrice-assetChainlinkPrice*CHAINLINK_PRECISION/DIVISION_CONSTANT, "!chainlinkPrice"
                );
            }
        }
    }
}
