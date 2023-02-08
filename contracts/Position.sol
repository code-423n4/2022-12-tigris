// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./utils/MetaContext.sol";
import "./interfaces/IPosition.sol";

contract Position is ERC721Enumerable, MetaContext, IPosition {

    using Counters for Counters.Counter;
    uint256 constant public DIVISION_CONSTANT = 1e10; // 100%

    mapping(uint256 => mapping(address => uint)) public vaultFundingPercent;

    mapping(address => bool) private _isMinter; // Trading contract should be minter
    mapping(uint256 => Trade) private _trades; // NFT id to Trade

    uint256[] private _openPositions;
    mapping(uint256 => uint256) private _openPositionsIndexes;

    mapping(uint256 => uint256[]) private _assetOpenPositions;
    mapping(uint256 => mapping(uint256 => uint256)) private _assetOpenPositionsIndexes;

    mapping(uint256 => uint256[]) private _limitOrders; // List of limit order nft ids per asset
    mapping(uint256 => mapping(uint256 => uint256)) private _limitOrderIndexes; // Keeps track of asset -> id -> array index

    // Funding
    mapping(uint256 => mapping(address => int256)) public fundingDeltaPerSec;
    mapping(uint256 => mapping(address => mapping(bool => int256))) private accInterestPerOi;
    mapping(uint256 => mapping(address => uint256)) private lastUpdate;
    mapping(uint256 => int256) private initId;
    mapping(uint256 => mapping(address => uint256)) private longOi;
    mapping(uint256 => mapping(address => uint256)) private shortOi;

    constructor(string memory _setBaseURI, string memory _name, string memory _symbol) ERC721(_name, _symbol) {
        baseURI = _setBaseURI;
        _tokenIds.increment();
    }

    function ownerOf(uint256 _id) public view override(ERC721, IERC721, IPosition) returns (address) {
        return ERC721.ownerOf(_id);
    }

    function isMinter(address _address) public view returns (bool) { return _isMinter[_address]; }
    function trades(uint256 _id) public view returns (Trade memory) {
        Trade memory _trade = _trades[_id];
        _trade.trader = ownerOf(_id);
        if (_trade.orderType > 0) return _trade;
        
        int256 _pendingFunding;
        uint256 _longOi = longOi[_trade.asset][_trade.tigAsset];
        uint256 _shortOi = shortOi[_trade.asset][_trade.tigAsset];

        if (_trade.direction && _longOi > 0) {
            _pendingFunding = (int256(block.timestamp-lastUpdate[_trade.asset][_trade.tigAsset])*fundingDeltaPerSec[_trade.asset][_trade.tigAsset])*1e18/int256(_longOi);
            if (_longOi > _shortOi) {
                _pendingFunding = -_pendingFunding;
            } else {
                _pendingFunding = _pendingFunding*int256(1e10-vaultFundingPercent[_trade.asset][_trade.tigAsset])/1e10;
            }
        } else if (_shortOi > 0) {
            _pendingFunding = (int256(block.timestamp-lastUpdate[_trade.asset][_trade.tigAsset])*fundingDeltaPerSec[_trade.asset][_trade.tigAsset])*1e18/int256(_shortOi);
            if (_shortOi > _longOi) {
                _pendingFunding = -_pendingFunding;
            } else {
                _pendingFunding = _pendingFunding*int256(1e10-vaultFundingPercent[_trade.asset][_trade.tigAsset])/1e10;
            }
        }
        _trade.accInterest += (int256(_trade.margin*_trade.leverage/1e18)*(accInterestPerOi[_trade.asset][_trade.tigAsset][_trade.direction]+_pendingFunding)/1e18)-initId[_id];
        
        return _trade;
    }
    function openPositions() public view returns (uint256[] memory) { return _openPositions; }
    function openPositionsIndexes(uint256 _id) public view returns (uint256) { return _openPositionsIndexes[_id]; }
    function assetOpenPositions(uint256 _asset) public view returns (uint256[] memory) { return _assetOpenPositions[_asset]; }
    function assetOpenPositionsIndexes(uint256 _asset, uint256 _id) public view returns (uint256) { return _assetOpenPositionsIndexes[_asset][_id]; }
    function limitOrders(uint256 _asset) public view returns (uint256[] memory) { return _limitOrders[_asset]; }
    function limitOrderIndexes(uint256 _asset, uint256 _id) public view returns (uint256) { return _limitOrderIndexes[_asset][_id]; }

    Counters.Counter private _tokenIds;
    string public baseURI;

    function _baseURI() internal override view returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    /**
    * @notice Update funding rate after open interest change
    * @dev only callable by minter
    * @param _asset pair id
    * @param _tigAsset tigAsset token address
    * @param _longOi long open interest
    * @param _shortOi short open interest
    * @param _baseFundingRate base funding rate of a pair
    * @param _vaultFundingPercent percent of earned funding going to the stablevault
    */
    function updateFunding(uint256 _asset, address _tigAsset, uint256 _longOi, uint256 _shortOi, uint256 _baseFundingRate, uint256 _vaultFundingPercent) external onlyMinter {
        uint256 _longOiAsset = longOi[_asset][_tigAsset];
        uint256 _shortOiAsset = shortOi[_asset][_tigAsset];
        uint256 _lastUpdate = lastUpdate[_asset][_tigAsset];
        int256 _fundingDeltaPerSec = fundingDeltaPerSec[_asset][_tigAsset];

        if(_longOiAsset < _shortOiAsset) {
            if (_longOiAsset > 0) {
                accInterestPerOi[_asset][_tigAsset][true] += ((int256(block.timestamp-_lastUpdate)*_fundingDeltaPerSec)*1e18/int256(_longOiAsset))*int256(1e10-vaultFundingPercent[_asset][_tigAsset])/1e10;
            }
            accInterestPerOi[_asset][_tigAsset][false] -= (int256(block.timestamp-_lastUpdate)*_fundingDeltaPerSec)*1e18/int256(_shortOiAsset);

        } else if(_longOiAsset > _shortOiAsset) {
            accInterestPerOi[_asset][_tigAsset][true] -= (int256(block.timestamp-_lastUpdate)*_fundingDeltaPerSec)*1e18/int256(_longOiAsset);
            if (_shortOiAsset > 0) {
                accInterestPerOi[_asset][_tigAsset][false] += ((int256(block.timestamp-_lastUpdate)*_fundingDeltaPerSec)*1e18/int256(_shortOiAsset))*int256(1e10-vaultFundingPercent[_asset][_tigAsset])/1e10;
            }
        }
        lastUpdate[_asset][_tigAsset] = block.timestamp;
        int256 _oiDelta;
        if (_longOi > _shortOi) {
            unchecked { _oiDelta = int256(_longOi)-int256(_shortOi); }
        } else {
            unchecked { _oiDelta = int256(_shortOi)-int256(_longOi); }
        }
        
        fundingDeltaPerSec[_asset][_tigAsset] = (_oiDelta*int256(_baseFundingRate)/int256(DIVISION_CONSTANT))/31536000;
        longOi[_asset][_tigAsset] = _longOi;
        shortOi[_asset][_tigAsset] = _shortOi;
        vaultFundingPercent[_asset][_tigAsset] = _vaultFundingPercent;
    }

    /**
    * @notice mint a new position nft
    * @dev only callable by minter
    * @param _mintTrade New trade params in struct
    */
    function mint(
        MintTrade memory _mintTrade
    ) external onlyMinter {
        uint256 newTokenID = _tokenIds.current();

        Trade storage newTrade = _trades[newTokenID];
        newTrade.margin = _mintTrade.margin;
        newTrade.leverage = _mintTrade.leverage;
        newTrade.asset = _mintTrade.asset;
        newTrade.direction = _mintTrade.direction;
        newTrade.price = _mintTrade.price;
        newTrade.tpPrice = _mintTrade.tp;
        newTrade.slPrice = _mintTrade.sl;
        newTrade.orderType = _mintTrade.orderType;
        newTrade.id = newTokenID;
        newTrade.tigAsset = _mintTrade.tigAsset;

        if (_mintTrade.orderType > 0) {
            _limitOrders[_mintTrade.asset].push(newTokenID);
            _limitOrderIndexes[_mintTrade.asset][newTokenID] = _limitOrders[_mintTrade.asset].length-1;
        } else {
            initId[newTokenID] = accInterestPerOi[_mintTrade.asset][_mintTrade.tigAsset][_mintTrade.direction]*int256(_mintTrade.margin*_mintTrade.leverage/1e18)/1e18;
            _openPositions.push(newTokenID);
            _openPositionsIndexes[newTokenID] = _openPositions.length-1;

            _assetOpenPositions[_mintTrade.asset].push(newTokenID);
            _assetOpenPositionsIndexes[_mintTrade.asset][newTokenID] = _assetOpenPositions[_mintTrade.asset].length-1;
        }
        _tokenIds.increment();
        _mint(_mintTrade.account, newTokenID);
    }

    /**
     * @param _id id of the position NFT
     * @param _price price used for execution
     * @param _newMargin margin after fees
     */
    function executeLimitOrder(uint256 _id, uint256 _price, uint256 _newMargin) external onlyMinter {
        Trade storage _trade = _trades[_id];
        if (_trade.orderType == 0) {
            return;
        }
        _trade.orderType = 0;
        _trade.price = _price;
        _trade.margin = _newMargin;
        uint256 _asset = _trade.asset;
        _limitOrderIndexes[_asset][_limitOrders[_asset][_limitOrders[_asset].length-1]] = _limitOrderIndexes[_asset][_id];
        _limitOrders[_asset][_limitOrderIndexes[_asset][_id]] = _limitOrders[_asset][_limitOrders[_asset].length-1];
        delete _limitOrderIndexes[_asset][_id];
        _limitOrders[_asset].pop();

        _openPositions.push(_id);
        _openPositionsIndexes[_id] = _openPositions.length-1;
        _assetOpenPositions[_asset].push(_id);
        _assetOpenPositionsIndexes[_asset][_id] = _assetOpenPositions[_asset].length-1;

        initId[_id] = accInterestPerOi[_asset][_trade.tigAsset][_trade.direction]*int256(_newMargin*_trade.leverage/1e18)/1e18;
    }

    /**
    * @notice modifies margin and leverage
    * @dev only callable by minter
    * @param _id position id
    * @param _newMargin new margin amount
    * @param _newLeverage new leverage amount
    */
    function modifyMargin(uint256 _id, uint256 _newMargin, uint256 _newLeverage) external onlyMinter {
        _trades[_id].margin = _newMargin;
        _trades[_id].leverage = _newLeverage;
    }

    /**
    * @notice modifies margin and entry price
    * @dev only callable by minter
    * @param _id position id
    * @param _newMargin new margin amount
    * @param _newPrice new entry price
    */
    function addToPosition(uint256 _id, uint256 _newMargin, uint256 _newPrice) external onlyMinter {
        _trades[_id].margin = _newMargin;
        _trades[_id].price = _newPrice;
        initId[_id] = accInterestPerOi[_trades[_id].asset][_trades[_id].tigAsset][_trades[_id].direction]*int256(_newMargin*_trades[_id].leverage/1e18)/1e18;
    }

    /**
    * @notice Called before updateFunding for reducing position or adding to position, to store accumulated funding
    * @dev only callable by minter
    * @param _id position id
    */
    function setAccInterest(uint256 _id) external onlyMinter {
        _trades[_id].accInterest = trades(_id).accInterest;
    }

    /**
    * @notice Reduces position size by %
    * @dev only callable by minter
    * @param _id position id
    * @param _percent percent of a position being closed
    */
    function reducePosition(uint256 _id, uint256 _percent) external onlyMinter {
        _trades[_id].accInterest -= _trades[_id].accInterest*int256(_percent)/int256(DIVISION_CONSTANT);
        _trades[_id].margin -= _trades[_id].margin*_percent/DIVISION_CONSTANT;
        initId[_id] = accInterestPerOi[_trades[_id].asset][_trades[_id].tigAsset][_trades[_id].direction]*int256(_trades[_id].margin*_trades[_id].leverage/1e18)/1e18;
    }

    /**
    * @notice change a position tp price
    * @dev only callable by minter
    * @param _id position id
    * @param _tpPrice tp price
    */
    function modifyTp(uint256 _id, uint256 _tpPrice) external onlyMinter {
        _trades[_id].tpPrice = _tpPrice;
    }

    /**
    * @notice change a position sl price
    * @dev only callable by minter
    * @param _id position id
    * @param _slPrice sl price
    */
    function modifySl(uint256 _id, uint256 _slPrice) external onlyMinter {
        _trades[_id].slPrice = _slPrice;
    }

    /**
    * @dev Burns an NFT and it's data
    * @param _id ID of the trade
    */
    function burn(uint256 _id) external onlyMinter {
        _burn(_id);
        uint256 _asset = _trades[_id].asset;
        if (_trades[_id].orderType > 0) {
            _limitOrderIndexes[_asset][_limitOrders[_asset][_limitOrders[_asset].length-1]] = _limitOrderIndexes[_asset][_id];
            _limitOrders[_asset][_limitOrderIndexes[_asset][_id]] = _limitOrders[_asset][_limitOrders[_asset].length-1];
            delete _limitOrderIndexes[_asset][_id];
            _limitOrders[_asset].pop();            
        } else {
            _assetOpenPositionsIndexes[_asset][_assetOpenPositions[_asset][_assetOpenPositions[_asset].length-1]] = _assetOpenPositionsIndexes[_asset][_id];
            _assetOpenPositions[_asset][_assetOpenPositionsIndexes[_asset][_id]] = _assetOpenPositions[_asset][_assetOpenPositions[_asset].length-1];
            delete _assetOpenPositionsIndexes[_asset][_id];
            _assetOpenPositions[_asset].pop();  

            _openPositionsIndexes[_openPositions[_openPositions.length-1]] = _openPositionsIndexes[_id];
            _openPositions[_openPositionsIndexes[_id]] = _openPositions[_openPositions.length-1];
            delete _openPositionsIndexes[_id];
            _openPositions.pop();              
        }
        delete _trades[_id];
    }

    function assetOpenPositionsLength(uint256 _asset) external view returns (uint256) {
        return _assetOpenPositions[_asset].length;
    }

    function limitOrdersLength(uint256 _asset) external view returns (uint256) {
        return _limitOrders[_asset].length;
    }

    function getCount() external view returns (uint) {
        return _tokenIds.current();
    }

    function userTrades(address _user) external view returns (uint[] memory) {
        uint[] memory _ids = new uint[](balanceOf(_user));
        for (uint256 i=0; i<_ids.length; i++) {
            _ids[i] = tokenOfOwnerByIndex(_user, i);
        }
        return _ids;
    }

    function openPositionsSelection(uint256 _from, uint256 _to) external view returns (uint[] memory) {
        uint[] memory _ids = new uint[](_to-_from);
        for (uint256 i=0; i<_ids.length; i++) {
            _ids[i] = _openPositions[i+_from];
        }
        return _ids;
    }

    function setMinter(address _minter, bool _bool) external onlyOwner {
        _isMinter[_minter] = _bool;
    }    

    modifier onlyMinter() {
        require(_isMinter[_msgSender()], "!Minter");
        _;
    }

    // META-TX
    function _msgSender() internal view override(Context, MetaContext) returns (address) {
        return MetaContext._msgSender();
    }
    function _msgData() internal view override(Context, MetaContext) returns (bytes calldata) {
        return MetaContext._msgData();
    }
}