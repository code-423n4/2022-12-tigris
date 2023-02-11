// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "./utils/MetaContext.sol";
import "./interfaces/ITrading.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPairsContract.sol";
import "./interfaces/IReferrals.sol";
import "./interfaces/IPosition.sol";
import "./interfaces/IGovNFT.sol";
import "./interfaces/IStableVault.sol";
import "./utils/TradingLibrary.sol";

interface ITradingExtension {
    function getVerifiedPrice(
        uint256 _asset,
        PriceData calldata _priceData,
        bytes calldata _signature,
        uint256 _withSpreadIsLong
    ) external returns(uint256 _price, uint256 _spread);
    function getRef(
        address _trader
    ) external pure returns(address);
    function _setReferral(
        bytes32 _referral,
        address _trader
    ) external;
    function validateTrade(uint256 _asset, address _tigAsset, uint256 _margin, uint256 _leverage) external view;
    function isPaused() external view returns(bool);
    function minPos(address) external view returns(uint);
    function modifyLongOi(
        uint256 _asset,
        address _tigAsset,
        bool _onOpen,
        uint256 _size
    ) external;
    function modifyShortOi(
        uint256 _asset,
        address _tigAsset,
        bool _onOpen,
        uint256 _size
    ) external;
    function paused() external returns(bool);
    function _limitClose(
        uint256 _id,
        bool _tp,
        PriceData calldata _priceData,
        bytes calldata _signature
    ) external returns(uint256 _limitPrice, address _tigAsset);
    function _checkGas() external view;
    function _closePosition(
        uint256 _id,
        uint256 _price,
        uint256 _percent
    ) external returns (IPosition.Trade memory _trade, uint256 _positionSize, int256 _payout);
}

interface IStable is IERC20 {
    function burnFrom(address account, uint256 amount) external;
    function mintFor(address account, uint256 amount) external;
}

interface ExtendedIERC20 is IERC20 {
    function decimals() external view returns (uint);
}

interface ERC20Permit is IERC20 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

