// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";

import "./Five.sol";

/**
 * @title MasterFarmer
 * @dev This contract manages the minting and distribution of the FIVE token, handles staking,
 *      and distributes rewards based on liquidity pool participation. It also supports staking
 *      with lock periods and implements reward decay mechanisms.
 */
contract MasterFarmer is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @dev Struct representing information about each pool.
     * @param lpToken The address of the liquidity pool (LP) token contract.
     * @param allocPoint Allocation points assigned to the pool for reward distribution.
     * @param lastRewardBlockTime Timestamp of the last reward distribution.
     * @param accFivePerShare Accumulated FIVE tokens per share, scaled by 1e18 for precision.
     */
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlockTime;
        uint256 accFivePerShare;
    }

    /**
     * @dev Struct representing information about each user in a pool.
     * @param amount The amount of LP tokens provided by the user.
     * @param rewardDebt The user's pending reward debt for accurate reward tracking.
     */
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    /**
     * @dev Struct representing staking lock information for PID[0].
     * @param lockAmount The amount of FIVE tokens locked.
     * @param unlockTime The timestamp when the locked tokens can be withdrawn.
     */
    struct LockInfo {
        uint256 lockAmount;
        uint256 unlockTime;
    }

    PoolInfo[] public poolInfo; // Array of pool information.
    mapping(IERC20 => bool) private poolExistence; // Tracks whether an LP token is already added.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // User information for each pool.
    mapping(address => LockInfo) public lockInfo; // Lock information for staked tokens in PID[0].

    // Constants for system limits and constraints.
    uint256 public constant MAX_EMISSION = 5 * 1e18; // Maximum emission rate (5 FIVE tokens per second).
    uint256 public constant MAX_STAKING_PERCENTAGE = 30; // Maximum staking allocation percentage (30%).
    uint256 public constant MAX_LOCK_TIME = 6 * 30 days; // Maximum lock duration: 6 months.
    uint256 public constant MIN_LOCK_TIME = 14 days; // Minimum lock duration: 2 weeks.

    FIVE public five; // Instance of the FIVE token contract.
    uint256 public emission = 5 * 1e18; // Current emission rate for rewards.
    uint256 public stakingPercentage = 30; // Staking pool allocation percentage.
    uint256 public totalAllocPoint = 0; // Total allocation points for all pools.
    uint256 public startBlockTime; // Timestamp for the start of rewards.
    uint256 public totalLockedAmount; // Total amount of locked FIVE tokens.
    uint256 public totalLockedUsers; // Total number of users with locked tokens.
    uint256 public k; // Parameter controlling the steepness of the veFIVE decay curve.

    // Event declarations for important actions within the contract.
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetTreasury(address indexed user, address indexed newTreasury);
    event SetDev(address indexed user, address indexed newDev);
    event Add(address indexed user, IERC20 indexed pair, uint256 indexed point);
    event Set(address indexed user, uint256 indexed pid, uint256 indexed point);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EnterStaking(address indexed user, uint256 amount, uint256 lockTime);
    event LeaveStaking(address indexed user, uint256 amount);
    event EmissionUpdated(uint256 newRate);
    event StakingPercentageUpdated(uint256 newPercentage);
    event LockTimeExtended(address indexed user, uint256 extraLockTime, uint256 newUnlockTime);
    event KUpdated(uint256 oldK, uint256 newK);

    /**
     * @dev Modifier to ensure an LP token is not added more than once.
     */
    modifier nonDuplicated(IERC20 _lpToken) {
        require(!poolExistence[_lpToken], "Add: pool already exists!");
        _;
    }

    /**
     * @dev Modifier to ensure the pool ID is valid.
     */
    modifier onlyValidPool(uint256 _pid) {
        require(_pid < poolLength(), "Invalid pool ID");
        _;
    }

    /**
     * @dev Constructor to initialize the MasterFarmer contract.
     * @param initialOwner The owner of the contract.
     * @param _five The FIVE token contract address.
     * @param _startBlockTime The start time for rewards distribution.
     * @param initialK Initial steepness value for the decay curve.
     */
    constructor(address initialOwner, FIVE _five, uint256 _startBlockTime, uint256 initialK) Ownable(initialOwner) {
        require(initialK >= 1e18 && initialK <= 6 * 1e18, "initialK must be between 1 and 6 (scaled by 1e18)");
        require(_startBlockTime > block.timestamp, "_startBlockTime must be in the future");

        five = _five;
        startBlockTime = _startBlockTime;
        k = initialK;

        // Initialize the staking pool (PID[0]) for FIVE tokens.
        poolInfo.push(
            PoolInfo({ lpToken: _five, allocPoint: 1000, lastRewardBlockTime: startBlockTime, accFivePerShare: 0 })
        );

        poolExistence[_five] = true; // Mark the staking pool as added.
        totalAllocPoint = 1000;
    }

    /**
     * @notice Reduces the maximum supply of the FIVE token.
     * @param newMaxSupply The new maximum supply, which must be less than the current maximum supply.
     */
    function decreaseFiveMaxSupply(uint256 newMaxSupply) external onlyOwner {
        // Update all pools to ensure rewards are based on the current supply before changing it.
        massUpdatePools();

        uint256 currentMaxSupply = five.maxSupply();
        uint256 currentTotalSupply = five.totalSupply();

        require(newMaxSupply < currentMaxSupply, "New max supply must be less than the current max supply");
        require(newMaxSupply >= currentTotalSupply, "New max supply cannot be less than the current total supply");

        // Update the max supply in the FIVE token contract.
        five.decreaseMaxSupply(newMaxSupply);
    }

    /**
     * @notice Updates the emission rate for reward distribution.
     * @param _emission The new emission rate, must not exceed the MAX_EMISSION limit.
     */
    function setEmission(uint256 _emission) external onlyOwner {
        require(_emission <= MAX_EMISSION, "Emission rate exceeds maximum limit");

        // Update all pools to apply the new emission rate.
        massUpdatePools();

        emission = _emission;
        emit EmissionUpdated(_emission);
    }

    /**
     * @notice Updates the staking allocation percentage.
     * @param _percentage The new staking percentage, must not exceed MAX_STAKING_PERCENTAGE.
     */
    function setStakingPercentage(uint256 _percentage) external onlyOwner {
        require(_percentage <= MAX_STAKING_PERCENTAGE, "Staking percentage exceeds maximum limit");

        // Update all pools to apply the new staking percentage.
        massUpdatePools();

        stakingPercentage = _percentage;
        emit StakingPercentageUpdated(_percentage);

        // Recalculate allocation points for the staking pool.
        updateStakingPool();
    }

    /**
     * @notice Updates the steepness parameter of the reward decay curve.
     * @param newK The new steepness value, must be within the allowed range (1 to 6, scaled by 1e18).
     */
    function updateK(uint256 newK) external onlyOwner {
        require(newK >= 1e18 && newK <= 6 * 1e18, "Steepness value out of range");

        // Update all pools to ensure rewards are calculated based on the old k value before the change.
        massUpdatePools();

        emit KUpdated(k, newK);
        k = newK;
    }

    /**
     * @notice Adds a new liquidity pool for reward distribution.
     * @param _allocPoint Allocation points for the pool.
     * @param _lpToken Address of the LP token for the pool.
     * @param _withUpdate Whether to update all pools before adding this one.
     */
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlockTime = block.timestamp > startBlockTime ? block.timestamp : startBlockTime;
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlockTime: lastRewardBlockTime,
                accFivePerShare: 0
            })
        );
        poolExistence[_lpToken] = true;
        updateStakingPool();
        emit Add(msg.sender, _lpToken, _allocPoint);
    }

    /**
     * @notice Updates allocation points for an existing pool.
     * @param _pid Pool ID to update.
     * @param _allocPoint New allocation points for the pool.
     * @param _withUpdate Whether to update all pools before making the change.
     */
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        require(_pid != 0, "Cannot set allocation points for the staking pool");
        if (_withUpdate) {
            massUpdatePools();
        }
        if (poolInfo[_pid].allocPoint != _allocPoint) {
            uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
            poolInfo[_pid].allocPoint = _allocPoint;
            totalAllocPoint = totalAllocPoint - prevAllocPoint + _allocPoint;
            updateStakingPool();
            emit Set(msg.sender, _pid, _allocPoint);
        }
    }

    /**
     * @dev Updates the allocation points for the staking pool (PID[0]) based on the current staking percentage.
     *
     * @notice The staking pool is treated as a special pool (PID[0]) where users stake FIVE tokens to earn rewards.
     *         The allocation points for this pool are recalculated to maintain the specified staking percentage relative
     *         to all other pools' total allocation points.
     *
     * @notice This function ensures that the staking pool always gets the correct proportion of rewards
     *         based on the `stakingPercentage` parameter, without requiring manual adjustments when other pools are added or updated.
     */
    function updateStakingPool() internal {
        // Get the total number of pools in the system.
        uint256 length = poolLength();

        uint256 points = 0;

        // Iterate over all pools except the staking pool (PID[0]) to sum their allocation points.
        for (uint256 pid = 1; pid < length; ++pid) {
            points += poolInfo[pid].allocPoint;
        }

        if (points != 0) {
            // Calculate the new allocation points for the staking pool based on the staking percentage.
            // The formula ensures the staking pool gets a share proportional to the total allocation points of other pools:
            // stakingAlloc = (points * stakingPercentage) / (100 - stakingPercentage)
            uint256 numerator = points * stakingPercentage * 1e18; // Scale to 1e18 for precision.
            uint256 denominator = 100 - stakingPercentage; // Remaining percentage allocated to non-staking pools.
            uint256 stakingAlloc = numerator / denominator / 1e18; // Final scaled allocation for the staking pool.

            totalAllocPoint = totalAllocPoint - poolInfo[0].allocPoint + stakingAlloc;
            poolInfo[0].allocPoint = stakingAlloc;
        }
    }

    /**
     * @dev Calculates the maximum amount of FIVE tokens that can be minted based on the remaining supply.
     * @param _amount Requested mint amount.
     * @return fiveReward Actual amount of FIVE tokens that can be minted.
     */
    function fiveCanMint(uint256 _amount) internal view returns (uint256 fiveReward) {
        uint256 canMint = five.maxSupply() - five.totalSupply();
        return _amount > canMint ? canMint : _amount;
    }

    /**
     * @notice Calculates pending rewards for a user in a specific pool.
     * @param _pid Pool ID.
     * @param _user Address of the user.
     * @return Pending reward amount in FIVE tokens.
     */
    function pendingFive(uint256 _pid, address _user) public view onlyValidPool(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFivePerShare = pool.accFivePerShare;
        uint256 supply = _pid > 0 ? pool.lpToken.balanceOf(address(this)) : totalLockedAmount;

        if (block.timestamp > pool.lastRewardBlockTime && supply != 0) {
            uint256 timeElapsed = block.timestamp - pool.lastRewardBlockTime;
            uint256 rewardAmount = (timeElapsed * emission * pool.allocPoint) / totalAllocPoint;
            uint256 fiveReward = fiveCanMint(rewardAmount);
            accFivePerShare += (fiveReward * 1e18) / supply;
        }

        return (user.amount * accFivePerShare) / 1e18 - user.rewardDebt;
    }

    /**
     * @notice Calculates decayed pending rewards for a user based on veFIVE balance.
     * @param _user Address of the user.
     * @return Decayed pending reward amount in FIVE tokens.
     */
    function decayedPendingFive(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[0][_user];

        if (user.amount == 0) {
            return 0;
        }
        uint256 pending = pendingFive(0, _user);

        uint256 scaledVeFIVE = (getVeFive(_user, 0) * 1e18) / user.amount;
        return (pending * scaledVeFIVE) / 1e18;
    }

    /**
     * @notice Updates all pools to ensure rewards are distributed accurately.
     */
    function massUpdatePools() public {
        uint256 length = poolLength();
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @notice Updates a specific pool to ensure rewards are distributed accurately.
     * @param _pid Pool ID to update.
     */
    function updatePool(uint256 _pid) public onlyValidPool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardBlockTime) {
            return;
        }
        uint256 supply = _pid > 0 ? pool.lpToken.balanceOf(address(this)) : totalLockedAmount;

        if (supply == 0) {
            pool.lastRewardBlockTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pool.lastRewardBlockTime;
        uint256 rewardAmount = (timeElapsed * emission * pool.allocPoint) / totalAllocPoint;
        uint256 fiveReward = fiveCanMint(rewardAmount);
        if (fiveReward > 0) {
            five.mint(address(this), fiveReward);
        }
        pool.accFivePerShare += (fiveReward * 1e18) / supply;
        pool.lastRewardBlockTime = block.timestamp;
    }
    /**
     * @notice Allows users to deposit LP tokens into a pool to earn rewards.
     * @param _pid Pool ID where the deposit will occur.
     * @param _amount Amount of LP tokens to deposit.
     */
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant onlyValidPool(_pid) {
        require(_pid != 0, "Deposit FIVE tokens via staking pool (PID[0])");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Update pool rewards before processing deposit
        updatePool(_pid);

        // Distribute pending rewards to the user
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accFivePerShare) / 1e18 - user.rewardDebt;
            if (pending > 0) {
                safeFiveTransfer(msg.sender, pending);
            }
        }

        // Update user balance and transfer LP tokens to the contract
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount += _amount;
        }

        user.rewardDebt = (user.amount * pool.accFivePerShare) / 1e18;
        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice Allows users to withdraw LP tokens from a pool and claim pending rewards.
     * @param _pid Pool ID where the withdrawal will occur.
     * @param _amount Amount of LP tokens to withdraw.
     */
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant onlyValidPool(_pid) {
        require(_pid != 0, "Withdraw FIVE tokens via staking pool (PID[0])");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "Insufficient balance to withdraw");

        // Update pool rewards before processing withdrawal
        updatePool(_pid);

        // Distribute pending rewards to the user
        uint256 pending = (user.amount * pool.accFivePerShare) / 1e18 - user.rewardDebt;
        if (pending > 0) {
            safeFiveTransfer(msg.sender, pending);
        }

        // Update user balance and transfer LP tokens back to the user
        if (_amount > 0) {
            user.amount -= _amount;
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }

        user.rewardDebt = (user.amount * pool.accFivePerShare) / 1e18;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /**
     * @notice Allows users to stake and lock FIVE tokens in the staking pool (PID[0]).
     * @param _amount Amount of FIVE tokens to stake.
     * @param _lockDuration Lock duration for the staked tokens, must be within allowed limits.
     */
    function enterStaking(uint256 _amount, uint256 _lockDuration) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        LockInfo storage lock = lockInfo[msg.sender];

        require(_lockDuration >= MIN_LOCK_TIME && _lockDuration <= MAX_LOCK_TIME, "Invalid lock duration");

        // Update pool rewards before processing staking
        updatePool(0);

        // Handle pending rewards for previously staked tokens
        if (user.amount > 0 && block.timestamp <= lock.unlockTime) {
            uint256 maxPending = (user.amount * pool.accFivePerShare) / 1e18 - user.rewardDebt;
            uint256 pending = (maxPending * ((getVeFive(msg.sender, 0) * 1e18) / user.amount)) / 1e18;
            if (pending > 0) {
                safeFiveTransfer(msg.sender, pending);
                if (maxPending > pending) {
                    five.burn(maxPending - pending);
                }
            }
        }

        // Process staking and update lock details
        if (_amount > 0) {
            five.transferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            lock.lockAmount += _amount;

            // Extend lock time if applicable
            uint256 newUnlockTime = block.timestamp + _lockDuration;
            if (newUnlockTime > lock.unlockTime) {
                lock.unlockTime = newUnlockTime;
            }

            totalLockedAmount += _amount;

            // Increment user count if this is the first time locking
            if (lock.lockAmount == _amount) {
                totalLockedUsers++;
            }
        }

        user.rewardDebt = (user.amount * pool.accFivePerShare) / 1e18;
        emit EnterStaking(msg.sender, _amount, _lockDuration);
    }

    /**
     * @notice Allows users to unstake and withdraw their staked FIVE tokens from PID[0].
     */
    function leaveStaking() public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        LockInfo storage lock = lockInfo[msg.sender];

        require(user.amount > 0 && lock.lockAmount > 0, "No staked tokens to withdraw");

        // Update pool rewards before processing unstaking
        updatePool(0);

        if (block.timestamp <= lock.unlockTime) {
            uint256 maxPending = (user.amount * pool.accFivePerShare) / 1e18 - user.rewardDebt;
            uint256 pending = (maxPending * ((getVeFive(msg.sender, 0) * 1e18) / user.amount)) / 1e18;
            if (pending > 0) {
                safeFiveTransfer(msg.sender, pending);
                if (maxPending > pending) {
                    five.burn(maxPending - pending);
                }
            }
        } else {
            // Burn unclaimed rewards if lock has expired
            uint256 unclaimedRewards = (user.amount * pool.accFivePerShare) / 1e18 - user.rewardDebt;
            if (unclaimedRewards > 0) {
                five.burn(unclaimedRewards);
            }

            // Reset user and lock data, transfer staked tokens back to the user
            uint256 amountToTransfer = user.amount;
            user.amount = 0;
            lock.lockAmount = 0;
            lock.unlockTime = 0;
            totalLockedAmount -= amountToTransfer;
            totalLockedUsers--;

            safeFiveTransfer(msg.sender, amountToTransfer);
            emit LeaveStaking(msg.sender, amountToTransfer);
        }

        user.rewardDebt = (user.amount * pool.accFivePerShare) / 1e18;
    }

    /**
     * @notice Allows users to extend the lock duration for their staked tokens.
     * @param _additionalLockDuration The additional time to be added to the user's existing lock.
     */
    function extendLockTime(uint256 _additionalLockDuration) public nonReentrant {
        LockInfo storage lock = lockInfo[msg.sender];

        // Ensure the user has staked tokens with an active lock
        require(lock.lockAmount > 0, "No active lock to extend");

        // Validate that the additional lock duration does not exceed the maximum allowed lock duration
        require(_additionalLockDuration <= MAX_LOCK_TIME, "Exceeds maximum lock duration");

        // Validate that the additional lock duration meets the minimum allowed duration
        require(_additionalLockDuration >= MIN_LOCK_TIME, "New unlock time too short");

        // Calculate the new unlock time by adding the additional lock duration to the current block timestamp
        uint256 updatedUnlockTime = block.timestamp + _additionalLockDuration;

        // Revert if the updated unlock time is not greater than the current unlock time
        require(updatedUnlockTime > lock.unlockTime, "Unlock time must be extended");

        // If the new unlock time is valid, update the unlock time
        lock.unlockTime = updatedUnlockTime;

        // Emit the event for the lock time extension
        emit LockTimeExtended(msg.sender, _additionalLockDuration, lock.unlockTime);
    }

    /**
     * @notice Allows users to withdraw their LP tokens in an emergency without receiving rewards.
     * @param _pid Pool ID where the emergency withdrawal will occur.
     */
    function emergencyWithdraw(uint256 _pid) public nonReentrant onlyValidPool(_pid) {
        require(_pid != 0, "Emergency withdrawal unavailable for staking pool");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount > 0, "No tokens to withdraw");

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /**
     * @notice Calculates the veFIVE (vote-escrowed FIVE) balance of a user at a specific timestamp.
     * If the timestamp is before current block timestamp, it calculates the veFIVE at the current block timestamp.
     * @param _user The address of the user whose veFIVE balance is being calculated.
     * @param _timestamp The timestamp at which to calculate the veFIVE balance.
     * If it's before current block timestamp, it will default to the current block timestamp.
     * For example, use 0 for the current block timestamp.
     * @return veFIVE The calculated veFIVE balance based on the user's locked amount and remaining lock time.
     *
     * @dev This function calculates veFIVE using a normalized decay curve:
     *      - The longer the remaining lock time, the higher the veFIVE.
     *      - The amount of locked tokens directly influences the veFIVE balance.
     *      - A decay formula is used to ensure diminishing returns as lock time increases.
     */
    function getVeFive(address _user, uint256 _timestamp) public view returns (uint256) {
        if (_timestamp < block.timestamp) {
            _timestamp = block.timestamp;
        }

        LockInfo storage lock = lockInfo[_user];

        // If the user's lock has expired or they have no locked tokens, return 0.
        if (_timestamp >= lock.unlockTime || lock.lockAmount == 0) {
            return 0;
        }

        // Remaining lock time is the difference between the unlock time and the current block timestamp.
        uint256 remainingTime = lock.unlockTime - _timestamp;

        // Maximum veFIVE is directly proportional to the amount of locked tokens.
        uint256 maxVeFIVE = lock.lockAmount;

        // Normalize the remaining time as a fraction of the maximum lock duration (scaled to 1e18 for precision).
        // Example: If the remaining time is 3 months and MAX_LOCK_TIME is 6 months, scaledRemainingTime = 0.5 * 1e18.
        uint256 scaledRemainingTime = PRBMathUD60x18.div(PRBMathUD60x18.mul(remainingTime, 1e18), MAX_LOCK_TIME);

        // Multiply the normalized remaining time by the steepness parameter `k`.
        // This determines how sharply the veFIVE value decays as the remaining time decreases.
        uint256 scaledX = PRBMathUD60x18.mul(k, scaledRemainingTime);

        // Calculate the exponential decay factor `exp(-k * scaledRemainingTime)` using PRBMath.
        // This results in a value between 0 and 1, with higher values for longer remaining times.
        uint256 expValue = PRBMathUD60x18.div(1e18, PRBMathUD60x18.exp(scaledX));

        // Calculate the normalization factor to ensure that veFIVE reaches 100% when the remaining time equals MAX_LOCK_TIME.
        // The normalization factor is derived as `1 - exp(-k)`, where `k` represents the steepness of the curve.
        uint256 normalizationFactor = 1e18 - PRBMathUD60x18.div(1e18, PRBMathUD60x18.exp(k));

        // Use the normalized decay formula to calculate the veFIVE value:
        // veFIVE = maxVeFIVE * (1 - exp(-k * scaledRemainingTime)) / normalizationFactor
        // This ensures veFIVE grows asymptotically with lock time and maxVeFIVE.
        uint256 veFIVE = PRBMathUD60x18.mul(maxVeFIVE, PRBMathUD60x18.div(1e18 - expValue, normalizationFactor));

        return veFIVE;
    }

    /**
     * @notice Calculates the "veFIVE power" of a user at a specific timestamp.
     * If the timestamp is before current block timestamp, it calculates the veFIVE power at the current block timestamp.
     * @param _user The address of the user whose veFIVE power is being calculated.
     * @param _timestamp The timestamp at which to calculate the veFIVE power.
     * If it's before the current block timestamp, it will default to the current block timestamp.
     * @return veFivePower The veFIVE power of the user, which is the ratio of veFIVE to the user's locked amount.
     *
     * @dev This function calculates the veFIVE power as:
     *      - veFIVE power = getVeFIVE(_user, _timestamp) / lock.lockAmount (if the user has staked tokens in the staking pool).
     *      - It returns the ratio of veFIVE to the amount of tokens locked in PID[0].
     *      - The function returns 0 if the user has no locked tokens.
     */
    function getVeFivePower(address _user, uint256 _timestamp) public view returns (uint256) {
        LockInfo storage lock = lockInfo[_user];

        // If the user has no locked tokens, return 0
        if (lock.lockAmount == 0) {
            return 0;
        }

        // Get the veFIVE value of the user at the specified timestamp
        uint256 veFive = getVeFive(_user, _timestamp);

        // Calculate the veFIVE power as veFIVE / lock.lockAmount (for PID[0] staking pool)
        uint256 veFivePower = PRBMathUD60x18.div(veFive, lock.lockAmount);

        return veFivePower;
    }

    /**
     * @notice Returns the total number of pools in the contract.
     * @return Total pool count.
     */
    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev Safely transfers FIVE tokens, ensuring no transfer exceeds the available balance.
     * @param _to Recipient address.
     * @param _amount Amount to transfer.
     */
    function safeFiveTransfer(address _to, uint256 _amount) internal {
        uint256 fiveBalance = five.balanceOf(address(this));
        uint256 transferAmount = _amount > fiveBalance ? fiveBalance : _amount;

        five.transfer(_to, transferAmount);
    }
}
