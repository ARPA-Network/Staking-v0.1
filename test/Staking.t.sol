// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "src/Staking.sol";
import "./MockStakingMigrationTarget.sol";

contract StakingTest is Test {
    Staking staking;
    IERC20 arpa;
    address public admin = address(0xABCD);
    address public node1 = address(0x1);
    address public node2 = address(0x2);
    address public node3 = address(0x3);
    address public user1 = address(0x11);
    address public user2 = address(0x12);
    address public user3 = address(0x13);

    /// @notice The initial maximum total stake amount across all stakers
    uint256 initialMaxPoolSize = 50_000_00 * 1e18;
    /// @notice The initial maximum stake amount for a single community staker
    uint256 initialMaxCommunityStakeAmount = 3_000_00 * 1e18;
    /// @notice The minimum stake amount that a community staker can stake
    uint256 minCommunityStakeAmount = 1e12;
    /// @notice The minimum stake amount that an operator can stake
    uint256 operatorStakeAmount = 500_00 * 1e18;
    /// @notice The minimum number of node operators required to initialize the
    /// staking pool.
    uint256 minInitialOperatorCount = 1;
    /// @notice The minimum reward duration after pool config updates and pool
    /// reward extensions
    uint256 minRewardDuration = 1 days;
    /// @notice Used to calculate delegated stake amount
    /// = amount / delegation rate denominator = 100% / 100 = 1%
    uint256 delegationRateDenominator = 20;
    /// @notice The duration of the unstake freeze period
    uint256 unstakeFreezingDuration = 14 days;

    uint256 rewardAmount = 1_500_00 * 1e18;

    function setUp() public {
        // deal nodes and users
        vm.deal(node1, 1e18);
        vm.deal(node2, 1e18);
        vm.deal(node3, 1e18);
        vm.deal(user1, 1e18);
        vm.deal(user2, 1e18);
        vm.deal(user3, 1e18);

        // deal owner
        vm.deal(admin, 1e18);

        vm.prank(admin);
        arpa = new ERC20("arpa token", "ARPA");
        deal(address(arpa), admin, rewardAmount);

        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(arpa)),
            initialMaxPoolSize,
            initialMaxCommunityStakeAmount,
            minCommunityStakeAmount,
            operatorStakeAmount,
            minInitialOperatorCount,
            minRewardDuration,
            delegationRateDenominator,
            unstakeFreezingDuration
        );
        vm.prank(admin);
        staking = new Staking(params);
    }

    function testNodeOperatorsStakeCondition() public {
        deal(address(arpa), node1, operatorStakeAmount);
        vm.prank(node1);
        arpa.approve(address(staking), operatorStakeAmount);
        // The operator will be treated as a community staker since it is not configured as a node operator.
        // And a community staker cannot stake before the pool is started.
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, false, true));
        vm.prank(node1);
        staking.stake(operatorStakeAmount);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.prank(admin);
        staking.emergencyPause();

        vm.expectRevert("Pausable: paused");
        vm.prank(node1);
        staking.stake(operatorStakeAmount);

        vm.prank(admin);
        staking.emergencyUnpause();

        vm.prank(node1);
        staking.stake(operatorStakeAmount);
        assertEq(staking.getDelegatesCount(), 1);
        assertEq(staking.getStake(node1), operatorStakeAmount);
    }

    function testCommunityStakersStakeCondition() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);
        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, false, true));
        vm.prank(user1);
        staking.stake(userToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.warp(0 days);
        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        staking.start(rewardAmount, 30 days);

        vm.prank(admin);
        staking.emergencyPause();

        vm.expectRevert("Pausable: paused");
        vm.prank(user1);
        staking.stake(userToStake);

        vm.prank(admin);
        staking.emergencyUnpause();

        vm.prank(user1);
        staking.stake(userToStake);
        assertEq(staking.getCommunityStakersCount(), 1);
        assertEq(staking.getStake(user1), userToStake);
    }

    function testRewardCalculation1u1n() public {
        uint256 rewardRate = rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getBaseReward(node1), 0);
        assertEq(staking.getDelegationReward(node1), 0);

        vm.warp(0 days);
        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        // T0
        staking.start(rewardAmount, 30 days);

        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);
        assertEq(staking.getBaseReward(user1), 0);
        assertEq(staking.getDelegationReward(user1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 30 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 30 days * 5 / 100, 1e18);
    }

    function testRewardCalculation2u2n() public {
        uint256 rewardRate = rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.warp(0 days);
        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        // T0
        staking.start(rewardAmount, 30 days);

        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);
        assertEq(staking.getBaseReward(user1), 0);
        assertEq(staking.getDelegationReward(user1), 0);

        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getBaseReward(node1), 0);
        assertEq(staking.getDelegationReward(node1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        deal(address(arpa), user2, userToStake);
        vm.prank(user2);
        arpa.approve(address(staking), userToStake);
        vm.prank(user2);
        staking.stake(userToStake);

        // T20
        vm.warp(20 * 1 days);
        operators[0] = node2;
        vm.prank(admin);
        staking.addOperators(operators);

        deal(address(arpa), node2, nodeToStake);
        vm.prank(node2);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node2);
        staking.stake(nodeToStake);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(
            staking.getBaseReward(user1), (rewardRate * 10 days + rewardRate * 20 days / 2) * 95 / 100, 1e18
        );
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(
            staking.getDelegationReward(node1), (rewardRate * 20 days + rewardRate * 10 days / 2) * 5 / 100, 1e18
        );

        assertApproxEqAbs(staking.getBaseReward(user2), (rewardRate * 20 days / 2) * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user2), 0);
        assertEq(staking.getBaseReward(node2), 0);
        assertApproxEqAbs(staking.getDelegationReward(node2), (rewardRate * 10 days / 2) * 5 / 100, 1e18);
    }

    function testComprehensiveScenario() public {
        uint256 rewardRate = rewardAmount / 30 days;

        uint256 balanceBefore;
        uint256 balanceAfter;
        uint96[] memory amounts;
        uint256[] memory unlockTimestamps;

        uint256 nodeToStake = operatorStakeAmount;

        address[] memory operators = new address[](3);
        operators[0] = node1;
        operators[1] = node2;
        operators[2] = node3;
        vm.prank(admin);
        staking.addOperators(operators);

        // Before the pool starts
        // nodeA stakes 500,000
        deal(address(arpa), node1, nodeToStake);
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);

        vm.warp(0 days);
        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        staking.start(rewardAmount, 30 days);

        // T0
        // userA stakes 3,000
        // nodeA stakes 500,000
        deal(address(arpa), user1, 3_000 * 1e18);
        vm.prank(user1);
        arpa.approve(address(staking), 3_000 * 1e18);
        vm.prank(user1);
        staking.stake(3_000 * 1e18);

        assertEq(staking.getTotalCommunityStakedAmount(), 3_000 * 1e18);

        // T5
        // userB stakes 10,000
        // nodeB stakes 500,000
        // totalCommunityStakingAmonut: 13,000
        vm.warp(5 * 1 days);

        deal(address(arpa), user2, 10_000 * 1e18);
        vm.prank(user2);
        arpa.approve(address(staking), 10_000 * 1e18);
        vm.prank(user2);
        staking.stake(10_000 * 1e18);

        deal(address(arpa), node2, nodeToStake);
        vm.prank(node2);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node2);
        staking.stake(nodeToStake);

        assertEq(staking.getTotalCommunityStakedAmount(), 13_000 * 1e18);

        // T12
        // userC stakes 284,000
        // totalCommunityStakingAmonut: 297,000
        vm.warp(12 * 1 days);

        deal(address(arpa), user3, 284_000 * 1e18);
        vm.prank(user3);
        arpa.approve(address(staking), 284_000 * 1e18);
        vm.prank(user3);
        staking.stake(284_000 * 1e18);

        assertEq(staking.getTotalCommunityStakedAmount(), 297_000 * 1e18);

        // T15
        // userA unstakes 3,000
        // userB stakes 5,000
        // totalCommunityStakingAmonut: 299,000
        // Assert userA earned reward: rewardRate * ((3,000/3,000) * 5 days + (3,000/13,000) * 7 days + (3,000/297,000) * 3 days )
        // Assert unlocking amount: userA 3,000 for 14 days
        vm.warp(15 * 1 days);

        balanceBefore = arpa.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(3_000 * 1e18);
        balanceAfter = arpa.balanceOf(user1);
        emit log_named_uint("rewards of u1 unstake on T15", balanceAfter - balanceBefore);
        assertEq(staking.getStake(user1), 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            rewardRate
                * (
                    (3_000 * uint256(5 days) / 3_000) + (3_000 * uint256(7 days) / 13_000)
                        + (3_000 * uint256(3 days) / 297_000)
                ) * 95 / 100,
            1e18
        );
        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 14 days);

        deal(address(arpa), user2, 5_000 * 1e18);
        vm.prank(user2);
        arpa.approve(address(staking), 5_000 * 1e18);
        vm.prank(user2);
        staking.stake(5_000 * 1e18);

        assertEq(staking.getTotalCommunityStakedAmount(), 299_000 * 1e18);

        // T17
        // userA stakes 20,000
        // nodeA unstakes 500,000
        // totalCommunityStakingAmonut: 319000
        // Assert nodeA earned reward: rewardRate * 5% * (5 days + 12 days/2)
        // Assert unlocking amount: userA 3,000 for 12 days
        vm.warp(17 * 1 days);

        deal(address(arpa), user1, 20_000 * 1e18);
        vm.prank(user1);
        arpa.approve(address(staking), 20_000 * 1e18);
        vm.prank(user1);
        staking.stake(20_000 * 1e18);

        balanceBefore = arpa.balanceOf(node1);
        vm.prank(node1);
        staking.unstake(nodeToStake);
        balanceAfter = arpa.balanceOf(node1);
        emit log_named_uint("rewards of n1 unstake on T17", balanceAfter - balanceBefore);
        assertEq(staking.getStake(node1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (5 days + (12 days / 2)) * 5 / 100, 1e18);
        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 12 days);

        assertEq(staking.getTotalCommunityStakedAmount(), 319_000 * 1e18);

        // T20
        // userC unstakes 50,000
        // nodeC stakes 500,000
        // totalCommunityStakingAmonut: 269000
        // Assert userC earned reward: rewardRate * ((284,000/297,000) * 3 days + (284,000/299,000) * 2 days + (284,000/319000) * 3 days)
        // Assert unlocking amount: userA 3,000 for 9 days, userC 50,000 for 14 days
        vm.warp(20 * 1 days);

        balanceBefore = arpa.balanceOf(user3);
        vm.prank(user3);
        staking.unstake(50_000 * 1e18);
        balanceAfter = arpa.balanceOf(user3);
        emit log_named_uint("rewards of u3 unstake on T20", balanceAfter - balanceBefore);
        assertEq(staking.getStake(user3), 234_000 * 1e18);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            rewardRate
                * (
                    (284_000 * uint256(3 days) / 297_000) + (284_000 * uint256(2 days) / 299_000)
                        + (284_000 * uint256(3 days) / 319_000)
                ) * 95 / 100,
            1e18
        );
        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 14 days);

        deal(address(arpa), node3, nodeToStake);
        vm.prank(node3);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node3);
        staking.stake(nodeToStake);

        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 9 days);

        assertEq(staking.getTotalCommunityStakedAmount(), 269_000 * 1e18);

        // T26
        // Assert all users’ and nodes’ earned rewards:
        // userA: rewardRate * ((20,000/319000) * 3 days + (20,000/269000) * 6 days)
        // userB: rewardRate * ((10,000/13,000) * 7 days + (10,000/297,000) * 3 days + (15,000/299,000) * 2 days + (15,000/319000) * 3 days + (15,000/269000) * 6 days)
        // userC: rewardRate * (234,000/269000) * 6 days
        // nodeB: rewardRate * 5% * (12 days/2 + 3 days + 6 days/2)
        // Assert unlocking amount: userA 3,000 for 3 days, userC 50,000 for 8 days
        vm.warp(26 * 1 days);

        assertApproxEqAbs(
            staking.getBaseReward(user1),
            rewardRate * ((20_000 * uint256(3 days) / 319_000) + (20_000 * uint256(6 days) / 269_000)) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(6 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(6 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 6 days / 2) * 5 / 100, 1e18
        );

        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 8 days);

        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 3 days);

        // T29
        // userA claim claimable (unlocked staking amount + earned reward): 3,000 + rewardRate * ((20,000/319000) * 3 days + (20,000/269000) * 9 days)
        // Assert unlocking amount: userC 50,000 for 5 days
        vm.warp(29 * 1 days);

        balanceBefore = arpa.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        balanceAfter = arpa.balanceOf(user1);
        emit log_named_uint("rewards of u1 claim on T29", balanceAfter - balanceBefore);
        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 0);
        assertEq(unlockTimestamps.length, 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            (3_000 * 1e18)
                + rewardRate * ((20_000 * uint256(3 days) / 319_000) + (20_000 * uint256(9 days) / 269_000)) * 95 / 100,
            1e18
        );

        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 5 days);

        // T30
        // Assert all users' and nodes’ earned rewards
        // userA: rewardRate * ((20,000/269000) * 1 day)
        // userB: rewardRate * ((10,000/13,000) * 7 days + (10,000/297,000) * 3 days + (15,000/299,000) * 2 days + (15,000/319000) * 3 days + (15,000/269000) * 10 days)
        // userC: rewardRate * (234,000/269000) * 10 days
        // nodeB: rewardRate * 5% * (12 days/2 + 3 days + 10 days/2)
        // Assert unlocking amount: userC 50,000 for 4 day
        vm.warp(30 * 1 days);

        assertApproxEqAbs(
            staking.getBaseReward(user1), rewardRate * ((20_000 * uint256(1 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(10 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 10 days / 2) * 5 / 100, 1e18
        );

        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 4 days);

        // T36
        // Assert all users' earned rewards (same with T30)
        // userC claim claimable (unlocked staking amount + earned reward ): 50,000 + T30 userC earned reward
        vm.warp(36 * 1 days);

        assertApproxEqAbs(
            staking.getBaseReward(user1), rewardRate * ((20_000 * uint256(1 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(10 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 10 days / 2) * 5 / 100, 1e18
        );

        balanceBefore = arpa.balanceOf(user3);
        vm.prank(user3);
        staking.claim();
        balanceAfter = arpa.balanceOf(user3);
        emit log_named_uint("rewards of u3 claim on T36", balanceAfter - balanceBefore);
        (amounts, unlockTimestamps) = staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 0);
        assertEq(unlockTimestamps.length, 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            (50_000 * 1e18) + rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100,
            1e18
        );

        // T40
        // All users and nodes quit staking
        vm.warp(40 * 1 days);

        vm.prank(user1);
        staking.unstake(20_000 * 1e18);
        vm.prank(user2);
        staking.unstake(15_000 * 1e18);
        vm.prank(user3);
        staking.unstake(234_000 * 1e18);

        vm.prank(node2);
        staking.unstake(nodeToStake);
        vm.prank(node3);
        staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be 0
        vm.warp(54 * 1 days);

        vm.prank(user1);
        staking.claim();
        vm.prank(user2);
        staking.claim();
        vm.prank(user3);
        staking.claim();

        vm.prank(node1);
        staking.claimFrozenPrincipal();
        vm.prank(node2);
        staking.claimFrozenPrincipal();
        vm.prank(node3);
        staking.claimFrozenPrincipal();
        assertApproxEqAbs(arpa.balanceOf(address(staking)), 0, 1e18);
        assertEq(staking.getDelegatesCount(), 0);
        assertEq(staking.getCommunityStakersCount(), 0);
    }

    function testBothLateRewardCalculation1u1n() public {
        uint256 rewardRate = rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        // T0
        staking.start(rewardAmount, 30 days);

        // T5
        vm.warp(5 * 1 days);
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getBaseReward(node1), 0);
        assertEq(staking.getDelegationReward(node1), 0);

        // T10
        vm.warp(10 * 1 days);
        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);
        assertEq(staking.getBaseReward(user1), 0);
        assertEq(staking.getDelegationReward(user1), 0);

        // T20
        vm.warp(20 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 20 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 20 days * 5 / 100, 1e18);

        // All users and nodes quit staking
        vm.prank(user1);
        staking.unstake(userToStake);

        vm.prank(node1);
        staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be rewards of 10 day
        vm.warp(44 * 1 days);

        vm.prank(user1);
        staking.claim();

        vm.prank(node1);
        staking.claimFrozenPrincipal();
        assertApproxEqAbs(arpa.balanceOf(address(staking)), rewardRate * 10 days, 1e18);
    }

    function testNodeLateRewardCalculation1u1n() public {
        uint256 rewardRate = rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        // T0
        staking.start(rewardAmount, 30 days);

        // T10
        vm.warp(10 * 1 days);
        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);
        assertEq(staking.getBaseReward(user1), 0);
        assertEq(staking.getDelegationReward(user1), 0);

        // T15
        vm.warp(15 * 1 days);
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getBaseReward(node1), 0);
        assertEq(staking.getDelegationReward(node1), 0);

        // T20
        vm.warp(20 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 5 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(staking.getBaseReward(user1), rewardRate * 20 days * 95 / 100, 1e18);
        assertEq(staking.getDelegationReward(user1), 0);
        assertEq(staking.getBaseReward(node1), 0);
        assertApproxEqAbs(staking.getDelegationReward(node1), rewardRate * 15 days * 5 / 100, 1e18);

        // All users and nodes quit staking
        vm.prank(user1);
        staking.unstake(userToStake);

        vm.prank(node1);
        staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be rewards of 10 day
        vm.warp(44 * 1 days);

        vm.prank(user1);
        staking.claim();

        vm.prank(node1);
        staking.claimFrozenPrincipal();
        assertApproxEqAbs(arpa.balanceOf(address(staking)), rewardRate * 10 days + rewardRate * 5 days * 5 / 100, 1e18);
    }

    function testAddReward() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](2);
        operators[0] = node1;
        operators[1] = node2;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        // T0
        staking.start(rewardAmount, 30 days);

        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);

        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getRewardRate(), rewardAmount / 30 days);

        // T10
        vm.warp(10 * 1 days);
        uint256 anotherRewardAmount = 2_000_000 * 1e18;
        deal(address(arpa), admin, anotherRewardAmount);
        vm.prank(admin);
        arpa.approve(address(staking), anotherRewardAmount);
        vm.prank(admin);
        staking.addReward(anotherRewardAmount, 10 days);
        assertApproxEqAbs(
            staking.getRewardRate(), (rewardAmount / 30 days * 20 days + anotherRewardAmount) / 10 days, 1e12
        );
    }

    function testStakeAndUnstake2u2n() public {
        uint256 rewardRate = rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;

        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), node1, nodeToStake);

        uint256 balanceBefore;
        uint256 balanceAfter;

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        staking.start(rewardAmount, 30 days);

        // T0
        // user1 stakes 2 * #userToStake
        deal(address(arpa), user1, 2 * userToStake);
        vm.prank(user1);
        arpa.approve(address(staking), 2 * userToStake);
        vm.prank(user1);
        staking.stake(2 * userToStake);
        assertEq(staking.getStake(user1), 2 * userToStake);
        // node1 stakes #nodeToStake
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);
        assertEq(staking.getStake(node1), nodeToStake);

        // T10
        vm.warp(10 * 1 days);
        // user1 unstakes #userToStake
        balanceBefore = arpa.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(userToStake);
        balanceAfter = arpa.balanceOf(user1);
        assertEq(staking.getStake(user1), userToStake);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 10 days * 95 / 100, 1e18);
        emit log_named_uint("rewards of u1 on T10", balanceAfter - balanceBefore);

        // user2 stakes 2 * #userToStake
        deal(address(arpa), user2, 2 * userToStake);
        vm.prank(user2);
        arpa.approve(address(staking), 2 * userToStake);
        vm.prank(user2);
        staking.stake(2 * userToStake);
        assertEq(staking.getStake(user2), 2 * userToStake);

        // T20
        vm.warp(20 * 1 days);
        operators[0] = node2;
        vm.prank(admin);
        staking.addOperators(operators);
        // node2 stakes #nodeToStake
        deal(address(arpa), node2, nodeToStake);
        vm.prank(node2);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node2);
        staking.stake(nodeToStake);
        assertEq(staking.getStake(node2), nodeToStake);
        // node1 unstakes #nodeToStake
        balanceBefore = arpa.balanceOf(node1);
        vm.prank(node1);
        staking.unstake(nodeToStake);
        balanceAfter = arpa.balanceOf(node1);
        assertEq(staking.getStake(node1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 20 days * 5 / 100, 1e18);
        emit log_named_uint("rewards of n1 on T20", balanceAfter - balanceBefore);

        // T30
        vm.warp(30 * 1 days);
        balanceBefore = arpa.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(userToStake);
        balanceAfter = arpa.balanceOf(user1);
        assertEq(staking.getStake(user1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (20 days * 1 / (1 + 2)) * 95 / 100, 1e18);
        emit log_named_uint("rewards of u1 on T30", balanceAfter - balanceBefore);
        balanceBefore = arpa.balanceOf(user2);
        vm.prank(user2);
        staking.unstake(2 * userToStake);
        balanceAfter = arpa.balanceOf(user2);
        assertEq(staking.getStake(user2), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (20 days * 2 / (1 + 2)) * 95 / 100, 1e18);
        emit log_named_uint("rewards of u2 on T30", balanceAfter - balanceBefore);
        balanceBefore = arpa.balanceOf(node2);
        vm.prank(node2);
        staking.unstake(nodeToStake);
        balanceAfter = arpa.balanceOf(node2);
        assertEq(staking.getStake(node2), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 10 days * 5 / 100, 1e18);
        emit log_named_uint("rewards of n2 on T30", balanceAfter - balanceBefore);
    }

    function testMigration() public {
        uint256 userToStake = 1_000 * 1e18;
        uint256 nodeToStake = operatorStakeAmount;
        deal(address(arpa), user1, userToStake);
        deal(address(arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        arpa.approve(address(staking), nodeToStake);
        vm.prank(node1);
        staking.stake(nodeToStake);

        // start the pool
        vm.warp(0 days);
        vm.prank(admin);
        arpa.approve(address(staking), rewardAmount);
        vm.prank(admin);
        staking.start(rewardAmount, 30 days);

        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
        vm.prank(user1);
        staking.stake(userToStake);

        // user cannot migrate before the pool depletes
        vm.warp(10 days);
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, true, false));
        vm.prank(user1);
        bytes memory userMigrationData = abi.encode(user1, new bytes(0));
        staking.migrate(userMigrationData);

        // actually we can also propose and accept before the pool depletes
        vm.warp(30 days);
        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(arpa)),
            initialMaxPoolSize,
            initialMaxCommunityStakeAmount,
            minCommunityStakeAmount,
            operatorStakeAmount,
            minInitialOperatorCount,
            minRewardDuration,
            delegationRateDenominator,
            unstakeFreezingDuration
        );
        vm.prank(admin);
        MockStakingMigrationTarget stakingMigrationTarget = new MockStakingMigrationTarget(params);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMigratable.InvalidMigrationTarget.selector));
        staking.proposeMigrationTarget(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

        vm.prank(admin);
        staking.proposeMigrationTarget(address(stakingMigrationTarget));

        vm.expectRevert(abi.encodeWithSelector(IStaking.AccessForbidden.selector));
        vm.prank(admin);
        staking.acceptMigrationTarget();

        vm.expectRevert(abi.encodeWithSelector(IMigratable.InvalidMigrationTarget.selector));
        vm.prank(user1);
        staking.migrate(userMigrationData);

        // after 7 days the migration target can be accepted by the admin
        vm.warp(37 days);
        vm.prank(admin);
        staking.acceptMigrationTarget();

        // when the pool depletes and the migration target is accepted, the user can migrate
        vm.prank(admin);
        stakingMigrationTarget.addOperators(operators);
        deal(address(arpa), admin, rewardAmount);
        vm.prank(admin);
        arpa.approve(address(stakingMigrationTarget), rewardAmount);
        vm.prank(admin);
        stakingMigrationTarget.start(rewardAmount, 30 days);

        uint256 expectedCommunityStakerMigrationAmount = userToStake + rewardAmount * 95 / 100;
        vm.prank(user1);
        staking.migrate(userMigrationData);
        assertEq(staking.getCommunityStakersCount(), 0);
        assertEq(staking.getStake(user1), 0);
        assertEq(stakingMigrationTarget.getCommunityStakersCount(), 1);
        assertApproxEqAbs(stakingMigrationTarget.getStake(user1), expectedCommunityStakerMigrationAmount, 1e18);

        uint256 expectedNodeRewardAmount = rewardAmount * 5 / 100;
        bytes memory nodeMigrationData = abi.encode(node1, new bytes(0));
        uint256 balanceBefore = arpa.balanceOf(node1);

        vm.prank(node1);
        staking.migrate(nodeMigrationData);
        assertEq(staking.getDelegatesCount(), 0);
        assertEq(staking.getStake(node1), 0);
        assertEq(stakingMigrationTarget.getDelegatesCount(), 1);
        assertApproxEqAbs(stakingMigrationTarget.getStake(node1), operatorStakeAmount, 1e18);

        uint256 balanceAfter = arpa.balanceOf(node1);
        assertApproxEqAbs(balanceAfter - balanceBefore, expectedNodeRewardAmount, 1e18);

        assertApproxEqAbs(arpa.balanceOf(address(staking)), 0, 1e18);
        assertApproxEqAbs(
            arpa.balanceOf(address(stakingMigrationTarget)),
            rewardAmount + expectedCommunityStakerMigrationAmount + operatorStakeAmount,
            1e18
        );
    }
}
