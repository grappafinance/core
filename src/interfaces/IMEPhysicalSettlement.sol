// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Settlement} from "../config/types.sol";

interface IMEPhysicalSettlement {
    function registerIssuer(address _subAccount) external returns (uint16 id);

    function settlePhysicalOption(Settlement calldata _settlement) external;

    function getPhysicalSettlementPerToken(uint256 _tokenId) external view returns (Settlement memory settlement);
}
