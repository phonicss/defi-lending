//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice() external override view returns (uint256) {
        return price;
    }
}

