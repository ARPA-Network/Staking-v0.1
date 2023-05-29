// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import "openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import "src/Staking.sol";
import "src/interfaces/IMigrationTarget.sol";

contract MockStakingMigrationTarget is Staking, IMigrationTarget, IERC165 {
    using StakingPoolLib for StakingPoolLib.Pool;
    using RewardLib for RewardLib.Reward;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    mapping(address => bytes) public migratedData;

    constructor(PoolConstructorParams memory params) Staking(params) {}

    function migrateFrom(uint256 amount, bytes calldata data) external override(IMigrationTarget) {
        (address sender, bytes memory stakerData) = abi.decode(data, (address, bytes));
        migratedData[sender] = stakerData;
        if (s_pool._isOperator(sender)) {
            _stakeAsOperator(sender, i_operatorStakeAmount);
            if (amount > i_operatorStakeAmount) {
                i_ARPA.safeTransfer(sender, amount - i_operatorStakeAmount);
            }
        } else {
            _stakeAsCommunityStaker(sender, amount);
        }
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == this.supportsInterface.selector || interfaceID == this.migrateFrom.selector;
    }
}
