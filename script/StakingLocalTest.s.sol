// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import {Staking, ArpaTokenInterface} from "../src/Staking.sol";
import "./ArpaLocalTest.sol";

contract StakingLocalTestScript is Script {
    uint256 deployerPrivateKey = vm.envUint("ADMIN_PRIVATE_KEY");
    uint256 plentyOfArpaBalance = vm.envUint("PLENTY_OF_ARPA_BALANCE");
    address node1Address = vm.envAddress("NODE_1");
    address node2Address = vm.envAddress("NODE_2");

    uint256 initialMaxPoolSize = vm.envUint("INITIAL_MAX_POOL_SIZE");
    uint256 initialMaxCommunityStakeAmount = vm.envUint("INITIAL_MAX_COMMUNITY_STAKE_AMOUNT");
    uint256 minCommunityStakeAmount = vm.envUint("MIN_COMMUNITY_STAKE_AMOUNT");
    uint256 operatorStakeAmount = vm.envUint("OPERATOR_STAKE_AMOUNT");
    uint256 minInitialOperatorCount = vm.envUint("MIN_INITIAL_OPERATOR_COUNT");
    uint256 minRewardDuration = vm.envUint("MIN_REWARD_DURATION");
    uint256 delegationRateDenominator = vm.envUint("DELEGATION_RATE_DENOMINATOR");
    uint256 unstakeFreezingDuration = vm.envUint("UNSTAKE_FREEZING_DURATION");

    function setUp() public {}

    function run() external {
        Staking staking;
        Arpa arpa;

        vm.broadcast(deployerPrivateKey);
        arpa = new Arpa();

        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            ArpaTokenInterface(address(arpa)),
            initialMaxPoolSize,
            initialMaxCommunityStakeAmount,
            minCommunityStakeAmount,
            operatorStakeAmount,
            minInitialOperatorCount,
            minRewardDuration,
            delegationRateDenominator,
            unstakeFreezingDuration
        );

        vm.broadcast(deployerPrivateKey);
        staking = new Staking(params);

        vm.broadcast(deployerPrivateKey);
        arpa.approve(address(staking), plentyOfArpaBalance);

        address[] memory operators = new address[](2);
        operators[0] = node1Address;
        operators[1] = node2Address;
        vm.broadcast(deployerPrivateKey);
        staking.addOperators(operators);
    }
}
