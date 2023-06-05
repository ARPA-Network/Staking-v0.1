// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC165} from "openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import {Staking, StakingPoolLib, RewardLib, IMigrationTarget, SafeERC20, IERC20} from "../src/Staking.sol";

contract MockStakingMigrationTarget is Staking, IMigrationTarget, IERC165 {
    using StakingPoolLib for StakingPoolLib.Pool;
    using RewardLib for RewardLib.Reward;
    using SafeERC20 for IERC20;

    mapping(address => bytes) public migratedData;

    // solhint-disable-next-line no-empty-blocks
    constructor(PoolConstructorParams memory params) Staking(params) {}

    function migrateFrom(uint256 amount, bytes calldata data) external override(IMigrationTarget) {
        (address sender, bytes memory stakerData) = abi.decode(data, (address, bytes));
        migratedData[sender] = stakerData;
        if (_pool._isOperator(sender)) {
            _stakeAsOperator(sender, _operatorStakeAmount);
            if (amount > _operatorStakeAmount) {
                _arpa.safeTransfer(sender, amount - _operatorStakeAmount);
            }
        } else {
            _stakeAsCommunityStaker(sender, amount);
        }
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == this.supportsInterface.selector || interfaceID == this.migrateFrom.selector;
    }
}
