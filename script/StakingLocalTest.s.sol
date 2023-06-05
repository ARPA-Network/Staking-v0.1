// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {Staking, IERC20} from "../src/Staking.sol";
import {Arpa} from "./ArpaLocalTest.sol";

contract StakingLocalTestScript is Script {
    uint256 internal _deployerPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
    uint256 internal _plentyOfArpaBalance = vm.envUint("PLENTY_OF_ARPA_BALANCE");
    address internal _node1Address = vm.envAddress("NODE_1");
    address internal _node2Address = vm.envAddress("NODE_2");
    uint256 internal _initialMaxPoolSize = vm.envUint("INITIAL_MAX_POOL_SIZE");
    uint256 internal _initialMaxCommunityStakeAmount = vm.envUint("INITIAL_MAX_COMMUNITY_STAKE_AMOUNT");
    uint256 internal _minCommunityStakeAmount = vm.envUint("MIN_COMMUNITY_STAKE_AMOUNT");
    uint256 internal _operatorStakeAmount = vm.envUint("OPERATOR_STAKE_AMOUNT");
    uint256 internal _minInitialOperatorCount = vm.envUint("MIN_INITIAL_OPERATOR_COUNT");
    uint256 internal _minRewardDuration = vm.envUint("MIN_REWARD_DURATION");
    uint256 internal _delegationRateDenominator = vm.envUint("DELEGATION_RATE_DENOMINATOR");
    uint256 internal _unstakeFreezingDuration = vm.envUint("UNSTAKE_FREEZING_DURATION");

    function run() external {
        Staking staking;
        Arpa arpa;

        vm.broadcast(_deployerPrivateKey);
        arpa = new Arpa();

        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(arpa)),
            _initialMaxPoolSize,
            _initialMaxCommunityStakeAmount,
            _minCommunityStakeAmount,
            _operatorStakeAmount,
            _minInitialOperatorCount,
            _minRewardDuration,
            _delegationRateDenominator,
            _unstakeFreezingDuration
        );

        vm.broadcast(_deployerPrivateKey);
        staking = new Staking(params);

        vm.broadcast(_deployerPrivateKey);
        arpa.approve(address(staking), _plentyOfArpaBalance);

        address[] memory operators = new address[](2);
        operators[0] = _node1Address;
        operators[1] = _node2Address;
        vm.broadcast(_deployerPrivateKey);
        staking.addOperators(operators);
    }
}
