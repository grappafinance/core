// SPDX-License-Identifier: MIT
// solhint-disable no-empty-blocks
pragma solidity ^0.8.0;

// imported contracts and libraries
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// inheriting contracts
import {BaseEngine} from "../BaseEngine.sol";

// librarise
import {ProductIdUtil} from "../../../libraries/ProductIdUtil.sol";
import {TokenIdUtil} from "../../../libraries/TokenIdUtil.sol";
import {NumberUtil} from "../../../libraries/NumberUtil.sol";

// // constants and types
import "../../../config/constants.sol";
import "../../../config/enums.sol";
import "../../../config/errors.sol";
import "../../../config/types.sol";

/**
 * @title   DebitSpread
 * @author  @dsshap
 * @notice  util functions for MarginEngines to support physically settled derivatives
 */
abstract contract PhysicallySettled is BaseEngine {
    using NumberUtil for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @dev next id used to represent an address
    /// invariant:  any id in tokenId not greater than this number
    uint16 public nextIssuerId;

    /// @dev address => issuerId
    mapping(address => uint16) public issuerIds;

    /// @dev issuerId => issuer address
    mapping(uint16 => address) public issuers;

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event IssuerRegistered(address subAccount, uint16 id);

    // TODO add set settlementWindow function
    // TODO should settleOption check for aboveWater on subAccount?
    // TODO CMLib settle shorts and longs
    // TODO check that margining math is properly accounting for co-mingled options
    // Change Runs on CME to 10_000

    /*///////////////////////////////////////////////////////////////
                            External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev register an issuer for physical options
     * @param _subAccount address of the new margin engine
     *
     */
    function registerIssuer(address _subAccount) public virtual returns (uint16 id) {
        if (issuerIds[_subAccount] != 0) revert PS_IssuerAlreadyRegistered();

        id = ++nextIssuerId;
        issuers[id] = _subAccount;

        issuerIds[_subAccount] = id;

        emit IssuerRegistered(_subAccount, id);
    }

    function settlePhysicalOption(Settlement calldata _settlement) public virtual {
        _checkIsGrappa();

        address _subAccount = _getIssuer(_settlement.tokenId);

        // issuer of option gets underlying asset (PUT) or strike asset (CALL)
        _receiveDebtValue(_settlement.debtAssetId, _settlement.debtor, _subAccount, _settlement.debt);

        // option owner gets collateral
        _sendPayoutValue(_settlement.payoutAssetId, _settlement.creditor, _subAccount, _settlement.payout);

        // option burned, removing debt from issuer
        _decreaseShortInAccount(_subAccount, _settlement.tokenId, _settlement.tokenAmount.toUint64());
    }

    /**
     * @dev calculate the payout for one physically settled derivative token
     * @param _tokenId  token id of derivative token
     * @return settlement struct
     */
    function getPhysicalSettlementPerToken(uint256 _tokenId) public view virtual returns (Settlement memory settlement) {
        (DerivativeType derivativeType, SettlementType settlementType, uint40 productId, uint64 expiry, uint64 strike,) =
            TokenIdUtil.parseTokenId(_tokenId);

        if (settlementType == SettlementType.CASH) revert PS_InvalidSettlementType();

        // settlement window
        bool settlementWindowOpen = block.timestamp < expiry + 1 hours;

        if (settlementWindowOpen) {
            // cash value denominated in strike (usually USD), with {UNIT_DECIMALS} decimals
            uint256 strikePrice = uint256(strike);

            (,, uint8 underlyingId, uint8 strikeId, uint8 collateralId) = ProductIdUtil.parseProductId(productId);

            (, uint8 strikeDecimals) = grappa.assets(strikeId);
            uint256 strikeAmount = strikePrice.convertDecimals(UNIT_DECIMALS, strikeDecimals);

            if (derivativeType == DerivativeType.CALL) {
                settlement.debtAssetId = strikeId;
                settlement.debtPerToken = strikeAmount;

                settlement.payoutAssetId = collateralId;
                (, uint8 collateralDecimals) = grappa.assets(collateralId);
                settlement.payoutPerToken = UNIT.convertDecimals(UNIT_DECIMALS, collateralDecimals);
            } else if (derivativeType == DerivativeType.PUT) {
                settlement.debtAssetId = underlyingId;
                (, uint8 underlyingDecimals) = grappa.assets(underlyingId);
                settlement.debtPerToken = UNIT.convertDecimals(UNIT_DECIMALS, underlyingDecimals);

                settlement.payoutAssetId = strikeId;
                settlement.payoutPerToken = strikeAmount;
            }
        }
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev mint option token to _subAccount, checks issuer is properly set
     * @param _data bytes data to decode
     */
    function _mintOption(address _subAccount, bytes calldata _data) internal virtual override (BaseEngine) {
        // decode parameters
        (uint256 tokenId,,) = abi.decode(_data, (uint256, address, uint64));

        (, SettlementType settlementType,,,,) = TokenIdUtil.parseTokenId(tokenId);

        // only check if issuer is properly set if physically settled option
        if (settlementType == SettlementType.PHYSICAL) {
            address issuer = _getIssuer(tokenId);

            if (issuer != _subAccount) revert PS_InvalidIssuerAddress();
        }

        BaseEngine._mintOption(_subAccount, _data);
    }

    /**
     * @notice payout to user on settlement.
     * @dev this can only triggered by Grappa, would only be called on settlement.
     * @param _assetId asset id to transfer
     * @param _sender sender of debt
     * @param _subAccount receiver
     * @param _amount amount
     */
    function _receiveDebtValue(uint8 _assetId, address _sender, address _subAccount, uint256 _amount) internal {
        (address _asset,) = grappa.assets(_assetId);

        _addCollateralToAccount(_subAccount, _assetId, _amount.toUint80());

        if (_sender != address(this)) IERC20(_asset).safeTransferFrom(_sender, address(this), _amount);
    }

    /**
     * @notice payout to user on settlement.
     * @dev this can only triggered by Grappa, would only be called on settlement.
     * @param _assetId asset id to transfer
     * @param _recipient receiver of payout
     * @param _subAccount of the sender
     * @param _amount amount
     */
    function _sendPayoutValue(uint8 _assetId, address _recipient, address _subAccount, uint256 _amount) internal {
        (address _asset,) = grappa.assets(_assetId);

        _removeCollateralFromAccount(_subAccount, _assetId, _amount.toUint80());

        if (_recipient != address(this)) IERC20(_asset).safeTransfer(_recipient, _amount);
    }

    function _getIssuer(uint256 _tokenId) internal view returns (address issuer) {
        return issuers[_getIssuerId(_tokenId)];
    }

    function _getIssuerId(uint256 _tokenId) internal pure returns (uint16 issuerId) {
        // since issuer id is uint16 of the last 16 bits of tokenId, we can just cast to uint16
        return uint16(_tokenId);
    }
}
