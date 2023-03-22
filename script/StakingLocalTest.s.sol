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

    /// @notice The ARPA Token
    ArpaTokenInterface ARPAAddress;
    /// @notice The initial maximum total stake amount across all stakers
    uint256 initialMaxPoolSize = 50_000_000 * 1e18;
    /// @notice The initial maximum stake amount for a single community staker
    uint256 initialMaxCommunityStakeAmount = 2_500_000 * 1e18;
    /// @notice The minimum stake amount that a community staker can stake
    uint256 minCommunityStakeAmount = 1e12;
    /// @notice The minimum stake amount that an operator can stake
    uint256 operatorStakeAmount = 500_000 * 1e18;
    /// @notice The minimum number of node operators required to initialize the
    /// staking pool.
    uint256 minInitialOperatorCount = 1;
    /// @notice The minimum reward duration after pool config updates and pool
    /// reward extensions
    uint256 minRewardDuration = 1 days;
    /// @notice Used to calculate delegated stake amount
    /// = amount / delegation rate denominator = 100% / 100 = 1%
    uint256 delegationRateDenominator = 20;
    /// @notice The freeze duration for stakers after unstaking
    uint256 unstakeFreezingDuration = 14 days;

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
