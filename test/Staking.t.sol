// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "src/Staking.sol";

contract StakingTest is Test {
    Staking staking;
    IERC20 arpa;
    address public admin = address(0xABCD);
    address public node1 = address(0x1);
    address public node2 = address(0x2);
    address public user1 = address(0x11);
    address public user2 = address(0x12);

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
    /// @notice The duration of the unstake freeze period
    uint256 unstakeFreezingDuration = 14 days;

    uint256 rewardAmount = 1_500_000 * 1e18;

    function setUp() public {
        // deal nodes and users
        vm.deal(node1, 1e18);
        vm.deal(node2, 1e18);
        vm.deal(user1, 1e18);
        vm.deal(user2, 1e18);

        // deal owner
        vm.deal(admin, 1e18);

        vm.prank(admin);
        arpa = new ERC20("arpa token", "ARPA");
        deal(address(arpa), admin, rewardAmount);

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
        vm.prank(admin);
        staking = new Staking(params);
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
        deal(address(arpa), user1, userToStake);

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
        // T0
        staking.start(rewardAmount, 30 days);
        // user1 stakes 2 * #userToStake
        vm.prank(user1);
        arpa.approve(address(staking), userToStake);
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
        deal(address(arpa), user2, userToStake);
        vm.prank(user2);
        arpa.approve(address(staking), userToStake);
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

    function testStakeRevertBeforePoolStart() public {
        uint256 userToStake = 1_000 * 1e18;
        deal(address(arpa), user1, userToStake);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(StakingPoolLib.InvalidPoolStatus.selector, false, true));
        staking.stake(userToStake);
    }
}
