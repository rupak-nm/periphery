// Neptune Mutual Protocol (https://neptunemutual.com)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../../util/TokenRecovery.sol";
import "./FakeLiquidityGaugePoolRewardV2.sol";
import "../../util/interfaces/IAccessControlUtil.sol";

contract FakeLiquidityGaugePoolV2 is IAccessControlUtil, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, TokenRecovery, FakeLiquidityGaugePoolRewardV2 {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(InitializationArgs calldata args, address admin, address[] calldata pausers) external initializer {
    if (admin == address(0)) {
      revert InvalidArgumentError("admin");
    }

    __AccessControl_init();
    __Pausable_init();
    __ReentrancyGuard_init();

    _setRoleAdmin(_NS_ROLES_PAUSER, DEFAULT_ADMIN_ROLE);
    _setRoleAdmin(_NS_ROLES_RECOVERY_AGENT, DEFAULT_ADMIN_ROLE);

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(_NS_ROLES_RECOVERY_AGENT, admin);

    for (uint256 i = 0; i < pausers.length; i++) {
      if (pausers[i] == address(0)) {
        revert InvalidArgumentError("pausers");
      }
      _grantRole(_NS_ROLES_PAUSER, pausers[i]);
    }

    if (args.key == 0) {
      revert InvalidArgumentError("args.key");
    }

    if (args.registry == address(0)) {
      revert InvalidArgumentError("args.registry");
    }

    if (args.rewardToken == address(0)) {
      revert InvalidArgumentError("args.rewardToken");
    }

    if (args.stakingToken == address(0)) {
      revert InvalidArgumentError("args.stakingToken");
    }

    if (args.veToken == address(0)) {
      revert InvalidArgumentError("args.veToken");
    }

    _key = args.key;
    _registry = args.registry;
    _rewardToken = args.rewardToken;
    _stakingToken = args.stakingToken;
    _veToken = args.veToken;

    _setPool(args.poolInfo);

    emit LiquidityGaugePoolInitialized(args.key, _msgSender(), args);
  }

  function setPool(PoolInfo calldata args) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (block.timestamp <= _epochEndTimestamp) {
      revert EpochUnavailableError();
    }

    _setPool(args);
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                                         Access Control
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function grantRoles(AccountWithRoles[] calldata detail) external override whenNotPaused {
    if (detail.length == 0) {
      revert InvalidArgumentError("detail");
    }

    for (uint256 i = 0; i < detail.length; i++) {
      for (uint256 j = 0; j < detail[i].roles.length; j++) {
        grantRole(detail[i].roles[j], detail[i].account);
      }
    }
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                             Danger!!! External & Public Functions
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function setNewStorageVariable(address value) external {
    _newStorageVariable = value;
  }

  function deposit(uint256 amount) external override nonReentrant whenNotPaused {
    if (amount == 0) {
      revert ZeroAmountError("amount");
    }

    if (_epoch == 0) {
      revert EpochUnavailableError();
    }

    IERC20Upgradeable(_stakingToken).safeTransferFrom(_msgSender(), address(this), amount);

    _updateReward(_msgSender(), false);

    _lockedByEveryone += amount;
    _lockedByMe[_msgSender()] += amount;
    _lastDepositHeights[_msgSender()] = block.number;

    emit LiquidityGaugeDeposited(_key, _msgSender(), _stakingToken, amount);
  }

  function _withdraw(uint256 amount, bool emergency) private {
    if (amount == 0) {
      revert ZeroAmountError("amount");
    }

    if (amount > _lockedByMe[_msgSender()]) {
      revert WithdrawalTooHighError(_lockedByMe[_msgSender()], amount);
    }

    if (block.number < _lastDepositHeights[_msgSender()] + _LOCKUP_PERIOD_IN_BLOCKS) {
      revert WithdrawalLockedError(_lastDepositHeights[_msgSender()] + _LOCKUP_PERIOD_IN_BLOCKS);
    }

    _updateReward(_msgSender(), emergency);

    _lockedByEveryone -= amount;
    _lockedByMe[_msgSender()] -= amount;
    IERC20Upgradeable(_stakingToken).safeTransfer(_msgSender(), amount);

    emit LiquidityGaugeWithdrawn(_key, _msgSender(), _stakingToken, amount);
  }

  function withdraw(uint256 amount) external override nonReentrant whenNotPaused {
    _withdraw(amount, false);
  }

  function _withdrawRewards() private {
    _updateReward(_msgSender(), false);

    uint256 rewards = _pendingRewardToDistribute[_msgSender()];

    if (rewards > 0) {
      uint256 platformFee = (rewards * _poolInfo.platformFee) / _denominator();

      _pendingRewardToDistribute[_msgSender()] = 0;
      IERC20Upgradeable(_rewardToken).safeTransfer(_msgSender(), rewards - platformFee);

      if (platformFee > 0) {
        IERC20Upgradeable(_rewardToken).safeTransfer(_poolInfo.treasury, platformFee);
      }

      emit LiquidityGaugeRewardsWithdrawn(_key, _msgSender(), _poolInfo.treasury, rewards, platformFee);
    }
  }

  function withdrawRewards() external override nonReentrant whenNotPaused {
    _withdrawRewards();
  }

  function exit() external override nonReentrant whenNotPaused {
    _withdraw(_lockedByMe[_msgSender()], false);
    _withdrawRewards();
  }

  function emergencyWithdraw() external override nonReentrant {
    _withdraw(_lockedByMe[_msgSender()], true);
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                                 Gauge Controller Registry Only
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function setEpoch(uint256 epoch, uint256 epochDuration, uint256 rewards) external override nonReentrant onlyRegistry {
    _updateReward(address(0), false);

    if (epochDuration > 0) {
      _setEpochDuration(epochDuration);
    }

    if (block.timestamp >= _epochEndTimestamp) {
      _rewardPerSecond = rewards / _poolInfo.epochDuration;
    } else {
      uint256 remaining = _epochEndTimestamp - block.timestamp;
      uint256 leftover = remaining * _rewardPerSecond;
      _rewardPerSecond = (rewards + leftover) / _poolInfo.epochDuration;
    }

    if (epoch <= _epoch) {
      revert InvalidArgumentError("epoch");
    }

    _epoch = epoch;
    _rewardAllocation = _poolInfo.epochDuration * _rewardPerSecond;

    uint256 requiredBalance = _rewardToken == _stakingToken ? _rewardAllocation + _lockedByEveryone : _rewardAllocation;
    uint256 rewardTokenBalance = IERC20Upgradeable(_rewardToken).balanceOf(address(this));

    if (requiredBalance > rewardTokenBalance) {
      revert InsufficientDepositError(requiredBalance, rewardTokenBalance);
    }

    _lastRewardTimestamp = block.timestamp;
    _epochEndTimestamp = block.timestamp + _poolInfo.epochDuration;

    emit EpochRewardSet(_key, _msgSender(), _rewardAllocation);
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                                          Recoverable
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function recoverEther(address sendTo) external onlyRole(_NS_ROLES_RECOVERY_AGENT) {
    _recoverEther(sendTo);
  }

  function recoverToken(IERC20Upgradeable malicious, address sendTo) external onlyRole(_NS_ROLES_RECOVERY_AGENT) {
    if (address(malicious) == _stakingToken || address(malicious) == _rewardToken) {
      revert InvalidArgumentError("malicious");
    }

    _recoverToken(malicious, sendTo);
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                                            Pausable
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function pause() external onlyRole(_NS_ROLES_PAUSER) {
    _pause();
  }

  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  //                                            Getters
  // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  function calculateReward(address account) external view returns (uint256) {
    return _getPendingRewards(account);
  }

  function getKey() external view override returns (bytes32) {
    return _key;
  }
}
