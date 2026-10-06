// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}