contract Trading is MetaContext, ITrading {

    error LimitNotSet();
    error NotLiquidatable();
    error TradingPaused();
    error BadDeposit();
    error BadWithdraw();
    error BadStopLoss();
    error IsLimit();
    error ValueNotEqualToMargin();
    error BadLeverage();
    error NotMargin();
    error NotAllowedInVault();
    error NotVault();
    error NotOwner();
    error NotAllowedPair();
    error WaitDelay();
    error NotProxy();
    error BelowMinPositionSize();
    error BadClosePercent();
    error NoPrice();
    error LiqThreshold();
    error CloseToMaxPnL();
    error BadSetter();
    error BadConstructor();
    error NotLimit();
    error LimitNotMet();

    uint256 private constant DIVISION_CONSTANT = 1e10; // 100%
    uint256 private constant LIQPERCENT = 9e9; // 90%

    struct Fees {
        uint256 daoFees;
        uint256 burnFees;
        uint256 referralFees;
        uint256 botFees;
    }
    Fees public openFees = Fees(
        0,
        0,
        0,
        0
    );
    Fees public closeFees = Fees(
        0,
        0,
        0,
        0
    );
    uint256 public limitOrderPriceRange = 1e8; // 1%

    uint256 public maxWinPercent;
    uint256 public vaultFundingPercent;

    IPairsContract private pairsContract;
    IPosition private position;
    IGovNFT private gov;
    ITradingExtension private tradingExtension;

    struct Delay {
        uint256 delay; // Block timestamp where delay ends
        bool actionType; // True for open, False for close
    }
    mapping(uint256 => Delay) public timeDelayPassed; // id => Delay
    mapping(uint256 => uint) public lastLimitUpdate; // id => timestamp
    uint256 public timeDelay;

    mapping(address => bool) public allowedVault;

    struct Proxy {
        address proxy;
        uint256 time;
    }

    mapping(address => Proxy) public proxyApprovals;

    mapping(address => bool) public marginApproved;

    constructor(
        address _position,
        address _gov,
        address _pairsContract
    )
    {
        if (_position == address(0)
            || _gov == address(0)
            || _pairsContract == address(0)
        ) revert BadConstructor();
        position = IPosition(_position);
        gov = IGovNFT(_gov);
        pairsContract = IPairsContract(_pairsContract);
    }

    // ===== END-USER FUNCTIONS =====

    /**
     * @param _tradeInfo Trade info
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _permitData data and signature needed for token approval
     * @param _trader address the trade is initiated for
     */
    function initiateMarketOrder(
        TradeInfo calldata _tradeInfo,
        PriceData calldata _priceData,
        bytes calldata _signature,
        ERC20PermitData calldata _permitData,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkDelay(position.getCount(), true);
        _checkVault(_tradeInfo.stableVault, _tradeInfo.marginAsset);
        address _tigAsset = IStableVault(_tradeInfo.stableVault).stable();
        tradingExtension.validateTrade(_tradeInfo.asset, _tigAsset, _tradeInfo.margin, _tradeInfo.leverage);
        tradingExtension._setReferral(_tradeInfo.referral, _trader);
        uint256 _marginAfterFees = _tradeInfo.margin - _handleOpenFees(_tradeInfo.asset, _tradeInfo.margin*_tradeInfo.leverage/1e18, _trader, _tigAsset, false);
        uint256 _positionSize = _marginAfterFees * _tradeInfo.leverage / 1e18;
        _handleDeposit(_tigAsset, _tradeInfo.marginAsset, _tradeInfo.margin, _tradeInfo.stableVault, _permitData, _trader);
        uint256 _isLong = _tradeInfo.direction ? 1 : 2;
        (uint256 _price,) = tradingExtension.getVerifiedPrice(_tradeInfo.asset, _priceData, _signature, _isLong);
        IPosition.MintTrade memory _mintTrade = IPosition.MintTrade(
            _trader,
            _marginAfterFees,
            _tradeInfo.leverage,
            _tradeInfo.asset,
            _tradeInfo.direction,
            _price,
            _tradeInfo.tpPrice,
            _tradeInfo.slPrice,
            0,
            _tigAsset
        );
        _checkSl(_tradeInfo.slPrice, _tradeInfo.direction, _price);
        unchecked {
            if (_tradeInfo.direction) {
                tradingExtension.modifyLongOi(_tradeInfo.asset, _tigAsset, true, _positionSize);
            } else {
                tradingExtension.modifyShortOi(_tradeInfo.asset, _tigAsset, true, _positionSize);
            }
        }
        _updateFunding(_tradeInfo.asset, _tigAsset);
        position.mint(
            _mintTrade
        );
        unchecked {
            emit PositionOpened(_tradeInfo, 0, _price, position.getCount()-1, _trader, _marginAfterFees);
        }   
    }

    /**
     * @dev initiate closing position
     * @param _id id of the position NFT
     * @param _percent percent of the position being closed in BP
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _stableVault StableVault address
     * @param _outputToken Token received upon closing trade
     * @param _trader address the trade is initiated for
     */
    function initiateCloseOrder(
        uint256 _id,
        uint256 _percent,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _stableVault,
        address _outputToken,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkDelay(_id, false);
        _checkOwner(_id, _trader);
        _checkVault(_stableVault, _outputToken);
        IPosition.Trade memory _trade = position.trades(_id);
        if (_trade.orderType != 0) revert IsLimit();        
        (uint256 _price,) = tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, 0);

        if (_percent > DIVISION_CONSTANT || _percent == 0) revert BadClosePercent();
        _closePosition(_id, _percent, _price, _stableVault, _outputToken, false); 
    }

    /**
     * @param _id position id
     * @param _addMargin margin amount used to add to the position
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _stableVault StableVault address
     * @param _marginAsset Token being used to add to the position
     * @param _permitData data and signature needed for token approval
     * @param _trader address the trade is initiated for
     */
    function addToPosition(
        uint256 _id,
        uint256 _addMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _stableVault,
        address _marginAsset,
        ERC20PermitData calldata _permitData,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkOwner(_id, _trader);
        _checkDelay(_id, true);
        IPosition.Trade memory _trade = position.trades(_id);
        tradingExtension.validateTrade(_trade.asset, _trade.tigAsset, _trade.margin + _addMargin, _trade.leverage);
        _checkVault(_stableVault, _marginAsset);
        if (_trade.orderType != 0) revert IsLimit();
        (uint256 _price,) = tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, _trade.direction ? 1 : 2);
        (,int256 _payout) = TradingLibrary.pnl(_trade.direction, _priceData.price, _trade.price, _trade.margin, _trade.leverage, _trade.accInterest);
        unchecked {
            if(maxWinPercent != 0 && _payout >= int256(_trade.margin*(maxWinPercent-DIVISION_CONSTANT)/DIVISION_CONSTANT)) revert CloseToMaxPnL();
        }
        uint256 _fee = _handleOpenFees(_trade.asset, _addMargin*_trade.leverage/1e18, _trader, _trade.tigAsset, false);
        _handleDeposit(
            _trade.tigAsset,
            _marginAsset,
            _addMargin,
            _stableVault,
            _permitData,
            _trader
        );
        position.setAccInterest(_id);
        uint256 _positionSize = (_addMargin - _fee) * _trade.leverage / 1e18;
        if (_trade.direction) {
            tradingExtension.modifyLongOi(_trade.asset, _trade.tigAsset, true, _positionSize);
        } else {
            tradingExtension.modifyShortOi(_trade.asset, _trade.tigAsset, true, _positionSize);     
        }
        _updateFunding(_trade.asset, _trade.tigAsset);
        _addMargin -= _fee;
        uint256 _newMargin = _trade.margin + _addMargin;
        uint256 _newPrice = _trade.price * _price * _newMargin /  (_trade.margin * _price + _addMargin * _trade.price);

        position.addToPosition(
            _trade.id,
            _newMargin,
            _newPrice
        );
        
        emit AddToPosition(_trade.id, _newMargin, _newPrice, _trade.trader);
    }

    /**
     * @param _tradeInfo Trade info
     * @param _orderType type of limit order used to open the position
     * @param _price limit price
     * @param _permitData data and signature needed for token approval
     * @param _trader address the trade is initiated for
     */
    function initiateLimitOrder(
        TradeInfo calldata _tradeInfo,
        uint256 _orderType, // 1 limit, 2 stop
        uint256 _price,
        ERC20PermitData calldata _permitData,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        address _tigAsset = IStableVault(_tradeInfo.stableVault).stable();
        tradingExtension.validateTrade(_tradeInfo.asset, _tigAsset, _tradeInfo.margin, _tradeInfo.leverage);
        _checkVault(_tradeInfo.stableVault, _tradeInfo.marginAsset);
        if (_orderType == 0) revert NotLimit();
        if (_price == 0) revert NoPrice();
        tradingExtension._setReferral(_tradeInfo.referral, _trader);
        _handleDeposit(_tigAsset, _tradeInfo.marginAsset, _tradeInfo.margin, _tradeInfo.stableVault, _permitData, _trader);
        _checkSl(_tradeInfo.slPrice, _tradeInfo.direction, _price);
        uint256 _id = position.getCount();
        position.mint(
            IPosition.MintTrade(
                _trader,
                _tradeInfo.margin,
                _tradeInfo.leverage,
                _tradeInfo.asset,
                _tradeInfo.direction,
                _price,
                _tradeInfo.tpPrice,
                _tradeInfo.slPrice,
                _orderType,
                _tigAsset
            )
        );
        lastLimitUpdate[_id] = block.timestamp+1;
        emit PositionOpened(_tradeInfo, _orderType, _price, _id, _trader, _tradeInfo.margin);
    }

    /**
     * @param _id position ID
     * @param _trader address the trade is initiated for
     */
    function cancelLimitOrder(
        uint256 _id,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkOwner(_id, _trader);
        IPosition.Trade memory _trade = position.trades(_id);
        if (_trade.orderType == 0) revert();
        IStable(_trade.tigAsset).mintFor(_trader, _trade.margin);
        position.burn(_id);
        emit LimitCancelled(_id, _trader);
    }

    /**
     * @param _id position id
     * @param _stableVault StableVault address
     * @param _marginAsset Token being used to add to the position
     * @param _addMargin margin amount being added to the position
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _permitData data and signature needed for token approval
     * @param _trader address the trade is initiated for
     */
    function addMargin(
        uint256 _id,
        address _stableVault,
        address _marginAsset,
        uint256 _addMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        ERC20PermitData calldata _permitData,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkOwner(_id, _trader);
        _checkVault(_stableVault, _marginAsset);
        IPosition.Trade memory _trade = position.trades(_id);
        tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, 0);
        (,int256 _payout) = TradingLibrary.pnl(_trade.direction, _priceData.price, _trade.price, _trade.margin, _trade.leverage, _trade.accInterest);
        unchecked {
            if(maxWinPercent != 0 && _payout >= int256(_trade.margin*(maxWinPercent-DIVISION_CONSTANT)/DIVISION_CONSTANT)) revert CloseToMaxPnL();
        }
        if (_trade.orderType != 0) revert(); //IsLimit
        IPairsContract.Asset memory asset = pairsContract.idToAsset(_trade.asset);
        _handleDeposit(_trade.tigAsset, _marginAsset, _addMargin, _stableVault, _permitData, _trader);
        unchecked {
            uint256 _newMargin = _trade.margin + _addMargin;
            uint256 _newLeverage = _trade.margin * _trade.leverage / _newMargin;
            if (_newLeverage < asset.minLeverage) revert BadLeverage();
            position.modifyMargin(_id, _newMargin, _newLeverage);
            emit MarginModified(_id, _newMargin, _newLeverage, true, _trader);
        }
    }

    /**
     * @param _id position id
     * @param _stableVault StableVault address
     * @param _outputToken token the trader will receive
     * @param _removeMargin margin amount being removed from the position
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _trader address the trade is initiated for
     */
    function removeMargin(
        uint256 _id,
        address _stableVault,
        address _outputToken,
        uint256 _removeMargin,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkOwner(_id, _trader);
        _checkVault(_stableVault, _outputToken);
        IPosition.Trade memory _trade = position.trades(_id);
        if (_trade.orderType != 0) revert IsLimit();
        (uint256 _assetPrice,) = tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, 0);
        (,int256 _payout) = TradingLibrary.pnl(_trade.direction, _assetPrice, _trade.price, _trade.margin, _trade.leverage, _trade.accInterest);
        unchecked {
            if(maxWinPercent != 0 && _payout >= int256(_trade.margin*(maxWinPercent-DIVISION_CONSTANT)/DIVISION_CONSTANT)) revert CloseToMaxPnL();
        }
        IPairsContract.Asset memory asset = pairsContract.idToAsset(_trade.asset);
        uint256 _newMargin = _trade.margin - _removeMargin;
        uint256 _newLeverage = _trade.margin * _trade.leverage / _newMargin;
        if (_newLeverage > asset.maxLeverage) revert BadLeverage();
        unchecked {
            if (_payout <= int256(_newMargin*(DIVISION_CONSTANT-LIQPERCENT)/DIVISION_CONSTANT)) revert LiqThreshold();
        }
        position.modifyMargin(_trade.id, _newMargin, _newLeverage);
        _handleWithdraw(_trade, _stableVault, _outputToken, _removeMargin);
        emit MarginModified(_trade.id, _newMargin, _newLeverage, false, _trader);
    }

    /**
     * @param _type true for TP, false for SL
     * @param _id position id
     * @param _limitPrice TP/SL trigger price
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     * @param _trader address the trade is initiated for
     */
    function updateTpSl(
        bool _type,
        uint256 _id,
        uint256 _limitPrice,
        PriceData calldata _priceData,
        bytes calldata _signature,
        address _trader
    )
        external
    {
        _validateProxy(_trader);
        _checkOwner(_id, _trader);
        _checkDelay(_id, true);
        IPosition.Trade memory _trade = position.trades(_id);
        if (_trade.orderType != 0) revert IsLimit();
        if (_type) {
            position.modifyTp(_id, _limitPrice);
        } else {
            (uint256 _price,) = tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, 0);
            _checkSl(_limitPrice, _trade.direction, _price);
            position.modifySl(_id, _limitPrice);
        }
        lastLimitUpdate[_id] = block.timestamp+1;
        emit UpdateTPSL(_id, _type, _limitPrice, _trader);
    }

    /**
     * @param _id position id
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     */
    function executeLimitOrder(
        uint256 _id, 
        PriceData calldata _priceData,
        bytes calldata _signature
    ) 
        external
    {
        unchecked {
            _checkDelay(_id, true);
            tradingExtension._checkGas();
            if (tradingExtension.paused()) revert TradingPaused();
            IPosition.Trade memory trade = position.trades(_id);
            trade.margin -= _handleOpenFees(trade.asset, trade.margin*trade.leverage/1e18, trade.trader, trade.tigAsset, block.timestamp > lastLimitUpdate[_id]);
            (uint256 _price, uint256 _spread) = tradingExtension.getVerifiedPrice(trade.asset, _priceData, _signature, 0);
            if (trade.orderType == 0) revert NotLimit();
            if (_price > trade.price+trade.price*limitOrderPriceRange/DIVISION_CONSTANT || _price < trade.price-trade.price*limitOrderPriceRange/DIVISION_CONSTANT) revert LimitNotMet();
            if (trade.direction && trade.orderType == 1) {
                if (trade.price < _price) revert LimitNotMet();
            } else if (!trade.direction && trade.orderType == 1) {
                if (trade.price > _price) revert LimitNotMet();
            } else if (!trade.direction && trade.orderType == 2) {
                if (trade.price < _price) revert LimitNotMet();
                trade.price = _price;
            } else {
                if (trade.price > _price) revert LimitNotMet();
                trade.price = _price;
            } 
            if(trade.direction) {
                trade.price += trade.price * _spread / DIVISION_CONSTANT;
                tradingExtension.modifyLongOi(trade.asset, trade.tigAsset, true, trade.margin*trade.leverage/1e18);
            } else {
                trade.price -= trade.price * _spread / DIVISION_CONSTANT;
                tradingExtension.modifyShortOi(trade.asset, trade.tigAsset, true, trade.margin*trade.leverage/1e18);
            }
            if (trade.direction ? trade.tpPrice <= trade.price : trade.tpPrice >= trade.price) position.modifyTp(_id, 0);
            _updateFunding(trade.asset, trade.tigAsset);
            position.executeLimitOrder(_id, trade.price, trade.margin);
            emit LimitOrderExecuted(trade.asset, trade.direction, trade.price, trade.leverage, trade.margin, _id, trade.trader, _msgSender());
        }
    }

    /**
     * @notice liquidate position
     * @param _id id of the position NFT
     * @param _priceData verifiable off-chain data
     * @param _signature node signature
     */
    function liquidatePosition(
        uint256 _id,
        PriceData calldata _priceData,
        bytes calldata _signature
    )
        external
    {
        unchecked {
            tradingExtension._checkGas();
            IPosition.Trade memory _trade = position.trades(_id);
            if (_trade.orderType != 0) revert IsLimit();

            (uint256 _price,) = tradingExtension.getVerifiedPrice(_trade.asset, _priceData, _signature, 0);
            (uint256 _positionSizeAfterPrice, int256 _payout) = TradingLibrary.pnl(_trade.direction, _price, _trade.price, _trade.margin, _trade.leverage, _trade.accInterest);
            uint256 _positionSize = _trade.margin*_trade.leverage/1e18;
            if (_payout > int256(_trade.margin*(DIVISION_CONSTANT-LIQPERCENT)/DIVISION_CONSTANT)) revert NotLiquidatable();
            if (_trade.direction) {
                tradingExtension.modifyLongOi(_trade.asset, _trade.tigAsset, false, _positionSize);
            } else {
                tradingExtension.modifyShortOi(_trade.asset, _trade.tigAsset, false, _positionSize);
            }
            _updateFunding(_trade.asset, _trade.tigAsset);
            _handleCloseFees(_trade.asset, type(uint).max, _trade.tigAsset, _positionSizeAfterPrice, _trade.trader, true);
            position.burn(_id);
            emit PositionLiquidated(_id, _trade.trader, _msgSender());
        }
    }

    /**
     * @dev close position at a pre-set price
     * @param _id id of the position NFT
     * @param _tp true if take profit
     * @param _priceData verifiable off-chain price data
     * @param _signature node signature
     */
    function limitClose(
        uint256 _id,
        bool _tp,
        PriceData calldata _priceData,
        bytes calldata _signature
    )
        external
    {
        if (_tp) {
            _checkDelay(_id, false);
        }
        (uint256 _limitPrice, address _tigAsset) = tradingExtension._limitClose(_id, _tp, _priceData, _signature);
        _closePosition(_id, DIVISION_CONSTANT, _limitPrice, address(0), _tigAsset, block.timestamp > lastLimitUpdate[_id]);
    }

    /**
     * @notice Trader can approve a proxy wallet address for it to trade on its behalf. Can also provide proxy wallet with gas.
     * @param _proxy proxy wallet address
     * @param _timestamp end timestamp of approval period
     */
    function approveProxy(address _proxy, uint256 _timestamp) external payable {
        proxyApprovals[_msgSender()] = Proxy(
            _proxy,
            _timestamp
        );
        (bool sent, bytes memory data) = payable(_proxy).call{value: msg.value}("");
        require(sent, "Failed to send");
    }

    // ===== INTERNAL FUNCTIONS =====

    /**
     * @dev close the initiated position.
     * @param _id id of the position NFT
     * @param _percent percent of the position being closed
     * @param _price pair price
     * @param _stableVault StableVault address
     * @param _outputToken Token that trader will receive
     * @param _isBot false if closed via market order
     */
    function _closePosition(
        uint256 _id,
        uint256 _percent,
        uint256 _price,
        address _stableVault,
        address _outputToken,
        bool _isBot
    )
        internal
    {
        (IPosition.Trade memory _trade, uint256 _positionSize, int256 _payout) = tradingExtension._closePosition(_id, _price, _percent);
        position.setAccInterest(_id);
        _updateFunding(_trade.asset, _trade.tigAsset);
        if (_percent < DIVISION_CONSTANT) {
            if ((_trade.margin*_trade.leverage*(DIVISION_CONSTANT-_percent)/DIVISION_CONSTANT)/1e18 < tradingExtension.minPos(_trade.tigAsset)) revert BelowMinPositionSize();
            position.reducePosition(_id, _percent);
        } else {
            position.burn(_id);
        }
        uint256 _toMint;
        if (_payout > 0) {
            unchecked {
                _toMint = _handleCloseFees(_trade.asset, uint256(_payout)*_percent/DIVISION_CONSTANT, _trade.tigAsset, _positionSize*_percent/DIVISION_CONSTANT, _trade.trader, _isBot);
                uint256 marginToClose = _trade.margin*_percent/DIVISION_CONSTANT;
                if (maxWinPercent > 0 && _toMint > marginToClose*maxWinPercent/DIVISION_CONSTANT) {
                    _toMint = marginToClose*maxWinPercent/DIVISION_CONSTANT;
                }
            }
            _handleWithdraw(_trade, _stableVault, _outputToken, _toMint);
        }
        emit PositionClosed(_id, _price, _percent, _toMint, _trade.trader, _isBot ? _msgSender() : _trade.trader);
    }

    /**
     * @dev handle stableVault deposits for different trading functions
     * @param _tigAsset tigAsset token address
     * @param _marginAsset token being deposited into stableVault
     * @param _margin amount being deposited
     * @param _stableVault StableVault address
     * @param _permitData Data for approval via permit
     * @param _trader Trader address to take tokens from
     */
    function _handleDeposit(address _tigAsset, address _marginAsset, uint256 _margin, address _stableVault, ERC20PermitData calldata _permitData, address _trader) internal {
        IStable tigAsset = IStable(_tigAsset);
        if (_tigAsset != _marginAsset) {
            if (_permitData.usePermit) {
                ERC20Permit(_marginAsset).permit(_trader, address(this), _permitData.amount, _permitData.deadline, _permitData.v, _permitData.r, _permitData.s);
            }
            uint256 _balBefore = tigAsset.balanceOf(address(this));
            uint256 _marginDecMultiplier = 10**(18-ExtendedIERC20(_marginAsset).decimals());
            IERC20(_marginAsset).transferFrom(_trader, address(this), _margin/_marginDecMultiplier);
            if (!marginApproved[_marginAsset]) {
                IERC20(_marginAsset).approve(_stableVault, type(uint).max);
                marginApproved[_marginAsset] = true;
            }
            IStableVault(_stableVault).deposit(_marginAsset, _margin/_marginDecMultiplier);
            if (tigAsset.balanceOf(address(this)) != _balBefore + _margin) revert BadDeposit();
            tigAsset.burnFrom(address(this), tigAsset.balanceOf(address(this)));
        } else {
            tigAsset.burnFrom(_trader, _margin);
        }        
    }

    /**
     * @dev handle stableVault withdrawals for different trading functions
     * @param _trade Position info
     * @param _stableVault StableVault address
     * @param _outputToken Output token address
     * @param _toMint Amount of tigAsset minted to be used for withdrawal
     */
    function _handleWithdraw(IPosition.Trade memory _trade, address _stableVault, address _outputToken, uint256 _toMint) internal {
        IStable(_trade.tigAsset).mintFor(address(this), _toMint);
        if (_outputToken == _trade.tigAsset) {
            IERC20(_outputToken).transfer(_trade.trader, _toMint);
        } else {
            uint256 _balBefore = IERC20(_outputToken).balanceOf(address(this));
            IStableVault(_stableVault).withdraw(_outputToken, _toMint);
            uint256 _decimals = ExtendedIERC20(_outputToken).decimals();
            if (IERC20(_outputToken).balanceOf(address(this)) != _balBefore + _toMint/(10**(18-_decimals))) revert BadWithdraw();
            IERC20(_outputToken).transfer(_trade.trader, IERC20(_outputToken).balanceOf(address(this)) - _balBefore);
        }        
    }

    /**
     * @dev handle fees distribution for opening
     * @param _asset asset id
     * @param _positionSize position size
     * @param _trader trader address
     * @param _tigAsset tigAsset address
     * @param _isBot false if opened via market order
     * @return _feePaid total fees paid during opening
     */
    function _handleOpenFees(
        uint256 _asset,
        uint256 _positionSize,
        address _trader,
        address _tigAsset,
        bool _isBot
    )
        internal
        returns (uint256 _feePaid)
    {
        IPairsContract.Asset memory asset = pairsContract.idToAsset(_asset);
        Fees memory _fees = openFees;
        unchecked {
            _fees.daoFees = _fees.daoFees * asset.feeMultiplier / DIVISION_CONSTANT;
            _fees.burnFees = _fees.burnFees * asset.feeMultiplier / DIVISION_CONSTANT;
            _fees.referralFees = _fees.referralFees * asset.feeMultiplier / DIVISION_CONSTANT;
            _fees.botFees = _fees.botFees * asset.feeMultiplier / DIVISION_CONSTANT;
        }
        address _referrer = tradingExtension.getRef(_trader); //referrals.getReferral(referrals.getReferred(_trader));
        if (_referrer != address(0)) {
            unchecked {
                IStable(_tigAsset).mintFor(
                    _referrer,
                    _positionSize
                    * _fees.referralFees // get referral fee%
                    / DIVISION_CONSTANT // divide by 100%
                );
            }
            _fees.daoFees = _fees.daoFees - _fees.referralFees*2;
        }
        if (_isBot) {
            unchecked {
                IStable(_tigAsset).mintFor(
                    _msgSender(),
                    _positionSize
                    * _fees.botFees // get bot fee%
                    / DIVISION_CONSTANT // divide by 100%
                );
            }
            _fees.daoFees = _fees.daoFees - _fees.botFees;
        } else {
            _fees.botFees = 0;
        }
        unchecked {
            uint256 _daoFeesPaid = _positionSize * _fees.daoFees / DIVISION_CONSTANT;
            _feePaid =
                _positionSize
                * (_fees.burnFees + _fees.botFees + (_referrer != address(0) ? _fees.referralFees : 0)) // get total fee%
                / DIVISION_CONSTANT // divide by 100%
                + _daoFeesPaid;
            emit FeesDistributed(
                _tigAsset,
                _daoFeesPaid,
                _positionSize * _fees.burnFees / DIVISION_CONSTANT,
                _referrer != address(0) ? _positionSize * _fees.referralFees / DIVISION_CONSTANT : 0,
                _positionSize * _fees.botFees / DIVISION_CONSTANT,
                _referrer
            );
            IStable(_tigAsset).mintFor(address(this), _daoFeesPaid);
        }
        if (!marginApproved[_tigAsset]) {
            IStable(_tigAsset).approve(address(gov), type(uint).max);
            marginApproved[_tigAsset] = true;
        }
        gov.distribute(_tigAsset, IStable(_tigAsset).balanceOf(address(this)));
    }

    /**
     * @dev handle fees distribution for closing
     * @param _asset asset id
     * @param _payout payout to trader before fees
     * @param _tigAsset margin asset
     * @param _positionSize position size
     * @param _trader trader address
     * @param _isBot false if closed via market order
     * @return payout_ payout to trader after fees
     */
    function _handleCloseFees(
        uint256 _asset,
        uint256 _payout,
        address _tigAsset,
        uint256 _positionSize,
        address _trader,
        bool _isBot
    )
        internal
        returns (uint256 payout_)
    {
        IPairsContract.Asset memory asset = pairsContract.idToAsset(_asset);
        Fees memory _fees = closeFees;
        uint256 _daoFeesPaid;
        uint256 _burnFeesPaid;
        uint256 _referralFeesPaid;
        unchecked {
            _daoFeesPaid = (_positionSize*_fees.daoFees/DIVISION_CONSTANT)*asset.feeMultiplier/DIVISION_CONSTANT;
            _burnFeesPaid = (_positionSize*_fees.burnFees/DIVISION_CONSTANT)*asset.feeMultiplier/DIVISION_CONSTANT;
        }
        uint256 _botFeesPaid;
        address _referrer = tradingExtension.getRef(_trader);//referrals.getReferral(referrals.getReferred(_trader));
        if (_referrer != address(0)) {
            unchecked {
                _referralFeesPaid = (_positionSize*_fees.referralFees/DIVISION_CONSTANT)*asset.feeMultiplier/DIVISION_CONSTANT;
            }
            IStable(_tigAsset).mintFor(
                _referrer,
                _referralFeesPaid
            );
            _daoFeesPaid = _daoFeesPaid-_referralFeesPaid*2;
        }
        if (_isBot) {
            unchecked {
                _botFeesPaid = (_positionSize*_fees.botFees/DIVISION_CONSTANT)*asset.feeMultiplier/DIVISION_CONSTANT;
                IStable(_tigAsset).mintFor(
                    _msgSender(),
                    _botFeesPaid
                );
            }
            _daoFeesPaid = _daoFeesPaid - _botFeesPaid;
        }
        emit FeesDistributed(_tigAsset, _daoFeesPaid, _burnFeesPaid, _referralFeesPaid, _botFeesPaid, _referrer);
        payout_ = _payout - (_daoFeesPaid + _referralFeesPaid) - _burnFeesPaid - _botFeesPaid;
        IStable(_tigAsset).mintFor(address(this), _daoFeesPaid);
        gov.distribute(_tigAsset, _daoFeesPaid);
    }

    /**
     * @dev update funding rates after open interest changes
     * @param _asset asset id
     * @param _tigAsset tigAsset used for OI
     */
    function _updateFunding(uint256 _asset, address _tigAsset) internal {
        position.updateFunding(
            _asset,
            _tigAsset,
            pairsContract.idToOi(_asset, _tigAsset).longOi,
            pairsContract.idToOi(_asset, _tigAsset).shortOi,
            pairsContract.idToAsset(_asset).baseFundingRate,
            vaultFundingPercent
        );
    }

    /**
     * @dev check that SL price is valid compared to market price
     * @param _sl SL price
     * @param _direction long/short
     * @param _price market price
     */
    function _checkSl(uint256 _sl, bool _direction, uint256 _price) internal pure {
        if (_direction) {
            if (_sl > _price) revert BadStopLoss();
        } else {
            if (_sl < _price && _sl != 0) revert BadStopLoss();
        }
    }

    /**
     * @dev check that trader address owns the position
     * @param _id position id
     * @param _trader trader address
     */
    function _checkOwner(uint256 _id, address _trader) internal view {
        if (position.ownerOf(_id) != _trader) revert NotOwner();
    }

    /**
     * @notice Check that sufficient time has passed between opening and closing
     * @dev This is to prevent profitable opening and closing in the same tx with two different prices in the "valid signature pool".
     * @param _id position id
     * @param _type true for opening, false for closing
     */
    function _checkDelay(uint256 _id, bool _type) internal {
        unchecked {
            Delay memory _delay = timeDelayPassed[_id];
            if (_delay.actionType == _type) {
                timeDelayPassed[_id].delay = block.timestamp + timeDelay;
            } else {
                if (block.timestamp < _delay.delay) revert WaitDelay();
                timeDelayPassed[_id].delay = block.timestamp + timeDelay;
                timeDelayPassed[_id].actionType = _type;
            }
        }
    }

    /**
     * @dev Check that the stableVault input is whitelisted and the margin asset is whitelisted in the vault
     * @param _stableVault StableVault address
     * @param _token Margin asset token address
     */
    function _checkVault(address _stableVault, address _token) internal view {
        if (!allowedVault[_stableVault]) revert NotVault();
        if (_token != IStableVault(_stableVault).stable() || !IStableVault(_stableVault).allowed(_token)) revert NotAllowedInVault();
    }

    /**
     * @dev Check that the trader has approved the proxy address to trade for it
     * @param _trader Trader address
     */
    function _validateProxy(address _trader) internal view {
        if (_trader != _msgSender()) {
            Proxy memory _proxy = proxyApprovals[_trader];
            if (_proxy.proxy != _msgSender() || _proxy.time >= block.timestamp) revert NotProxy();
        }
    }

    // ===== GOVERNANCE-ONLY =====

    /**
     * @dev Sets timestamp delay between opening and closing
     * @param _timeDelay delay amount
     */
    function setTimeDelay(
        uint256 _timeDelay
    )
        external
        onlyOwner
    {
        timeDelay = _timeDelay;
    }

    /**
     * @dev Whitelists a stableVault contract address
     * @param _stableVault StableVault address
     * @param _bool true if allowed
     */
    function setAllowedVault(
        address _stableVault,
        bool _bool
    )
        external
        onlyOwner
    {
        allowedVault[_stableVault] = _bool;
    }

    /**
     * @dev Sets max payout % compared to margin, minimum +500% PnL
     * @param _maxWinPercent payout %
     */
    function setMaxWinPercent(
        uint256 _maxWinPercent
    )
        external
        onlyOwner
    {
        if (_maxWinPercent != 0 && _maxWinPercent < 6*DIVISION_CONSTANT) revert BadSetter();
        maxWinPercent = _maxWinPercent;
    }

    /**
     * @dev Sets executable price range for limit orders
     * @param _range price range in %
     */
    function setLimitOrderPriceRange(uint256 _range) external onlyOwner {
        limitOrderPriceRange = _range;
    }

    /**
     * @dev Sets the fees for the trading protocol
     * @param _open True if open fees are being set
     * @param _daoFees Fees distributed to the DAO
     * @param _burnFees Fees which get burned
     * @param _referralFees Fees given to referrers
     * @param _botFees Fees given to bots that execute limit orders
     * @param _percent Percent of earned funding fees going to StableVault
     */
    function setFees(bool _open, uint256 _daoFees, uint256 _burnFees, uint256 _referralFees, uint256 _botFees, uint256 _percent) external onlyOwner {
        unchecked {
            if (_daoFees < _botFees+_referralFees*2) revert BadSetter();
            if (_open) {
                openFees.daoFees = _daoFees;
                openFees.burnFees = _burnFees;
                openFees.referralFees = _referralFees;
                openFees.botFees = _botFees;
            } else {
                closeFees.daoFees = _daoFees;
                closeFees.burnFees = _burnFees;
                closeFees.referralFees = _referralFees;
                closeFees.botFees = _botFees;                
            }
            if (_percent > DIVISION_CONSTANT) revert BadSetter();
            vaultFundingPercent = _percent;
        }
    }

    /**
     * @dev Sets the extension contract address for trading
     * @param _ext extension contract address
     */
    function setTradingExtension(
        address _ext
    ) external onlyOwner() {
        tradingExtension = ITradingExtension(_ext);
    }

    // ===== EVENTS =====

    event PositionOpened(
        TradeInfo _tradeInfo,
        uint256 _orderType,
        uint256 _price,
        uint256 _id,
        address _trader,
        uint256 _marginAfterFees
    );

    event PositionClosed(
        uint256 _id,
        uint256 _closePrice,
        uint256 _percent,
        uint256 _payout,
        address _trader,
        address _executor
    );

    event PositionLiquidated(
        uint256 _id,
        address _trader,
        address _executor
    );

    event LimitOrderExecuted(
        uint256 _asset,
        bool _direction,
        uint256 _openPrice,
        uint256 _lev,
        uint256 _margin,
        uint256 _id,
        address _trader,
        address _executor
    );

    event UpdateTPSL(
        uint256 _id,
        bool _isTp,
        uint256 _price,
        address _trader
    );

    event LimitCancelled(
        uint256 _id,
        address _trader
    );

    event MarginModified(
        uint256 _id,
        uint256 _newMargin,
        uint256 _newLeverage,
        bool _isMarginAdded,
        address _trader
    );

    event AddToPosition(
        uint256 _id,
        uint256 _newMargin,
        uint256 _newPrice,
        address _trader
    );

    event FeesDistributed(
        address _tigAsset,
        uint256 _daoFees,
        uint256 _burnFees,
        uint256 _refFees,
        uint256 _botFees,
        address _referrer
    );
}
