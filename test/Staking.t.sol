// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Staking, IERC20, StakingPoolLib, IStaking, IMigratable} from "../src/Staking.sol";
import {MockStakingMigrationTarget} from "./MockStakingMigrationTarget.sol";
import {SimpleTransferBalanceStakingMigrationTarget} from "./SimpleTransferBalanceStakingMigrationTarget.sol";

// solhint-disable-next-line max-states-count
contract StakingTest is Test {
    Staking internal _staking;
    IERC20 internal _arpa;
    address public admin = address(0xABCD);
    address public node1 = address(0x1);
    address public node2 = address(0x2);
    address public node3 = address(0x3);
    address public user1 = address(0x11);
    address public user2 = address(0x12);
    address public user3 = address(0x13);

    /// @notice The initial maximum total stake amount across all stakers
    uint256 internal _initialMaxPoolSize = 50_000_00 * 1e18;
    /// @notice The initial maximum stake amount for a single community staker
    uint256 internal _initialMaxCommunityStakeAmount = 3_000_00 * 1e18;
    /// @notice The minimum stake amount that a community staker can stake
    uint256 internal _minCommunityStakeAmount = 1e12;
    /// @notice The minimum stake amount that an operator can stake
    uint256 internal _operatorStakeAmount = 500_00 * 1e18;
    /// @notice The minimum number of node operators required to initialize the
    /// staking pool.
    uint256 internal _minInitialOperatorCount = 1;
    /// @notice The minimum reward duration after pool config updates and pool
    /// reward extensions
    uint256 internal _minRewardDuration = 1 days;
    /// @notice Used to calculate delegated stake amount
    /// = amount / delegation rate denominator = 100% / 100 = 1%
    uint256 internal _delegationRateDenominator = 20;
    /// @notice The duration of the unstake freeze period
    uint256 internal _unstakeFreezingDuration = 14 days;

    uint256 internal _rewardAmount = 1_500_00 * 1e18;

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
        _arpa = new ERC20("arpa token", "ARPA");
        deal(address(_arpa), admin, _rewardAmount);

        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(_arpa)),
            _initialMaxPoolSize,
            _initialMaxCommunityStakeAmount,
            _minCommunityStakeAmount,
            _operatorStakeAmount,
            _minInitialOperatorCount,
            _minRewardDuration,
            _delegationRateDenominator,
            _unstakeFreezingDuration
        );
        vm.prank(admin);
        _staking = new Staking(params);
    }

    function testNodeOperatorsStakeCondition() public {
        deal(address(_arpa), node1, _operatorStakeAmount);
        vm.prank(node1);
        _arpa.approve(address(_staking), _operatorStakeAmount);
        // The operator will be treated as a community staker since it is not configured as a node operator.
        // And a community staker cannot stake before the pool is started.
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, false, true));
        vm.prank(node1);
        _staking.stake(_operatorStakeAmount);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.prank(admin);
        _staking.emergencyPause();

        vm.expectRevert("Pausable: paused");
        vm.prank(node1);
        _staking.stake(_operatorStakeAmount);

        vm.prank(admin);
        _staking.emergencyUnpause();

        vm.prank(node1);
        _staking.stake(_operatorStakeAmount);
        assertEq(_staking.getDelegatesCount(), 1);
        assertEq(_staking.getStake(node1), _operatorStakeAmount);
    }

    function testCommunityStakersStakeCondition() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);
        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, false, true));
        vm.prank(user1);
        _staking.stake(userToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.start(_rewardAmount, 30 days);

        vm.prank(admin);
        _staking.emergencyPause();

        vm.expectRevert("Pausable: paused");
        vm.prank(user1);
        _staking.stake(userToStake);

        vm.prank(admin);
        _staking.emergencyUnpause();

        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getCommunityStakersCount(), 1);
        assertEq(_staking.getStake(user1), userToStake);
    }

    function testRewardCalculation1u1n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 30 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 30 days * 5 / 100, 1e18);
    }

    function testRewardCalculation2u2n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        deal(address(_arpa), user2, userToStake);
        vm.prank(user2);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user2);
        _staking.stake(userToStake);

        // T20
        vm.warp(20 * 1 days);
        operators[0] = node2;
        vm.prank(admin);
        _staking.addOperators(operators);

        deal(address(_arpa), node2, nodeToStake);
        vm.prank(node2);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node2);
        _staking.stake(nodeToStake);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(
            _staking.getBaseReward(user1), (rewardRate * 10 days + rewardRate * 20 days / 2) * 95 / 100, 1e18
        );
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(
            _staking.getDelegationReward(node1), (rewardRate * 20 days + rewardRate * 10 days / 2) * 5 / 100, 1e18
        );

        assertApproxEqAbs(_staking.getBaseReward(user2), (rewardRate * 20 days / 2) * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user2), 0);
        assertEq(_staking.getBaseReward(node2), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node2), (rewardRate * 10 days / 2) * 5 / 100, 1e18);
    }

    function testComprehensiveScenario() public {
        uint256 rewardRate = _rewardAmount / 30 days;

        uint256 balanceBefore;
        uint256 balanceAfter;
        uint96[] memory amounts;
        uint256[] memory unlockTimestamps;

        uint256 nodeToStake = _operatorStakeAmount;

        address[] memory operators = new address[](3);
        operators[0] = node1;
        operators[1] = node2;
        operators[2] = node3;
        vm.prank(admin);
        _staking.addOperators(operators);

        // Before the pool starts
        // nodeA stakes 500,000
        deal(address(_arpa), node1, nodeToStake);
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.start(_rewardAmount, 30 days);

        // T0
        // userA stakes 3,000
        // nodeA stakes 500,000
        deal(address(_arpa), user1, 3_000 * 1e18);
        vm.prank(user1);
        _arpa.approve(address(_staking), 3_000 * 1e18);
        vm.prank(user1);
        _staking.stake(3_000 * 1e18);

        assertEq(_staking.getTotalCommunityStakedAmount(), 3_000 * 1e18);

        // T5
        // userB stakes 10,000
        // nodeB stakes 500,000
        // totalCommunityStakingAmonut: 13,000
        vm.warp(5 * 1 days);

        deal(address(_arpa), user2, 10_000 * 1e18);
        vm.prank(user2);
        _arpa.approve(address(_staking), 10_000 * 1e18);
        vm.prank(user2);
        _staking.stake(10_000 * 1e18);

        deal(address(_arpa), node2, nodeToStake);
        vm.prank(node2);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node2);
        _staking.stake(nodeToStake);

        assertEq(_staking.getTotalCommunityStakedAmount(), 13_000 * 1e18);

        // T12
        // userC stakes 284,000
        // totalCommunityStakingAmonut: 297,000
        vm.warp(12 * 1 days);

        deal(address(_arpa), user3, 284_000 * 1e18);
        vm.prank(user3);
        _arpa.approve(address(_staking), 284_000 * 1e18);
        vm.prank(user3);
        _staking.stake(284_000 * 1e18);

        assertEq(_staking.getTotalCommunityStakedAmount(), 297_000 * 1e18);

        // T15
        // userA unstakes 3,000
        // userB stakes 5,000
        // totalCommunityStakingAmonut: 299,000
        // Assert userA earned reward: rewardRate * ((3,000/3,000) * 5 days + (3,000/13,000) * 7 days + (3,000/297,000) * 3 days )
        // Assert unlocking amount: userA 3,000 for 14 days
        vm.warp(15 * 1 days);

        balanceBefore = _arpa.balanceOf(user1);
        vm.prank(user1);
        _staking.unstake(3_000 * 1e18);
        balanceAfter = _arpa.balanceOf(user1);
        emit log_named_uint("rewards of u1 unstake on T15", balanceAfter - balanceBefore);
        assertEq(_staking.getStake(user1), 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            rewardRate
                * (
                    (3_000 * uint256(5 days) / 3_000) + (3_000 * uint256(7 days) / 13_000)
                        + (3_000 * uint256(3 days) / 297_000)
                ) * 95 / 100,
            1e18
        );
        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 14 days);

        deal(address(_arpa), user2, 5_000 * 1e18);
        vm.prank(user2);
        _arpa.approve(address(_staking), 5_000 * 1e18);
        vm.prank(user2);
        _staking.stake(5_000 * 1e18);

        assertEq(_staking.getTotalCommunityStakedAmount(), 299_000 * 1e18);

        // T17
        // userA stakes 20,000
        // nodeA unstakes 500,000
        // totalCommunityStakingAmonut: 319000
        // Assert nodeA earned reward: rewardRate * 5% * (5 days + 12 days/2)
        // Assert unlocking amount: userA 3,000 for 12 days
        vm.warp(17 * 1 days);

        deal(address(_arpa), user1, 20_000 * 1e18);
        vm.prank(user1);
        _arpa.approve(address(_staking), 20_000 * 1e18);
        vm.prank(user1);
        _staking.stake(20_000 * 1e18);

        balanceBefore = _arpa.balanceOf(node1);
        vm.prank(node1);
        _staking.unstake(nodeToStake);
        balanceAfter = _arpa.balanceOf(node1);
        emit log_named_uint("rewards of n1 unstake on T17", balanceAfter - balanceBefore);
        assertEq(_staking.getStake(node1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (5 days + (12 days / 2)) * 5 / 100, 1e18);
        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 12 days);

        assertEq(_staking.getTotalCommunityStakedAmount(), 319_000 * 1e18);

        // T20
        // userC unstakes 50,000
        // nodeC stakes 500,000
        // totalCommunityStakingAmonut: 269000
        // Assert userC earned reward: rewardRate * ((284,000/297,000) * 3 days + (284,000/299,000) * 2 days + (284,000/319000) * 3 days)
        // Assert unlocking amount: userA 3,000 for 9 days, userC 50,000 for 14 days
        vm.warp(20 * 1 days);

        balanceBefore = _arpa.balanceOf(user3);
        vm.prank(user3);
        _staking.unstake(50_000 * 1e18);
        balanceAfter = _arpa.balanceOf(user3);
        emit log_named_uint("rewards of u3 unstake on T20", balanceAfter - balanceBefore);
        assertEq(_staking.getStake(user3), 234_000 * 1e18);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            rewardRate
                * (
                    (284_000 * uint256(3 days) / 297_000) + (284_000 * uint256(2 days) / 299_000)
                        + (284_000 * uint256(3 days) / 319_000)
                ) * 95 / 100,
            1e18
        );
        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 14 days);

        deal(address(_arpa), node3, nodeToStake);
        vm.prank(node3);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node3);
        _staking.stake(nodeToStake);

        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 9 days);

        assertEq(_staking.getTotalCommunityStakedAmount(), 269_000 * 1e18);

        // T26
        // Assert all users’ and nodes’ earned rewards:
        // userA: rewardRate * ((20,000/319000) * 3 days + (20,000/269000) * 6 days)
        // userB: rewardRate * ((10,000/13,000) * 7 days + (10,000/297,000) * 3 days + (15,000/299,000) * 2 days + (15,000/319000) * 3 days + (15,000/269000) * 6 days)
        // userC: rewardRate * (234,000/269000) * 6 days
        // nodeB: rewardRate * 5% * (12 days/2 + 3 days + 6 days/2)
        // Assert unlocking amount: userA 3,000 for 3 days, userC 50,000 for 8 days
        vm.warp(26 * 1 days);

        assertApproxEqAbs(
            _staking.getBaseReward(user1),
            rewardRate * ((20_000 * uint256(3 days) / 319_000) + (20_000 * uint256(6 days) / 269_000)) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(6 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(6 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            _staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 6 days / 2) * 5 / 100, 1e18
        );

        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 8 days);

        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 3_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 3 days);

        // T29
        // userA claim claimable (unlocked _staking amount + earned reward): 3,000 + rewardRate * ((20,000/319000) * 3 days + (20,000/269000) * 9 days)
        // Assert unlocking amount: userC 50,000 for 5 days
        vm.warp(29 * 1 days);

        balanceBefore = _arpa.balanceOf(user1);
        vm.prank(user1);
        _staking.claim();
        balanceAfter = _arpa.balanceOf(user1);
        emit log_named_uint("rewards of u1 claim on T29", balanceAfter - balanceBefore);
        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user1);
        assertEq(amounts.length, 0);
        assertEq(unlockTimestamps.length, 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            (3_000 * 1e18)
                + rewardRate * ((20_000 * uint256(3 days) / 319_000) + (20_000 * uint256(9 days) / 269_000)) * 95 / 100,
            1e18
        );

        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user3);
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
            _staking.getBaseReward(user1), rewardRate * ((20_000 * uint256(1 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(10 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            _staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 10 days / 2) * 5 / 100, 1e18
        );

        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50_000 * 1e18);
        assertEq(unlockTimestamps[0], block.timestamp + 4 days);

        // T36
        // Assert all users' earned rewards (same with T30)
        // userC claim claimable (unlocked _staking amount + earned reward ): 50,000 + T30 userC earned reward
        vm.warp(36 * 1 days);

        assertApproxEqAbs(
            _staking.getBaseReward(user1), rewardRate * ((20_000 * uint256(1 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user2),
            rewardRate
                * (
                    (10_000 * uint256(7 days) / 13_000) + (10_000 * uint256(3 days) / 297_000)
                        + (15_000 * uint256(2 days) / 299_000) + (15_000 * uint256(3 days) / 319_000)
                        + (15_000 * uint256(10 days) / 269_000)
                ) * 95 / 100,
            1e18
        );

        assertApproxEqAbs(
            _staking.getBaseReward(user3), rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100, 1e18
        );

        assertApproxEqAbs(
            _staking.getDelegationReward(node2), rewardRate * (12 days / 2 + 3 days + 10 days / 2) * 5 / 100, 1e18
        );

        balanceBefore = _arpa.balanceOf(user3);
        vm.prank(user3);
        _staking.claim();
        balanceAfter = _arpa.balanceOf(user3);
        emit log_named_uint("rewards of u3 claim on T36", balanceAfter - balanceBefore);
        (amounts, unlockTimestamps) = _staking.getFrozenPrincipal(user3);
        assertEq(amounts.length, 0);
        assertEq(unlockTimestamps.length, 0);
        assertApproxEqAbs(
            balanceAfter - balanceBefore,
            (50_000 * 1e18) + rewardRate * ((234_000 * uint256(10 days) / 269_000)) * 95 / 100,
            1e18
        );

        // T40
        // All users and nodes quit _staking
        vm.warp(40 * 1 days);

        vm.prank(user1);
        _staking.unstake(20_000 * 1e18);
        vm.prank(user2);
        _staking.unstake(15_000 * 1e18);
        vm.prank(user3);
        _staking.unstake(234_000 * 1e18);

        vm.prank(node2);
        _staking.unstake(nodeToStake);
        vm.prank(node3);
        _staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be 0
        vm.warp(54 * 1 days);

        vm.prank(user1);
        _staking.claim();
        vm.prank(user2);
        _staking.claim();
        vm.prank(user3);
        _staking.claim();

        vm.prank(node1);
        _staking.claimFrozenPrincipal();
        vm.prank(node2);
        _staking.claimFrozenPrincipal();
        vm.prank(node3);
        _staking.claimFrozenPrincipal();
        assertApproxEqAbs(_arpa.balanceOf(address(_staking)), 0, 1e18);
        assertEq(_staking.getDelegatesCount(), 0);
        assertEq(_staking.getCommunityStakersCount(), 0);
    }

    function testBothLateRewardCalculation1u1n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        // T5
        vm.warp(5 * 1 days);
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        // T10
        vm.warp(10 * 1 days);
        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        // T20
        vm.warp(20 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 20 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 20 days * 5 / 100, 1e18);

        // All users and nodes quit _staking
        vm.prank(user1);
        _staking.unstake(userToStake);

        vm.prank(node1);
        _staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be rewards of 10 day
        vm.warp(44 * 1 days);

        vm.prank(user1);
        _staking.claim();

        vm.prank(node1);
        _staking.claimFrozenPrincipal();
        assertApproxEqAbs(_arpa.balanceOf(address(_staking)), rewardRate * 10 days, 1e18);
    }

    function testNodeLateRewardCalculation1u1n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        // T10
        vm.warp(10 * 1 days);
        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        // T15
        vm.warp(15 * 1 days);
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        // T20
        vm.warp(20 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 5 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 20 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 15 days * 5 / 100, 1e18);

        // All users and nodes quit _staking
        vm.prank(user1);
        _staking.unstake(userToStake);

        vm.prank(node1);
        _staking.unstake(nodeToStake);

        // T54
        // All users and nodes claim their rewards and frozen principal, the balance of pool should be rewards of 10 day
        vm.warp(44 * 1 days);

        vm.prank(user1);
        _staking.claim();

        vm.prank(node1);
        _staking.claimFrozenPrincipal();
        assertApproxEqAbs(
            _arpa.balanceOf(address(_staking)), rewardRate * 10 days + rewardRate * 5 days * 5 / 100, 1e18
        );
    }

    function testAddReward() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](2);
        operators[0] = node1;
        operators[1] = node2;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);

        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getRewardRate(), _rewardAmount / 30 days);

        // T10
        vm.warp(10 * 1 days);
        uint256 anotherRewardAmount = 2_000_000 * 1e18;
        deal(address(_arpa), admin, anotherRewardAmount);
        vm.prank(admin);
        _arpa.approve(address(_staking), anotherRewardAmount);
        vm.prank(admin);
        _staking.addReward(anotherRewardAmount, 10 days);
        assertApproxEqAbs(
            _staking.getRewardRate(), (_rewardAmount / 30 days * 20 days + anotherRewardAmount) / 10 days, 1e12
        );
    }

    function testStakeAndUnstake2u2n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        uint256 balanceBefore;
        uint256 balanceAfter;

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.start(_rewardAmount, 30 days);

        // T0
        // user1 stakes 2 * #userToStake
        deal(address(_arpa), user1, 2 * userToStake);
        vm.prank(user1);
        _arpa.approve(address(_staking), 2 * userToStake);
        vm.prank(user1);
        _staking.stake(2 * userToStake);
        assertEq(_staking.getStake(user1), 2 * userToStake);
        // node1 stakes #nodeToStake
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getStake(node1), nodeToStake);

        // T10
        vm.warp(10 * 1 days);
        // user1 unstakes #userToStake
        balanceBefore = _arpa.balanceOf(user1);
        vm.prank(user1);
        _staking.unstake(userToStake);
        balanceAfter = _arpa.balanceOf(user1);
        assertEq(_staking.getStake(user1), userToStake);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 10 days * 95 / 100, 1e18);
        emit log_named_uint("rewards of u1 on T10", balanceAfter - balanceBefore);

        // user2 stakes 2 * #userToStake
        deal(address(_arpa), user2, 2 * userToStake);
        vm.prank(user2);
        _arpa.approve(address(_staking), 2 * userToStake);
        vm.prank(user2);
        _staking.stake(2 * userToStake);
        assertEq(_staking.getStake(user2), 2 * userToStake);

        // T20
        vm.warp(20 * 1 days);
        operators[0] = node2;
        vm.prank(admin);
        _staking.addOperators(operators);
        // node2 stakes #nodeToStake
        deal(address(_arpa), node2, nodeToStake);
        vm.prank(node2);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node2);
        _staking.stake(nodeToStake);
        assertEq(_staking.getStake(node2), nodeToStake);
        // node1 unstakes #nodeToStake
        balanceBefore = _arpa.balanceOf(node1);
        vm.prank(node1);
        _staking.unstake(nodeToStake);
        balanceAfter = _arpa.balanceOf(node1);
        assertEq(_staking.getStake(node1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 20 days * 5 / 100, 1e18);
        emit log_named_uint("rewards of n1 on T20", balanceAfter - balanceBefore);

        // T30
        vm.warp(30 * 1 days);
        balanceBefore = _arpa.balanceOf(user1);
        vm.prank(user1);
        _staking.unstake(userToStake);
        balanceAfter = _arpa.balanceOf(user1);
        assertEq(_staking.getStake(user1), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (20 days * 1 / (1 + 2)) * 95 / 100, 1e18);
        emit log_named_uint("rewards of u1 on T30", balanceAfter - balanceBefore);
        balanceBefore = _arpa.balanceOf(user2);
        vm.prank(user2);
        _staking.unstake(2 * userToStake);
        balanceAfter = _arpa.balanceOf(user2);
        assertEq(_staking.getStake(user2), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * (20 days * 2 / (1 + 2)) * 95 / 100, 1e18);
        emit log_named_uint("rewards of u2 on T30", balanceAfter - balanceBefore);
        balanceBefore = _arpa.balanceOf(node2);
        vm.prank(node2);
        _staking.unstake(nodeToStake);
        balanceAfter = _arpa.balanceOf(node2);
        assertEq(_staking.getStake(node2), 0);
        assertApproxEqAbs(balanceAfter - balanceBefore, rewardRate * 10 days * 5 / 100, 1e18);
        emit log_named_uint("rewards of n2 on T30", balanceAfter - balanceBefore);
    }

    function testMigration() public {
        uint256 userToStake = 1_000 * 1e18;
        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), user1, userToStake);
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);

        // start the pool
        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);

        // user cannot migrate before the pool depletes
        vm.warp(10 days);
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, true, false));
        vm.prank(user1);
        bytes memory userMigrationData = abi.encode(user1, new bytes(0));
        _staking.migrate(userMigrationData);

        // actually we can also propose and accept before the pool depletes
        vm.warp(30 days);
        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(_arpa)),
            _initialMaxPoolSize,
            _initialMaxCommunityStakeAmount,
            _minCommunityStakeAmount,
            _operatorStakeAmount,
            _minInitialOperatorCount,
            _minRewardDuration,
            _delegationRateDenominator,
            _unstakeFreezingDuration
        );
        vm.prank(admin);
        MockStakingMigrationTarget stakingMigrationTarget = new MockStakingMigrationTarget(params);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IMigratable.InvalidMigrationTarget.selector));
        _staking.proposeMigrationTarget(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

        vm.prank(admin);
        _staking.proposeMigrationTarget(address(stakingMigrationTarget));

        vm.expectRevert(abi.encodeWithSelector(IStaking.AccessForbidden.selector));
        vm.prank(admin);
        _staking.acceptMigrationTarget();

        vm.expectRevert(abi.encodeWithSelector(IMigratable.InvalidMigrationTarget.selector));
        vm.prank(user1);
        _staking.migrate(userMigrationData);

        // after 7 days the migration target can be accepted by the admin
        vm.warp(37 days);
        vm.prank(admin);
        _staking.acceptMigrationTarget();

        // when the pool depletes and the migration target is accepted, the user can migrate
        vm.prank(admin);
        stakingMigrationTarget.addOperators(operators);
        deal(address(_arpa), admin, _rewardAmount);
        vm.prank(admin);
        _arpa.approve(address(stakingMigrationTarget), _rewardAmount);
        vm.prank(admin);
        stakingMigrationTarget.start(_rewardAmount, 30 days);

        uint256 expectedCommunityStakerMigrationAmount = userToStake + _rewardAmount * 95 / 100;
        vm.prank(user1);
        _staking.migrate(userMigrationData);
        assertEq(_staking.getCommunityStakersCount(), 0);
        assertEq(_staking.getStake(user1), 0);
        assertEq(stakingMigrationTarget.getCommunityStakersCount(), 1);
        assertApproxEqAbs(stakingMigrationTarget.getStake(user1), expectedCommunityStakerMigrationAmount, 1e18);

        uint256 expectedNodeRewardAmount = _rewardAmount * 5 / 100;
        bytes memory nodeMigrationData = abi.encode(node1, new bytes(0));
        uint256 balanceBefore = _arpa.balanceOf(node1);

        vm.prank(node1);
        _staking.migrate(nodeMigrationData);
        assertEq(_staking.getDelegatesCount(), 0);
        assertEq(_staking.getStake(node1), 0);
        assertEq(stakingMigrationTarget.getDelegatesCount(), 1);
        assertApproxEqAbs(stakingMigrationTarget.getStake(node1), _operatorStakeAmount, 1e18);

        uint256 balanceAfter = _arpa.balanceOf(node1);
        assertApproxEqAbs(balanceAfter - balanceBefore, expectedNodeRewardAmount, 1e18);

        assertApproxEqAbs(_arpa.balanceOf(address(_staking)), 0, 1e18);
        assertApproxEqAbs(
            _arpa.balanceOf(address(stakingMigrationTarget)),
            _rewardAmount + expectedCommunityStakerMigrationAmount + _operatorStakeAmount,
            1e18
        );
    }

    function testAddRewardCalculation1u1n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // add reward
        deal(address(_arpa), admin, _rewardAmount);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.addReward(_rewardAmount, 20 days);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 2 * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 2 * 5 / 100, 1e18);

        // >T30
        vm.warp(35 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 2 * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 2 * 5 / 100, 1e18);
    }

    function testNewRewardCalculation1u1n() public {
        uint256 rewardRate = _rewardAmount / 30 days;
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        // T10
        vm.warp(10 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), rewardRate * 10 days * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), rewardRate * 10 days * 5 / 100, 1e18);

        // T30
        vm.warp(30 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 5 / 100, 1e18);

        // >T30
        vm.warp(35 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 5 / 100, 1e18);

        // start a new round of reward
        deal(address(_arpa), admin, _rewardAmount);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        _staking.newReward(_rewardAmount, 20 days);

        vm.warp(55 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 2 * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 2 * 5 / 100, 1e18);

        // >T55
        vm.warp(60 * 1 days);
        assertApproxEqAbs(_staking.getBaseReward(user1), _rewardAmount * 2 * 95 / 100, 1e18);
        assertEq(_staking.getDelegationReward(user1), 0);
        assertEq(_staking.getBaseReward(node1), 0);
        assertApproxEqAbs(_staking.getDelegationReward(node1), _rewardAmount * 2 * 5 / 100, 1e18);
    }

    function testUnstakeAndClaimUnlockedStaking() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(_arpa), user1, userToStake);

        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getBaseReward(node1), 0);
        assertEq(_staking.getDelegationReward(node1), 0);

        vm.warp(0 days);
        vm.prank(admin);
        _arpa.approve(address(_staking), _rewardAmount);
        vm.prank(admin);
        // T0
        _staking.start(_rewardAmount, 30 days);

        vm.prank(user1);
        _arpa.approve(address(_staking), userToStake);
        vm.prank(user1);
        _staking.stake(userToStake);
        assertEq(_staking.getBaseReward(user1), 0);
        assertEq(_staking.getDelegationReward(user1), 0);

        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 claimable;

        balanceBefore = _arpa.balanceOf(user1);
        assertEq(balanceBefore, 0);
        vm.prank(user1);
        _staking.unstake(userToStake);
        claimable = _staking.getClaimablePrincipalAmount(user1);
        assertEq(claimable, 0);
        // T10
        vm.warp(10 days);
        claimable = _staking.getClaimablePrincipalAmount(user1);
        assertEq(claimable, 0);
        vm.prank(user1);
        _staking.claim();
        balanceAfter = _arpa.balanceOf(user1);
        assertEq(balanceAfter, 0);
        // T14
        vm.warp(14 days);
        claimable = _staking.getClaimablePrincipalAmount(user1);
        assertEq(claimable, userToStake);
        vm.prank(user1);
        _staking.claim();
        balanceAfter = _arpa.balanceOf(user1);
        assertEq(balanceAfter, userToStake);
    }

    function testMigrationBeforeStart() public {
        uint256 nodeToStake = _operatorStakeAmount;
        deal(address(_arpa), node1, nodeToStake);

        address[] memory operators = new address[](1);
        operators[0] = node1;
        vm.prank(admin);
        _staking.addOperators(operators);

        // before the pool starts
        vm.prank(node1);
        _arpa.approve(address(_staking), nodeToStake);
        vm.prank(node1);
        _staking.stake(nodeToStake);
        assertEq(_staking.getDelegatesCount(), 1);
        assertEq(_staking.getStake(node1), nodeToStake);

        // actually we can also propose and accept before the pool depletes
        vm.warp(0 days);
        Staking.PoolConstructorParams memory params = Staking.PoolConstructorParams(
            IERC20(address(_arpa)),
            _initialMaxPoolSize,
            _initialMaxCommunityStakeAmount,
            _minCommunityStakeAmount,
            _operatorStakeAmount,
            _minInitialOperatorCount,
            _minRewardDuration,
            _delegationRateDenominator,
            _unstakeFreezingDuration
        );
        vm.prank(admin);
        SimpleTransferBalanceStakingMigrationTarget stakingMigrationTarget =
            new SimpleTransferBalanceStakingMigrationTarget(params);

        vm.prank(admin);
        _staking.proposeMigrationTarget(address(stakingMigrationTarget));

        vm.expectRevert(abi.encodeWithSelector(IStaking.AccessForbidden.selector));
        vm.prank(admin);
        _staking.acceptMigrationTarget();

        // after 7 days the migration target can be accepted by the admin
        vm.warp(7 days);
        vm.prank(admin);
        _staking.acceptMigrationTarget();

        bytes memory nodeMigrationData = abi.encode(node1, new bytes(0));
        uint256 balanceBefore = _arpa.balanceOf(node1);

        vm.prank(node1);
        _staking.migrate(nodeMigrationData);
        assertEq(_staking.getDelegatesCount(), 0);
        assertEq(_staking.getStake(node1), 0);
        assertEq(stakingMigrationTarget.getDelegatesCount(), 0);
        assertEq(stakingMigrationTarget.getStake(node1), 0);

        uint256 balanceAfter = _arpa.balanceOf(node1);
        assertApproxEqAbs(balanceAfter - balanceBefore, nodeToStake, 1e18);

        assertEq(_arpa.balanceOf(address(_staking)), 0);
        assertEq(_arpa.balanceOf(address(stakingMigrationTarget)), 0);
    }
}
