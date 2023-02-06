// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPairsContract.sol";
import "./utils/TradingLibrary.sol";
import "./interfaces/IReferrals.sol";
import "./interfaces/IPosition.sol";

contract TradingExtension is Ownable{
    uint256 constant private DIVISION_CONSTANT = 1e10; // 100%

    address public immutable trading;
    bool public chainlinkEnabled;
    bool public paused;
    uint256 public validSignatureTimer;


    mapping(address => bool) private isNode;
    mapping(address => uint) public minPositionSize;
    mapping(address => bool) public allowedMargin;

    IPairsContract private immutable pairsContract;
    IReferrals private immutable referrals;
    IPosition private immutable position;

    uint256 public maxGasPrice = 1000 gwei;

    error BadConstructor();

    constructor(
        address _trading,
        address _pairsContract,
        address _ref,
        address _position
    )
    {
        if (_trading == address(0)
            || _pairsContract == address(0)
            || _ref == address(0)
            || _position == address(0)
        ) revert BadConstructor();
        trading = _trading;
        pairsContract = IPairsContract(_pairsContract);
        referrals = IReferrals(_ref);
        position = IPosition(_position);
    }

    /**
    * @notice returns the minimum position size per collateral asset
    * @param _asset address of the asset
    */
    function minPos(
        address _asset
    ) external view returns(uint) {
        return minPositionSize[_asset];
    }

    /**
    * @notice closePosition helper
    * @dev only callable by trading contract
    * @param _id id of the position NFT
    * @param _price current asset price
    * @param _percent close percentage
    * @return _trade returns the trade struct from NFT contract
    * @return _positionSize size of the position
    * @return _payout amount of payout to the trader after closing
    */
    function _closePosition(
        uint256 _id,
        uint256 _price,
        uint256 _percent
    ) external onlyProtocol returns (IPosition.Trade memory _trade, uint256 _positionSize, int256 _payout) {
        _trade = position.trades(_id);
        (_positionSize, _payout) = TradingLibrary.pnl(_trade.direction, _price, _trade.price, _trade.margin, _trade.leverage, _trade.accInterest);

        unchecked {
            if (_trade.direction) {
                modifyLongOi(_trade.asset, _trade.tigAsset, false, (_trade.margin*_trade.leverage/1e18)*_percent/DIVISION_CONSTANT);
            } else {
                modifyShortOi(_trade.asset, _trade.tigAsset, false, (_trade.margin*_trade.leverage/1e18)*_percent/DIVISION_CONSTANT);     
            }
        }
    }

    /**
    * @notice limitClose helper
    * @dev only callable by trading contract
    * @param _id id of the position NFT
    * @param _tp true if long, else short
    * @param _priceData price data object came from the price oracle
    * @param _signature to verify the oracle
    * @return _limitPrice price of sl or tp returned from positions contract
    * @return _tigAsset address of the position collateral asset
    */
    function _limitClose(
        uint256 _id,
        bool _tp,
        PriceData calldata _priceData,
        bytes calldata _signature
    ) external view returns(uint256 _limitPrice, address _tigAsset) {
        _checkGas();
        IPosition.Trade memory _trade = position.trades(_id);
        _tigAsset = _trade.tigAsset;

        getVerifiedPrice(_trade.asset, _priceData, _signature, 0);
        uint256 _price = _priceData.price;

        if (_trade.orderType != 0) revert("4"); //IsLimit

        if (_tp) {
            if (_trade.tpPrice == 0) revert("7"); //LimitNotSet
            if (_trade.direction) {
                if (_trade.tpPrice > _price) revert("6"); //LimitNotMet
            } else {
                if (_trade.tpPrice < _price) revert("6"); //LimitNotMet
            }
            _limitPrice = _trade.tpPrice;
        } else {
            if (_trade.slPrice == 0) revert("7"); //LimitNotSet
            if (_trade.direction) {
                if (_trade.slPrice < _price) revert("6"); //LimitNotMet
            } else {
                if (_trade.slPrice > _price) revert("6"); //LimitNotMet
            }
            _limitPrice = _trade.slPrice;
        }
    }

    function _checkGas() public view {
        if (tx.gasprice > maxGasPrice) revert("1"); //GasTooHigh
    }

    function modifyShortOi(
        uint256 _asset,
        address _tigAsset,
        bool _onOpen,
        uint256 _size
    ) public onlyProtocol {
        pairsContract.modifyShortOi(_asset, _tigAsset, _onOpen, _size);
    }

    function modifyLongOi(
        uint256 _asset,
        address _tigAsset,
        bool _onOpen,
        uint256 _size
    ) public onlyProtocol {
        pairsContract.modifyLongOi(_asset, _tigAsset, _onOpen, _size);
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external onlyOwner {
        maxGasPrice = _maxGasPrice;
    }

    function getRef(
        address _trader
    ) external view returns(address) {
        return referrals.getReferral(referrals.getReferred(_trader));
    }

    /**
    * @notice verifies the signed price and returns it
    * @param _asset id of position asset
    * @param _priceData price data object came from the price oracle
    * @param _signature to verify the oracle
    * @param _withSpreadIsLong 0, 1, or 2 - to specify if we need the price returned to be after spread
    * @return _price price after verification and with spread if _withSpreadIsLong is 1 or 2
    * @return _spread spread after verification
    */
    function getVerifiedPrice(
        uint256 _asset,
        PriceData calldata _priceData,
        bytes calldata _signature,
        uint256 _withSpreadIsLong
    ) 
        public view
        returns(uint256 _price, uint256 _spread) 
    {
        TradingLibrary.verifyPrice(
            validSignatureTimer,
            _asset,
            chainlinkEnabled,
            pairsContract.idToAsset(_asset).chainlinkFeed,
            _priceData,
            _signature,
            isNode
        );
        _price = _priceData.price;
        _spread = _priceData.spread;

        if(_withSpreadIsLong == 1) 
            _price += _price * _spread / DIVISION_CONSTANT;
        else if(_withSpreadIsLong == 2) 
            _price -= _price * _spread / DIVISION_CONSTANT;
    }

    function _setReferral(
        bytes32 _referral,
        address _trader
    ) external onlyProtocol {
        if (_referral != bytes32(0)
            && referrals.getReferred(_trader) == bytes32(0)
            && referrals.getReferral(_referral) != address(0)
        ) {
            referrals.setReferred(_trader, _referral);
        }
    }

    /**
     * @dev validates the inputs of trades
     * @param _asset asset id
     * @param _tigAsset margin asset
     * @param _margin margin
     * @param _leverage leverage
     */
    function validateTrade(uint256 _asset, address _tigAsset, uint256 _margin, uint256 _leverage) external view {
        unchecked {
            IPairsContract.Asset memory asset = pairsContract.idToAsset(_asset);
            if (!allowedMargin[_tigAsset]) revert("!margin");
            if (paused) revert("paused");
            if (!pairsContract.allowedAsset(_asset)) revert("!allowed");
            if (_leverage < asset.minLeverage || _leverage > asset.maxLeverage) revert("!lev");
            if (_margin*_leverage/1e18 < minPositionSize[_tigAsset]) revert("!size");
        }
    }

    function setValidSignatureTimer(
        uint256 _time
    )
        external
        onlyOwner
    {
        validSignatureTimer = _time;
    }

    function setChainlinkEnabled(bool _isEnabled) external onlyOwner {
        chainlinkEnabled = _isEnabled;
    }

    /**
     * @dev whitelists a node
     * @param _node node address
     * @param _isNode if address is set as a node
     */
    function setNode(address _node, bool _isNode) external onlyOwner {
        isNode[_node] = _isNode;
    }

    /**
     * @dev Allows a tigAsset to be used
     * @param _tigAsset tigAsset
     * @param _isAllowed if token is allowed to be used as margin
     */
    function setAllowedMargin(
        address _tigAsset,
        bool _isAllowed
    ) 
        external
        onlyOwner
    {
        allowedMargin[_tigAsset] = _isAllowed;
    }

    /**
     * @dev changes the minimum position size
     * @param _tigAsset tigAsset
     * @param _min minimum position size 18 decimals
     */
    function setMinPositionSize(
        address _tigAsset,
        uint256 _min
    ) 
        external
        onlyOwner
    {
        minPositionSize[_tigAsset] = _min;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    modifier onlyProtocol { 
        require(msg.sender == trading, "!protocol");
        _;
    }

    event SetAllowedMargin(address _token, bool _isAllowed);
    event SetNode(address _node, bool _isNode);
    event SetChainlinkEnabled(bool _isEnabled);
    event SetValidSignatureTimer(uint256 _time);
}