// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10;

import {ArpaTokenInterface} from "./interfaces/ArpaTokenInterface.sol";
import {TypeAndVersionInterface} from "./interfaces/TypeAndVersionInterface.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {IERC165} from "openzeppelin-contracts/contracts/interfaces/IERC165.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IStakingOwner} from "./interfaces/IStakingOwner.sol";
import {INodeStaking} from "./interfaces/INodeStaking.sol";
import {IMigratable} from "./interfaces/IMigratable.sol";
import {StakingPoolLib} from "./libraries/StakingPoolLib.sol";
import {RewardLib, SafeCast} from "./libraries/RewardLib.sol";
import {IMigrationTarget} from "./interfaces/IMigrationTarget.sol";

contract Staking is IStaking, IStakingOwner, INodeStaking, IMigratable, Ownable, TypeAndVersionInterface, Pausable {
    using StakingPoolLib for StakingPoolLib.Pool;
    using RewardLib for RewardLib.Reward;
    using SafeCast for uint256;

    /// @notice This struct defines the params required by the Staking contract's
    /// constructor.
    struct PoolConstructorParams {
        /// @notice The ARPA Token
        ArpaTokenInterface ARPAAddress;
        /// @notice The initial maximum total stake amount across all stakers
        uint256 initialMaxPoolSize;
        /// @notice The initial maximum stake amount for a single community staker
        uint256 initialMaxCommunityStakeAmount;
        /// @notice The minimum stake amount that a community staker can stake
        uint256 minCommunityStakeAmount;
        /// @notice The stake amount that an operator should stake
        uint256 operatorStakeAmount;
        /// @notice The minimum number of node operators required to initialize the
        /// staking pool.
        uint256 minInitialOperatorCount;
        /// @notice The minimum reward duration after pool config updates and pool
        /// reward extensions
        uint256 minRewardDuration;
        /// @notice Used to calculate delegated stake amount
        /// = amount / delegation rate denominator = 100% / 100 = 1%
        uint256 delegationRateDenominator;
        /// @notice The freezing duration for stakers after unstaking
        uint256 unstakeFreezingDuration;
    }

    ArpaTokenInterface private immutable i_ARPA;
    StakingPoolLib.Pool private s_pool;
    RewardLib.Reward private s_reward;
    /// @notice The address of the controller contract
    address private s_controller;
    /// @notice The proposed address stakers will migrate funds to
    address private s_proposedMigrationTarget;
    /// @notice The timestamp of when the migration target was proposed at
    uint256 private s_proposedMigrationTargetAt;
    /// @notice The address stakers can migrate their funds to
    address private s_migrationTarget;
    /// @notice The stake amount that a node operator should stake
    uint256 private immutable i_operatorStakeAmount;
    /// @notice The minimum stake amount that a community staker can stake
    uint256 private immutable i_minCommunityStakeAmount;
    /// @notice The minimum number of node operators required to initialize the
    /// staking pool.
    uint256 private immutable i_minInitialOperatorCount;
    /// @notice The minimum reward duration after pool config updates and pool
    /// reward extensions
    uint256 private immutable i_minRewardDuration;
    /// @notice Used to calculate delegated stake amount
    /// = amount / delegation rate denominator = 100% / 100 = 1%
    uint256 private immutable i_delegationRateDenominator;
    /// @notice The freeze duration for stakers after unstaking
    uint256 private immutable i_unstakeFreezingDuration;

    constructor(PoolConstructorParams memory params) {
        if (address(params.ARPAAddress) == address(0)) revert InvalidZeroAddress();
        if (params.delegationRateDenominator == 0) revert InvalidDelegationRate();
        if (RewardLib.REWARD_PRECISION % params.delegationRateDenominator > 0) {
            revert InvalidDelegationRate();
        }
        if (params.operatorStakeAmount == 0) {
            revert InvalidOperatorStakeAmount();
        }
        if (params.minCommunityStakeAmount > params.initialMaxCommunityStakeAmount) {
            revert InvalidMinCommunityStakeAmount();
        }

        s_pool._setConfig(params.initialMaxPoolSize, params.initialMaxCommunityStakeAmount);
        i_ARPA = params.ARPAAddress;
        i_operatorStakeAmount = params.operatorStakeAmount;
        i_minCommunityStakeAmount = params.minCommunityStakeAmount;
        i_minInitialOperatorCount = params.minInitialOperatorCount;
        i_minRewardDuration = params.minRewardDuration;
        i_delegationRateDenominator = params.delegationRateDenominator;
        i_unstakeFreezingDuration = params.unstakeFreezingDuration;
    }

    // =======================
    // TypeAndVersionInterface
    // =======================

    /// @inheritdoc TypeAndVersionInterface
    function typeAndVersion() external pure override returns (string memory) {
        return "Staking 0.1.0";
    }

    // =============
    // IStakingOwner
    // =============

    /// @inheritdoc IStakingOwner
    function setController(address controller) external override(IStakingOwner) onlyOwner {
        if (controller == address(0)) revert InvalidZeroAddress();
        s_controller = controller;
    }

    /// @inheritdoc IStakingOwner
    function setPoolConfig(uint256 maxPoolSize, uint256 maxCommunityStakeAmount)
        external
        override(IStakingOwner)
        onlyOwner
        whenActive
    {
        s_pool._setConfig(maxPoolSize, maxCommunityStakeAmount);
    }

    /// @inheritdoc IStakingOwner
    function start(uint256 amount, uint256 rewardDuration) external override(IStakingOwner) onlyOwner {
        s_pool._open(i_minInitialOperatorCount);

        // We need to transfer ARPA balance before we initialize the reward to
        // calculate the new reward expiry timestamp.
        i_ARPA.transferFrom(msg.sender, address(this), amount);

        s_reward._initialize(i_minRewardDuration, amount, rewardDuration);
    }

    /// @inheritdoc IStakingOwner
    function addReward(uint256 amount, uint256 rewardDuration) external override(IStakingOwner) onlyOwner whenActive {
        i_ARPA.transferFrom(msg.sender, address(this), amount);

        s_reward._updateReward(amount, rewardDuration);

        emit RewardLib.RewardAdded(amount, block.timestamp + rewardDuration);
    }

    /// @dev Required conditions for adding operators:
    /// - Operators can only be added to the pool if they have no prior stake.
    /// - Operators cannot be added to the pool after staking ends.
    /// @inheritdoc IStakingOwner
    function addOperators(address[] calldata operators) external override(IStakingOwner) onlyOwner {
        // If reward was initialized (meaning the pool was active) but the pool is
        // no longer active we want to prevent adding new operators.
        if (s_reward.startTimestamp > 0 && !isActive()) {
            revert StakingPoolLib.InvalidPoolStatus(false, true);
        }

        s_pool._addOperators(operators);
    }

    /// @inheritdoc IStakingOwner
    function emergencyPause() external override(IStakingOwner) onlyOwner {
        _pause();
    }

    /// @inheritdoc IStakingOwner
    function emergencyUnpause() external override(IStakingOwner) onlyOwner {
        _unpause();
    }

    // ===========
    // IMigratable
    // ===========

    /// @inheritdoc IMigratable
    function getMigrationTarget() external view override(IMigratable) returns (address) {
        return s_migrationTarget;
    }

    /// @inheritdoc IMigratable
    function proposeMigrationTarget(address migrationTarget) external override(IMigratable) onlyOwner {
        if (
            migrationTarget.code.length == 0 || migrationTarget == address(this)
                || s_proposedMigrationTarget == migrationTarget || s_migrationTarget == migrationTarget
                || !IERC165(migrationTarget).supportsInterface(IMigrationTarget.migrateFrom.selector)
        ) {
            revert InvalidMigrationTarget();
        }

        s_migrationTarget = address(0);
        s_proposedMigrationTarget = migrationTarget;
        s_proposedMigrationTargetAt = block.timestamp;
        emit MigrationTargetProposed(migrationTarget);
    }

    /// @inheritdoc IMigratable
    function acceptMigrationTarget() external override(IMigratable) onlyOwner {
        if (s_proposedMigrationTarget == address(0)) {
            revert InvalidMigrationTarget();
        }

        if (block.timestamp < (uint256(s_proposedMigrationTargetAt) + 7 days)) {
            revert AccessForbidden();
        }

        s_migrationTarget = s_proposedMigrationTarget;
        s_proposedMigrationTarget = address(0);
        emit MigrationTargetAccepted(s_migrationTarget);
    }

    /// @inheritdoc IMigratable
    function migrate(bytes calldata data) external override(IMigratable) whenInactive {
        if (s_migrationTarget == address(0)) revert InvalidMigrationTarget();

        (uint256 amount, uint256 baseReward, uint256 delegationReward) = _exit(msg.sender);

        i_ARPA.transfer(s_migrationTarget, uint256(amount + baseReward + delegationReward));

        // call migrate function
        IMigrationTarget(s_migrationTarget).migrateFrom(
            uint256(amount + baseReward + delegationReward), abi.encode(msg.sender, data)
        );

        emit Migrated(msg.sender, amount, baseReward, delegationReward, data);
    }

    // ========
    // INodeStaking
    // ========

    /// @inheritdoc INodeStaking
    function lock(address staker, uint256 amount) external override(INodeStaking) onlyController {
        StakingPoolLib.Staker storage stakerAccount = s_pool.stakers[staker];
        if (!stakerAccount.isOperator) {
            revert StakingPoolLib.OperatorDoesNotExist(staker);
        }
        if (stakerAccount.stakedAmount < amount) {
            revert StakingPoolLib.InsufficientStakeAmount(amount);
        }
        stakerAccount.lockedStakeAmount += amount._toUint96();
        emit Locked(staker, amount);
    }

    /// @inheritdoc INodeStaking
    function unlock(address staker, uint256 amount) external override(INodeStaking) onlyController {
        StakingPoolLib.Staker storage stakerAccount = s_pool.stakers[staker];
        if (!stakerAccount.isOperator) {
            revert StakingPoolLib.OperatorDoesNotExist(staker);
        }
        if (stakerAccount.lockedStakeAmount < amount) {
            revert INodeStaking.InadequateOperatorLockedStakingAmount(stakerAccount.lockedStakeAmount);
        }
        stakerAccount.lockedStakeAmount -= amount._toUint96();
        emit Unlocked(staker, amount);
    }

    /// @inheritdoc INodeStaking
    function slashDelegationReward(address staker, uint256 amount) external override(INodeStaking) onlyController {
        StakingPoolLib.Staker memory stakerAccount = s_pool.stakers[staker];
        if (!stakerAccount.isOperator) {
            revert StakingPoolLib.OperatorDoesNotExist(staker);
        }
        uint256 earnedRewards = s_reward._getOperatorEarnedDelegatedRewards(
            staker, getTotalDelegatedAmount(), getTotalCommunityStakedAmount()
        );
        // max capped by earnings
        uint256 slashedRewards = Math.min(amount, earnedRewards);
        s_reward.missed[staker].delegated += slashedRewards._toUint96();

        i_ARPA.transfer(owner(), slashedRewards);

        emit DelegationRewardSlashed(staker, slashedRewards);
    }

    /// @inheritdoc INodeStaking
    function getLockedAmount(address staker) external view override(INodeStaking) returns (uint256) {
        return s_pool.stakers[staker].lockedStakeAmount;
    }

    // ========
    // IStaking
    // ========

    /// @inheritdoc IStaking
    function stake(uint256 amount) external override(IStaking) whenNotPaused whenActive {
        if (amount < RewardLib.REWARD_PRECISION) {
            revert StakingPoolLib.InsufficientStakeAmount(RewardLib.REWARD_PRECISION);
        }

        // Round down input amount to avoid cumulative rounding errors.
        uint256 remainder = amount % RewardLib.REWARD_PRECISION;
        if (remainder > 0) {
            amount -= remainder;
        }

        i_ARPA.transferFrom(msg.sender, address(this), amount);

        if (s_pool._isOperator(msg.sender)) {
            _stakeAsOperator(msg.sender, amount);
        } else {
            _stakeAsCommunityStaker(msg.sender, amount);
        }
    }

    /// @inheritdoc IStaking
    function unstake(uint256 amount) external override(IStaking) whenNotPaused {
        // Round down unstake amount to avoid cumulative rounding errors.
        uint256 remainder = amount % RewardLib.REWARD_PRECISION;
        if (remainder > 0) {
            amount -= remainder;
        }

        (uint256 baseReward, uint256 delegationReward) = _exit(msg.sender, amount, false);

        i_ARPA.transfer(msg.sender, baseReward + delegationReward);

        emit Unstaked(msg.sender, amount, baseReward, delegationReward);
    }

    /// @inheritdoc IStaking
    function claim() external override(IStaking) whenNotPaused {
        claimReward();
        if (s_pool.stakers[msg.sender].frozenPrincipals.length > 0) {
            claimFrozenPrincipal();
        }
    }

    /// @inheritdoc IStaking
    function claimReward() public override(IStaking) whenNotPaused {
        StakingPoolLib.Staker memory stakerAccount = s_pool.stakers[msg.sender];
        if (stakerAccount.isOperator) {
            revert StakingPoolLib.NoBaseRewardForOperator();
        }

        uint256 accruedReward = s_reward._calculateAccruedBaseRewards(
            RewardLib._getNonDelegatedAmount(stakerAccount.stakedAmount, i_delegationRateDenominator),
            getTotalCommunityStakedAmount()
        );

        uint256 claimingReward = accruedReward - uint256(s_reward.missed[msg.sender].base);

        s_reward.missed[msg.sender].base = accruedReward._toUint96();

        i_ARPA.transfer(msg.sender, claimingReward);

        emit RewardClaimed(msg.sender, claimingReward);
    }

    /// @inheritdoc IStaking
    function claimFrozenPrincipal() public override(IStaking) whenNotPaused {
        StakingPoolLib.FrozenPrincipal[] storage frozenPrincipals = s_pool.stakers[msg.sender].frozenPrincipals;
        if (frozenPrincipals.length == 0) revert StakingPoolLib.FrozenPrincipalDoesNotExist(msg.sender);

        uint256 claimingPrincipal = 0;
        uint256 popCount = 0;
        for (uint256 i = 0; i < frozenPrincipals.length; i++) {
            StakingPoolLib.FrozenPrincipal storage frozenPrincipal = frozenPrincipals[i];
            if (frozenPrincipals[i].unlockTimestamp <= block.timestamp) {
                claimingPrincipal += frozenPrincipal.amount;
                s_pool.totalFrozenAmount -= frozenPrincipal.amount;
                popCount++;
            } else {
                break;
            }
        }
        if (popCount > 0) {
            for (uint256 i = 0; i < frozenPrincipals.length - popCount; i++) {
                frozenPrincipals[i] = frozenPrincipals[i + popCount];
            }
            for (uint256 i = 0; i < popCount; i++) {
                frozenPrincipals.pop();
            }
        }

        if (claimingPrincipal > 0) {
            i_ARPA.transfer(msg.sender, claimingPrincipal);
        }

        emit FrozenPrincipalClaimed(msg.sender, claimingPrincipal);
    }

    /// @inheritdoc IStaking
    function getStake(address staker) public view override(IStaking) returns (uint256) {
        return s_pool.stakers[staker].stakedAmount;
    }

    /// @inheritdoc IStaking
    function isOperator(address staker) external view override(IStaking) returns (bool) {
        return s_pool._isOperator(staker);
    }

    /// @inheritdoc IStaking
    function isActive() public view override(IStaking) returns (bool) {
        return s_pool.state.isOpen && !s_reward._isDepleted();
    }

    /// @inheritdoc IStaking
    function getMaxPoolSize() external view override(IStaking) returns (uint256) {
        return uint256(s_pool.limits.maxPoolSize);
    }

    /// @inheritdoc IStaking
    function getCommunityStakerLimits() external view override(IStaking) returns (uint256, uint256) {
        return (i_minCommunityStakeAmount, uint256(s_pool.limits.maxCommunityStakeAmount));
    }

    /// @inheritdoc IStaking
    function getOperatorLimit() external view override(IStaking) returns (uint256) {
        return i_operatorStakeAmount;
    }

    /// @inheritdoc IStaking
    function getRewardTimestamps() external view override(IStaking) returns (uint256, uint256) {
        return (uint256(s_reward.startTimestamp), uint256(s_reward.endTimestamp));
    }

    /// @inheritdoc IStaking
    function getRewardRate() external view override(IStaking) returns (uint256) {
        return uint256(s_reward.rate);
    }

    /// @inheritdoc IStaking
    function getDelegationRateDenominator() external view override(IStaking) returns (uint256) {
        return i_delegationRateDenominator;
    }

    /// @inheritdoc IStaking
    function getAvailableReward() public view override(IStaking) returns (uint256) {
        return i_ARPA.balanceOf(address(this)) - getTotalStakedAmount() - s_pool.totalFrozenAmount;
    }

    /// @inheritdoc IStaking
    function getBaseReward(address staker) public view override(IStaking) returns (uint256) {
        uint256 stakedAmount = s_pool.stakers[staker].stakedAmount;
        if (stakedAmount == 0) return 0;

        if (s_pool._isOperator(staker)) {
            return 0;
        }

        return s_reward._calculateAccruedBaseRewards(
            RewardLib._getNonDelegatedAmount(stakedAmount, i_delegationRateDenominator), getTotalCommunityStakedAmount()
        ) - uint256(s_reward.missed[staker].base);
    }

    /// @inheritdoc IStaking
    function getDelegationReward(address staker) public view override(IStaking) returns (uint256) {
        StakingPoolLib.Staker memory stakerAccount = s_pool.stakers[staker];
        if (!stakerAccount.isOperator) return 0;
        if (stakerAccount.stakedAmount == 0) return 0;
        return s_reward._getOperatorEarnedDelegatedRewards(
            staker, getTotalDelegatedAmount(), getTotalCommunityStakedAmount()
        );
    }

    /// @inheritdoc IStaking
    function getTotalDelegatedAmount() public view override(IStaking) returns (uint256) {
        return RewardLib._getDelegatedAmount(s_pool.state.totalCommunityStakedAmount, i_delegationRateDenominator);
    }

    /// @inheritdoc IStaking
    function getDelegatesCount() external view override(IStaking) returns (uint256) {
        return uint256(s_reward.delegated.delegatesCount);
    }

    /// @inheritdoc IStaking
    function getTotalStakedAmount() public view override(IStaking) returns (uint256) {
        return s_pool._getTotalStakedAmount();
    }

    /// @inheritdoc IStaking
    function getTotalCommunityStakedAmount() public view override(IStaking) returns (uint256) {
        return s_pool.state.totalCommunityStakedAmount;
    }

    /// @inheritdoc IStaking
    function getTotalFrozenAmount() external view override(IStaking) returns (uint256) {
        return s_pool.totalFrozenAmount;
    }

    /// @inheritdoc IStaking
    function getFrozenPrincipal(address staker)
        external
        view
        override(IStaking)
        returns (uint96[] memory amounts, uint256[] memory unlockTimestamps)
    {
        StakingPoolLib.FrozenPrincipal[] memory frozenPrincipals = s_pool.stakers[staker].frozenPrincipals;
        amounts = new uint96[](frozenPrincipals.length);
        unlockTimestamps = new uint256[](frozenPrincipals.length);
        for (uint256 i = 0; i < frozenPrincipals.length; i++) {
            amounts[i] = frozenPrincipals[i].amount;
            unlockTimestamps[i] = frozenPrincipals[i].unlockTimestamp;
        }
    }

    /// @inheritdoc IStaking
    function getClaimablePrincipalAmount(address) external view returns (uint256 claimingPrincipal) {
        StakingPoolLib.FrozenPrincipal[] storage frozenPrincipals = s_pool.stakers[msg.sender].frozenPrincipals;
        if (frozenPrincipals.length == 0) return 0;

        for (uint256 i = 0; i < frozenPrincipals.length; i++) {
            StakingPoolLib.FrozenPrincipal storage frozenPrincipal = frozenPrincipals[i];
            if (frozenPrincipals[i].unlockTimestamp <= block.timestamp) {
                claimingPrincipal += frozenPrincipal.amount;
            } else {
                break;
            }
        }
    }

    /// @inheritdoc IStaking
    function isPaused() external view override(IStaking) returns (bool) {
        return paused();
    }

    /// @inheritdoc IStaking
    function getArpaToken() public view override(IStaking) returns (address) {
        return address(i_ARPA);
    }

    /// @inheritdoc IStaking
    function getController() external view override(IStaking) returns (address) {
        return s_controller;
    }

    // =======
    // Private
    // =======

    /// @notice Helper function for when a community staker enters the pool
    /// @param staker The staker address
    /// @param amount The amount of principal staked
    function _stakeAsCommunityStaker(address staker, uint256 amount) private {
        uint256 currentStakedAmount = s_pool.stakers[staker].stakedAmount;
        uint256 newStakedAmount = currentStakedAmount + amount;
        // Check that the amount is greater than or equal to the minimum required
        if (newStakedAmount < i_minCommunityStakeAmount) {
            revert StakingPoolLib.InsufficientStakeAmount(i_minCommunityStakeAmount);
        }

        // Check that the amount is less than or equal to the maximum allowed
        uint256 maxCommunityStakeAmount = uint256(s_pool.limits.maxCommunityStakeAmount);
        if (newStakedAmount > maxCommunityStakeAmount) {
            revert StakingPoolLib.ExcessiveStakeAmount(maxCommunityStakeAmount - currentStakedAmount);
        }

        // Check if the amount supplied increases the total staked amount above
        // the maximum pool size
        uint256 remainingPoolSpace = s_pool._getRemainingPoolSpace();
        if (amount > remainingPoolSpace) {
            revert StakingPoolLib.ExcessiveStakeAmount(remainingPoolSpace);
        }

        s_reward._accumulateBaseRewards(getTotalCommunityStakedAmount());
        s_reward._accumulateDelegationRewards(getTotalDelegatedAmount(), getTotalCommunityStakedAmount());

        uint256 extraNonDelegatedAmount = RewardLib._getNonDelegatedAmount(amount, i_delegationRateDenominator);
        s_reward.missed[staker].base +=
            s_reward._calculateAccruedBaseRewards(extraNonDelegatedAmount, getTotalCommunityStakedAmount())._toUint96();
        s_pool.state.totalCommunityStakedAmount += amount._toUint96();
        s_pool.stakers[staker].stakedAmount = newStakedAmount._toUint96();
        emit Staked(staker, amount, newStakedAmount);
    }

    /// @notice Helper function for when an operator enters the pool
    /// @param staker The staker address
    /// @param amount The amount of principal staked
    function _stakeAsOperator(address staker, uint256 amount) private {
        StakingPoolLib.Staker storage operator = s_pool.stakers[staker];
        uint256 currentStakedAmount = operator.stakedAmount;
        uint256 newStakedAmount = currentStakedAmount + amount;

        // Check that the amount is greater than or less than the required
        if (newStakedAmount < i_operatorStakeAmount) {
            revert StakingPoolLib.InsufficientStakeAmount(i_operatorStakeAmount);
        }
        if (newStakedAmount > i_operatorStakeAmount) {
            revert StakingPoolLib.ExcessiveStakeAmount(newStakedAmount - i_operatorStakeAmount);
        }

        // On first stake
        if (currentStakedAmount == 0) {
            s_reward._accumulateDelegationRewards(getTotalDelegatedAmount(), getTotalCommunityStakedAmount());
            uint8 delegatesCount = s_reward.delegated.delegatesCount;

            // Prior to the first operator staking, we reset the accumulated value
            // so it doesn't count towards missed rewards.
            if (delegatesCount == 0) {
                delete s_reward.delegated.cumulativePerDelegate;
            }

            s_reward.delegated.delegatesCount = delegatesCount + 1;

            s_reward.missed[staker].delegated = s_reward.delegated.cumulativePerDelegate;
        }

        s_pool.state.totalOperatorStakedAmount += amount._toUint96();
        s_pool.stakers[staker].stakedAmount = newStakedAmount._toUint96();
        emit Staked(staker, amount, newStakedAmount);
    }

    /// @notice Helper function when staker exits the pool
    /// @param staker The staker address
    function _exit(address staker) private returns (uint256, uint256, uint256) {
        StakingPoolLib.Staker memory stakerAccount = s_pool.stakers[staker];
        if (stakerAccount.stakedAmount == 0) {
            revert StakingPoolLib.StakeNotFound(staker);
        }
        if (stakerAccount.lockedStakeAmount > 0) {
            revert StakingPoolLib.ExistingLockedStakeFound(staker);
        }
        (uint256 baseReward, uint256 delegationReward) = _exit(staker, stakerAccount.stakedAmount, true);
        return (stakerAccount.stakedAmount, baseReward, delegationReward);
    }

    /// @notice Helper function when staker exits the pool
    /// @param staker The staker address
    function _exit(address staker, uint256 amount, bool isMigrate) private returns (uint256, uint256) {
        StakingPoolLib.Staker memory stakerAccount = s_pool.stakers[staker];
        if (amount == 0) {
            revert StakingPoolLib.UnstakeWithZeroAmount(staker);
        }
        if (stakerAccount.stakedAmount < amount) {
            revert StakingPoolLib.InadequateStakingAmount(stakerAccount.stakedAmount);
        }

        s_reward._accumulateBaseRewards(getTotalCommunityStakedAmount());
        s_reward._accumulateDelegationRewards(getTotalDelegatedAmount(), getTotalCommunityStakedAmount());

        if (stakerAccount.isOperator) {
            if (amount != i_operatorStakeAmount) {
                revert StakingPoolLib.UnstakeOperatorWithPartialAmount(staker);
            }

            if (stakerAccount.lockedStakeAmount > 0) {
                revert StakingPoolLib.ExistingLockedStakeFound(staker);
            }

            uint256 delegationReward = s_reward._getOperatorEarnedDelegatedRewards(
                staker, getTotalDelegatedAmount(), getTotalCommunityStakedAmount()
            );

            s_pool.state.totalOperatorStakedAmount -= amount._toUint96();
            s_pool.stakers[staker].stakedAmount -= amount._toUint96();

            if (!isMigrate) {
                s_pool.totalFrozenAmount += amount._toUint96();
                s_pool.stakers[staker].frozenPrincipals.push(
                    StakingPoolLib.FrozenPrincipal(amount._toUint96(), block.timestamp + i_unstakeFreezingDuration)
                );
            }
            s_reward.delegated.delegatesCount -= 1;

            s_reward.missed[staker].delegated = s_reward.delegated.cumulativePerDelegate;

            return (0, delegationReward);
        } else {
            uint256 baseReward = s_reward._calculateAccruedBaseRewards(
                RewardLib._getNonDelegatedAmount(stakerAccount.stakedAmount, i_delegationRateDenominator),
                getTotalCommunityStakedAmount()
            ) - uint256(s_reward.missed[staker].base);

            s_pool.state.totalCommunityStakedAmount -= amount._toUint96();
            s_pool.stakers[staker].stakedAmount -= amount._toUint96();

            if (!isMigrate) {
                s_pool.totalFrozenAmount += amount._toUint96();
                s_pool.stakers[staker].frozenPrincipals.push(
                    StakingPoolLib.FrozenPrincipal(amount._toUint96(), block.timestamp + i_unstakeFreezingDuration)
                );
            }

            s_reward.missed[staker].base = s_reward._calculateAccruedBaseRewards(
                RewardLib._getNonDelegatedAmount(s_pool.stakers[staker].stakedAmount, i_delegationRateDenominator),
                getTotalCommunityStakedAmount()
            )._toUint96();

            return (baseReward, 0);
        }
    }

    // =========
    // Modifiers
    // =========

    /// @dev Having a private function for the modifer saves on the contract size
    function _isActive() private view {
        if (!isActive()) revert StakingPoolLib.InvalidPoolStatus(false, true);
    }

    /// @dev Reverts if the staking pool is inactive (not open for staking or
    /// expired)
    modifier whenActive() {
        _isActive();

        _;
    }

    /// @dev Reverts if the staking pool is active (open for staking)
    modifier whenInactive() {
        if (isActive()) revert StakingPoolLib.InvalidPoolStatus(true, false);

        _;
    }

    /// @dev Reverts if not sent from the LINK token
    modifier onlyController() {
        if (msg.sender != s_controller) revert SenderNotController();

        _;
    }
}
