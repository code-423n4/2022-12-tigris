// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BondNFT is ERC721Enumerable, Ownable {
    
    uint256 constant private DAY = 1 days;
    uint256 constant private WEEKDAYS = 7;
    uint256 constant private COOLDOWN = 300;

    struct Bond {
        uint256 id;
        address owner;
        address asset;
        bool expired;
        uint256 amount;
        uint256 mintEpoch;
        uint256 mintTime;
        uint256 expireEpoch;
        uint256 pending;
        uint256 shares;
        uint256 period;
    }

    mapping(address => uint256) public epoch;
    uint256 private totalBonds;
    string public baseURI;
    address public manager;
    address[] public assets;

    mapping(address => bool) public allowedAsset;
    mapping(address => uint) private assetsIndex;
    mapping(uint256 => mapping(address => uint256)) private bondPaid;
    mapping(address => mapping(uint256 => uint256)) private accRewardsPerShare; // tigAsset => epoch => accRewardsPerShare
    mapping(uint256 => Bond) private _idToBond;
    mapping(address => uint) public totalShares;
    mapping(address => mapping(address => uint)) public userDebt; // user => tigAsset => amount

    constructor(
        string memory _setBaseURI,
        string memory _name,
        string memory _symbol
    ) ERC721(_name, _symbol) {
        baseURI = _setBaseURI;
    }

    /**
     * @notice Create a bond
     * @dev Should only be called by a manager contract
     * @param _asset tigAsset token to lock
     * @param _amount tigAsset amount
     * @param _period time to lock for in days
     * @param _owner address to receive the bond
     * @return id ID of the minted bond
     */
    function createLock(
        address _asset,
        uint256 _amount,
        uint256 _period,
        address _owner
    ) external onlyManager() returns(uint256 id) {
        require(allowedAsset[_asset], "!Asset");
        unchecked {
            uint256 shares = _amount * _period / 365;
            uint256 expireEpoch = epoch[_asset] + _period;
            id = ++totalBonds;
            totalShares[_asset] += shares;
            Bond memory _bond = Bond(
                id,             // id
                address(0),     // owner
                _asset,         // tigAsset token
                false,          // is expired boolean
                _amount,        // tigAsset amount
                epoch[_asset],  // mint epoch
                block.timestamp,// mint timestamp
                expireEpoch,    // expire epoch
                0,              // pending
                shares,         // linearly scaling share of rewards
                _period         // lock period
            );
            _idToBond[id] = _bond;
            _mint(_owner, _bond);
        }
        emit Lock(_asset, _amount, _period, _owner, id);
    }

    /** 
     * @notice Extend the lock period and/or amount of a bond
     * @dev Should only be called by a manager contract
     * @param _id ID of the bond
     * @param _asset tigAsset token address
     * @param _amount amount of tigAsset being added
     * @param _period days being added to the bond
     * @param _sender address extending the bond
     */
    function extendLock(
        uint256 _id,
        address _asset,
        uint256 _amount,
        uint256 _period,
        address _sender
    ) external onlyManager() {
        Bond memory bond = idToBond(_id);
        Bond storage _bond = _idToBond[_id];
        require(bond.owner == _sender, "!owner");
        require(!bond.expired, "Expired");
        require(bond.asset == _asset, "!BondAsset");
        require(bond.pending == 0);
        uint256 currentEpoch = block.timestamp/DAY;
        require(epoch[bond.asset] == block.timestamp/DAY, "Bad epoch");
        uint256 pendingEpochs = bond.expireEpoch - currentEpoch;
        uint256 newBondPeriod = pendingEpochs + _period;
        require(newBondPeriod >= 7, "MIN PERIOD");
        require(bond.period+_period <= 365, "MAX PERIOD");

        unchecked {
            uint256 shares = (bond.amount + _amount) * newBondPeriod / 365;
            uint256 expireEpoch = currentEpoch + newBondPeriod;
            totalShares[bond.asset] = totalShares[bond.asset]+shares-bond.shares;
            _bond.shares = shares;
            _bond.amount += _amount;
            _bond.expireEpoch = expireEpoch;
            _bond.period = newBondPeriod;
            _bond.mintTime = block.timestamp;
            _bond.mintEpoch = currentEpoch;
            bondPaid[_id][bond.asset] = accRewardsPerShare[bond.asset][currentEpoch] * _bond.shares / 1e18;
        }
        emit ExtendLock(_period, _amount, _sender,  _id);
    }

    /**
     * @notice Release a bond
     * @dev Should only be called by a manager contract
     * @param _id ID of the bond
     * @param _releaser address initiating the release of the bond
     * @return amount amount of tigAsset returned
     * @return lockAmount amount of tigAsset locked in the bond
     * @return asset tigAsset token released
     * @return _owner bond owner
     */
    function release(
        uint256 _id,
        address _releaser
    ) external onlyManager() returns(uint256 amount, uint256 lockAmount, address asset, address _owner) {
        Bond memory bond = idToBond(_id);
        require(bond.expired, "!expire");
        if (_releaser != bond.owner) {
            unchecked {
                require(bond.expireEpoch + 7 < epoch[bond.asset], "Bond owner priority");
            }
        }
        amount = bond.amount;
        unchecked {
            totalShares[bond.asset] = totalShares[bond.asset] - bond.shares;
            uint256 _bondPaid = bondPaid[_id][bond.asset];

            uint256 _pendingDelta = (bond.shares * accRewardsPerShare[bond.asset][epoch[bond.asset]] / 1e18 - _bondPaid) - (bond.shares * accRewardsPerShare[bond.asset][bond.expireEpoch-1] / 1e18 - _bondPaid);

            uint _totalShares = totalShares[bond.asset];
            if (_totalShares > 0) {
                accRewardsPerShare[bond.asset][epoch[bond.asset]] += _pendingDelta*1e18/_totalShares;
            }
            (uint256 _claimAmount,) = claim(_id, bond.owner);
            amount = amount + _claimAmount;
        }
        asset = bond.asset;
        lockAmount = bond.amount;
        _owner = bond.owner;
        _burn(_id);
        emit Release(asset, lockAmount, _owner, _id);
    }
    /**
     * @notice Claim rewards from a bond
     * @dev Should only be called by a manager contract
     * @param _id ID of the bond to claim rewards from
     * @param _claimer address claiming rewards
     * @return amount amount of tigAsset claimed
     * @return tigAsset tigAsset token address
     */
    function claim(
        uint256 _id,
        address _claimer
    ) public onlyManager() returns(uint256 amount, address tigAsset) {
        Bond memory bond = idToBond(_id);
        require(_claimer == bond.owner, "!owner");
        amount = bond.pending;
        tigAsset = bond.asset;
        unchecked {
            bondPaid[_id][bond.asset] += amount;
        }
        IERC20(tigAsset).transfer(manager, amount);
        emit ClaimFees(tigAsset, amount, _claimer, _id);
    }

    /**
     * @notice Claim user debt left from bond transfer
     * @dev Should only be called by a manager contract
     * @param _user user address
     * @param _tigAsset tigAsset token address
     * @return amount amount of tigAsset claimed
     */
    function claimDebt(
        address _user,
        address _tigAsset
    ) public onlyManager() returns(uint256 amount) {
        amount = userDebt[_user][_tigAsset];
        userDebt[_user][_tigAsset] = 0;
        IERC20(_tigAsset).transfer(manager, amount);
        emit ClaimDebt(_tigAsset, amount, _user);
    }

    /**
     * @notice Distribute rewards to bonds
     * @param _tigAsset tigAsset token address
     * @param _amount tigAsset amount
     */
    function distribute(
        address _tigAsset,
        uint256 _amount
    ) external {
        if (!allowedAsset[_tigAsset]) return;
        uint256 aEpoch;
        unchecked {
            aEpoch = block.timestamp / DAY;
            if (aEpoch > epoch[_tigAsset]) {
                for (uint256 i=epoch[_tigAsset]; i<aEpoch; i++) {
                    epoch[_tigAsset] += 1;
                    accRewardsPerShare[_tigAsset][i+1] = accRewardsPerShare[_tigAsset][i];
                }
            }
        }
        if (totalShares[_tigAsset] == 0) return;
        unchecked {
            accRewardsPerShare[_tigAsset][aEpoch] += _amount * 1e18 / totalShares[_tigAsset];
        }
        IERC20(_tigAsset).transferFrom(_msgSender(), address(this), _amount);
        emit Distribution(_tigAsset, _amount);
    }

    /**
     * @notice Get all data for a bond
     * @param _id ID of the bond
     * @return bond Bond object
     */
    function idToBond(uint256 _id) public view returns (Bond memory bond) {
        bond = _idToBond[_id];
        bond.owner = ownerOf(_id);
        bond.expired = bond.expireEpoch <= epoch[bond.asset] ? true : false;
        unchecked {
            uint256 _accRewardsPerShare = accRewardsPerShare[bond.asset][bond.expired ? bond.expireEpoch-1 : epoch[bond.asset]];
            bond.pending = bond.shares * _accRewardsPerShare / 1e18 - bondPaid[_id][bond.asset];
        }
    }

    /*
     * @notice Get expired boolean for a bond
     * @param _id ID of the bond
     * @return bool true if bond is expired
     */
    function isExpired(uint256 _id) public view returns (bool) {
        Bond memory bond = _idToBond[_id];
        return bond.expireEpoch <= epoch[bond.asset] ? true : false;
    }

    /*
     * @notice Get pending rewards for a bond
     * @param _id ID of the bond
     * @return bool true if bond is expired
     */
    function pending(
        uint256 _id
    ) public view returns (uint256) {
        return idToBond(_id).pending;
    }

    function totalAssets() public view returns (uint256) {
        return assets.length;
    }

    /*
     * @notice Gets an array of all whitelisted token addresses
     * @return address array of addresses
     */
    function getAssets() public view returns (address[] memory) {
        return assets;
    }

    function _baseURI() internal override view returns (string memory) {
        return baseURI;
    }

    function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data) internal override {
        _transfer(from, to, tokenId);
    }

    function transferMany(address _to, uint[] calldata _ids) external {
        unchecked {
            for (uint256 i=0; i<_ids.length; i++) {
                _transfer(_msgSender(), _to, _ids[i]);
            }
        }
    }

    function transferFromMany(address _from, address _to, uint[] calldata _ids) external {
        unchecked {
            for (uint256 i=0; i<_ids.length; i++) {
                transferFrom(_from, _to, _ids[i]);
            }
        }
    }

    function approveMany(address _to, uint[] calldata _ids) external {
        unchecked {
            for (uint256 i=0; i<_ids.length; i++) {
                approve(_to, _ids[i]);
            }
        }
    }

    function _mint(
        address to,
        Bond memory bond
    ) internal {
        unchecked {
            bondPaid[bond.id][bond.asset] = accRewardsPerShare[bond.asset][epoch[bond.asset]] * bond.shares / 1e18;
        }
        _mint(to, bond.id);
    }

    function _burn(
        uint256 _id
    ) internal override {
        delete _idToBond[_id];
        super._burn(_id);
    }

    function _transfer(
        address from,
        address to,
        uint256 _id
    ) internal override {
        Bond memory bond = idToBond(_id);
        require(bond.expireEpoch > block.timestamp/DAY, "Transfer after expiration");
        unchecked {
            require(block.timestamp > bond.mintTime + COOLDOWN, "Recent update");
            userDebt[from][bond.asset] += bond.pending;
            bondPaid[_id][bond.asset] += bond.pending;
        }
        super._transfer(from, to, _id);
    }

    function balanceIds(address _user) public view returns (uint[] memory) {
        uint[] memory _ids = new uint[](balanceOf(_user));
        unchecked {
            for (uint256 i=0; i<_ids.length; i++) {
                _ids[i] = tokenOfOwnerByIndex(_user, i);
            }
        }
        return _ids;
    }

    function addAsset(address _asset) external onlyOwner {
        require(assets.length == 0 || assets[assetsIndex[_asset]] != _asset, "Already added");
        assetsIndex[_asset] = assets.length;
        assets.push(_asset);
        allowedAsset[_asset] = true;
        epoch[_asset] = block.timestamp/DAY;
    }

    function setAllowedAsset(address _asset, bool _bool) external onlyOwner {
        require(assets[assetsIndex[_asset]] == _asset, "Not added");
        allowedAsset[_asset] = _bool;
    }

    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    function setManager(
        address _manager
    ) public onlyOwner() {
        manager = _manager;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "!manager");
        _;
    }

    event Distribution(address _tigAsset, uint256 _amount);
    event Lock(address _tigAsset, uint256 _amount, uint256 _period, address _owner, uint256 _id);
    event ExtendLock(uint256 _period, uint256 _amount, address _owner, uint256 _id);
    event Release(address _tigAsset, uint256 _amount, address _owner, uint256 _id);
    event ClaimFees(address _tigAsset, uint256 _amount, address _claimer, uint256 _id);
    event ClaimDebt(address _tigAsset, uint256 _amount, address _owner);
}