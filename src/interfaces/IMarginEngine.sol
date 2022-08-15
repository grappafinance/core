// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TokenType} from "../config/types.sol";

interface IMarginEngine {
    function isAccountHealthy(address _subAccount) external view returns (bool);

    function getMinCollateral(address _subAccount) external view returns (uint256);

    function increaseCollateral(
        address _subAccount,
        address _from,
        address _collateral,
        uint8 _collateralId,
        uint80 _amount
    ) external;

    function decreaseCollateral(
        address _subAccount,
        address _to,
        address _collateral,
        uint8 collateralId,
        uint80 amount
    ) external;

    function increaseDebt(
        address _subAccount,
        uint256 optionId,
        uint64 amount
    ) external;

    function decreaseDebt(
        address _subAccount,
        uint256 optionId,
        uint64 amount
    ) external;

    function merge(address _subAccount, uint256 _optionId) external returns (uint64 burnAmount);

    function split(address _subAccount, TokenType tokenType) external returns (uint256 optionId, uint64 mintAmount);

    function liquidate(
        address _subAccount,
        address _liquidator,
        uint256[] memory tokensToBurn,
        uint256[] memory amountsToBurn
    ) external returns (uint8 collateralId, uint80 amountToPay);

    function payCashValue(
        address _asset,
        address _recipient,
        uint256 _amount
    ) external;

    function settleAtExpiry(address _subAccount) external;
}
