// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

abstract contract TypeAndVersionInterface {
    function typeAndVersion() external pure virtual returns (string memory);
}
