// SPDX-License-Identifier: MIT

import "../utils/TradingLibrary.sol";

pragma solidity 0.8.18;

interface ITrading {

    struct TradeInfo {
        uint256 margin;
        address marginAsset;
        address stableVault;
        uint256 leverage;
        uint256 asset;
        bool direction;
        uint256 tpPrice;
        uint256 slPrice;
        bytes32 referral;
    }

    struct ERC20PermitData {
        uint256 deadline;
        uint256 amount;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bool usePermit;
    }

    function initiateMarketOrder(
        TradeInfo calldata _tradeInfo,
        PriceData calldata _priceData,
        bytes calldata _signature,
        ERC20PermitData calldata _permitData,
        address _trader
    ) external;

    function initiateCloseOrder(
        uint256 _id,
        uint256 _percent,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _stableVault,
        address _outputToken,
        address _trader
    ) external;

    function addMargin(
        uint256 _id,
        address _stableVault,
        address _marginAsset,
        uint256 _addMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        ERC20PermitData calldata _permitData,
        address _trader
    ) external;

    function removeMargin(
        uint256 _id,
        address _stableVault,
        address _outputToken,
        uint256 _removeMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _trader
    ) external;

    function addToPosition(
        uint256 _id,
        uint256 _addMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _stableVault,
        address _marginAsset,
        ERC20PermitData calldata _permitData,
        address _trader
    ) external;

    function initiateLimitOrder(
        TradeInfo calldata _tradeInfo,
        uint256 _orderType, // 1 limit, 2 momentum
        uint256 _price,
        ERC20PermitData calldata _permitData,
        address _trader
    ) external;

    function cancelLimitOrder(
        uint256 _id,
        address _trader
    ) external;

    function updateTpSl(
        bool _type, // true is TP
        uint256 _id,
        uint256 _limitPrice,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _trader
    ) external;

    function executeLimitOrder(
        uint256 _id, 
        PriceData calldata _priceData,
        bytes calldata _signature
    ) external;

    function liquidatePosition(
        uint256 _id,
        PriceData calldata _priceData,
        bytes calldata _signature
    ) external;

    function limitClose(
        uint256 _id,
        bool _tp,
        PriceData calldata _priceData,
        bytes calldata _signature
    ) external;
}