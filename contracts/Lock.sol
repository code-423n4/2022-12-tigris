// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IBondNFT.sol";
import "./interfaces/IGovNFT.sol";

contract Lock is Ownable {

    uint256 public constant minPeriod = 7;
    uint256 public constant maxPeriod = 365;

    IBondNFT public immutable bondNFT;
    IGovNFT public immutable govNFT;

    mapping(address => bool) public allowedAssets;
    mapping(address => uint) public totalLocked;
    mapping(address => bool) private isApproved;

    constructor(
        address _bondNFTAddress,
        address _govNFT
    ) {
        bondNFT = IBondNFT(_bondNFTAddress);
        govNFT = IGovNFT(_govNFT);
    }

    /**
     * @notice Claim pending rewards from a bond
     * @param _id Bond NFT id
     * @return address claimed tigAsset address
     */
    function claim(
        uint256 _id
    ) public returns (address) {
        claimGovFees();
        (uint256 _amount, address _tigAsset) = bondNFT.claim(_id, msg.sender);
        IERC20(_tigAsset).transfer(msg.sender, _amount);
        return _tigAsset;
    }

    /**
     * @notice Claim pending rewards left over from a bond transfer
     * @param _tigAsset token address being claimed
     */
    function claimDebt(
        address _tigAsset
    ) external {
        claimGovFees();
        uint256 amount = bondNFT.claimDebt(msg.sender, _tigAsset);
        IERC20(_tigAsset).transfer(msg.sender, amount);
    }

    /**
     * @notice Lock up tokens to create a bond
     * @param _asset tigAsset being locked
     * @param _amount tigAsset amount
     * @param _period number of days to be locked for
     */
    function lock(
        address _asset,
        uint256 _amount,
        uint256 _period
    ) public {
        require(_period <= maxPeriod, "MAX PERIOD");
        require(_period >= minPeriod, "MIN PERIOD");
        require(allowedAssets[_asset], "!asset");

        claimGovFees();

        IERC20(_asset).transferFrom(msg.sender, address(this), _amount);
        totalLocked[_asset] = totalLocked[_asset] + _amount;
        
        bondNFT.createLock( _asset, _amount, _period, msg.sender);
    }

    /**
     * @notice Reset the lock time and extend the period and/or token amount
     * @param _id Bond id being extended
     * @param _amount tigAsset amount being added
     * @param _period number of days being added
     */
    function extendLock(
        uint256 _id,
        uint256 _amount,
        uint256 _period
    ) public {
        address _asset = claim(_id);
        IERC20(_asset).transferFrom(msg.sender, address(this), _amount);
        totalLocked[_asset] = totalLocked[_asset] + _amount;
        bondNFT.extendLock(_id, _asset, _amount, _period, msg.sender);
    }

    /**
     * @notice Release the bond once it's expired
     * @param _id Bond id being released
     */
    function release(
        uint256 _id
    ) public {
        claimGovFees();
        (uint256 amount, uint256 lockAmount, address asset, address _owner) = bondNFT.release(_id, msg.sender);
        totalLocked[asset] = totalLocked[asset] - lockAmount;
        IERC20(asset).transfer(_owner, amount);
    }

    /**
     * @notice Claim rewards from gov nfts and distribute them to bonds
     */
    function claimGovFees() public {
        address[] memory assets = bondNFT.getAssets();

        uint256 balanceBefore;
        uint256 balanceAfter;

        for (uint256 i=0; i < assets.length; i++) {
            balanceBefore = IERC20(assets[i]).balanceOf(address(this));
            IGovNFT(govNFT).claim(assets[i]);
            balanceAfter = IERC20(assets[i]).balanceOf(address(this));
            if (!isApproved[assets[i]]) {
                IERC20(assets[i]).approve(address(bondNFT), type(uint256).max);
                isApproved[assets[i]] = true;
            }
            bondNFT.distribute(assets[i], balanceAfter - balanceBefore);
        }
    }

    /**
     * @notice Whitelist an asset
     * @param _tigAsset tigAsset token address
     * @param _isAllowed set tigAsset as allowed
     */
    function editAsset(
        address _tigAsset,
        bool _isAllowed
    ) external onlyOwner() {
        allowedAssets[_tigAsset] = _isAllowed;
    }

    /**
     * @notice Owner can retreive Gov NFTs
     * @param _ids array of gov nft ids
     */
    function sendNFTs(
        uint[] memory _ids
    ) external onlyOwner() {
        govNFT.transferMany(msg.sender, _ids);
    }

    /**
     * @notice Owner can rescue tokens that are stuck in this contract
     * @param _token token address
     */
    function rescue(
        address _token
    ) external onlyOwner() {
        uint256 _toRescue = IERC20(_token).balanceOf(address(this)) - totalLocked[_token];
        IERC20(_token).transfer(owner(), _toRescue);
    }
}
