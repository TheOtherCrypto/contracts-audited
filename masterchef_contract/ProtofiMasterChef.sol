// SPDX-License-Identifier: MIT
pragma solidity >= 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./ProtonToken.sol";
import "./ElectronToken.sol";

/**
This is the masterchef of ProtoFi.

It has several features:

- Ownable
- ReentrancyGuard
- Farms with:
--- Lockup period (customizable)
--- Deposit fee (customizable)
--- Primary or secondary tokens as reward

Owner --> Timelock

Base is the Masterchef from Pancake, with several added features and ReentrancyGuard for security reasons
*/
contract ProtofiMasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for ProtofiERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;           // How many LP tokens the user has provided.
        uint256 rewardDebt;       // Reward debt. See explanation below.
        uint256 rewardLockedUp;   // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of PROTOs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accProtonPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accProtonPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 lpSupply;         // Supply of the lp token related to the pool.
        uint256 allocPoint;       // How many allocation points assigned to this pool. PROTOs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that PROTOs distribution occurs.
        uint256 accProtonPerShare; // Accumulated PROTOs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points.
        uint256 harvestInterval;  // Harvest interval in seconds.
        bool isElectronRewards;     // Establishes which token is given as reward for each pool.
    }

    // The PROTO token - Primary token for ProtoFi tokenomics
    ProtonToken public proton;
    // The ELCT token - Secondary (shares) token for ProtoFi tokenomics
    ElectronToken public electron;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // PROTO tokens created per block, number including decimals.
    uint256 public protonPerBlock;
    // Bonus muliplier
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days; // Cannot be changed, ever!
    // Max deposit fee is at 6% - Gives us a bit of flexibility, in general it will be <= 4.5%
    uint256 public constant MAXIMUM_DEPOSIT_FEES = 600; // Cannot be changed, ever!

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when PROTO mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Events, always useful to keep trak
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 indexed protonPerBlock);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    event UpdatedDevAddress(address indexed previousDevAddress, address indexed newDevAddress);
    event UpdatedFeeAddress(address indexed previousFeeAddress, address indexed newFeeAddress);

    constructor(
        ProtonToken _proton,
        ElectronToken _electron,
        uint256 _startBlock,
        uint256 _protonPerBlock,
        address _devaddr,
        address _feeAddress
    ) public {
        proton = _proton;
        electron = _electron;
        startBlock = _startBlock;
        protonPerBlock = _protonPerBlock;

        devAddress = _devaddr;
        feeAddress = _feeAddress;

        // No pools are added by default!
    }

    // Checks that poolInfo array has length at least >= _pid
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    // Returns the number of pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken,
                uint16 _depositFeeBP, uint256 _harvestInterval, 
                bool _isElectronRewards) public onlyOwner {

        // First deposit fee and harvest interval must not be higher than predefined values
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEES, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");

        // Always update pools
        massUpdatePools();

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        // Update the totalAllocPoint for the whole masterchef!
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            lpSupply: 0,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accProtonPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval,
            isElectronRewards: _isElectronRewards
        }));
    }

    // Update the given pool's PROTO allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint,
                 uint16 _depositFeeBP, uint256 _harvestInterval,
                 bool _isElectronRewards) public onlyOwner {
        // First deposit fee and harvest interval must not be higher than predefined values
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEES, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");

        // Always update pools
        massUpdatePools();

        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        poolInfo[_pid].isElectronRewards = _isElectronRewards;
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        if (prevAllocPoint != _allocPoint) {
            // Update the totalAllocPoint for the whole masterchef!
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending PROTOs on frontend.
    function pendingProton(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accProtonPerShare = pool.accProtonPerShare;
        uint256 lpSupply = pool.lpSupply; // Taken from the pool!
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 protonReward = multiplier.mul(protonPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accProtonPerShare = accProtonPerShare.add(protonReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accProtonPerShare).div(1e12).sub(user.rewardDebt);
        if(!pool.isElectronRewards){
            // Primary token has a 1.8% burning mechanism on the transfer function, hence
            // we take into account the 1.8% auto-burn
            pending = pending.mul(982).div(1000);
        }
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest PROTOs.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpSupply;
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 protonReward = multiplier.mul(protonPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // 5% fees to the dev address for salaries + Marketing + Moneypot
        proton.mint(devAddress, protonReward.div(20));

        // 5% To the burning address
        proton.mint(address(this), protonReward.div(20));
        safeProtonTransfer(BURN_ADDRESS, protonReward.div(20));

        if (pool.isElectronRewards){
            electron.mint(address(this), protonReward);
        }
        else{
            proton.mint(address(this), protonReward);
        }
        pool.accProtonPerShare = pool.accProtonPerShare.add(protonReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    /**
    Deposit LP tokens to ProtofiMasterChef for PROTO allocation.
    At the same time, updates the Pool and harvests if the user
    is allowed to harvest from this pool
    */
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingProton(_pid);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(proton)) {
                // Takes into account the 1.8% burning fees of the primary token
                uint256 transferTax = _amount.mul(18).div(1000);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                // Stake paying deposit fees.
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accProtonPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
    Withdraw LP tokens from ProtofiMasterChef.
    At the same time, updates the Pool and harvests if the user
    is allowed to harvest from this pool
    */
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: user amount staked is lower than the requested amount");

        updatePool(_pid);
        payOrLockupPendingProton(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accProtonPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /**
    Withdraw without caring about rewards. EMERGENCY ONLY.
    Resets user infos.
    Resets pool infos for the user (lpSupply)
    Transfers staked tokens to the user
    */
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpSupply = pool.lpSupply.sub(user.amount);
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending PROTOs.
    function payOrLockupPendingProton(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            // Update nextHarvestTime for the user if it's set to 0
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accProtonPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // Reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // Send rewards
                if(pool.isElectronRewards){
                    safeElectronTransfer(msg.sender, totalRewards);
                }
                else{
                    safeProtonTransfer(msg.sender, totalRewards);
                }
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe proton transfer function, just in case if rounding error causes pool to not have enough PROTOs.
    function safeProtonTransfer(address _to, uint256 _amount) internal {
        uint256 protonBal = proton.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > protonBal) {
            transferSuccess = proton.transfer(_to, protonBal);
        } else {
            transferSuccess = proton.transfer(_to, _amount);
        }
        require(transferSuccess, "safeProtonTransfer: Transfer failed");
    }

    // Safe electron transfer function, just in case if rounding error causes pool to not have enough ELCTs.
    function safeElectronTransfer(address _to, uint256 _amount) internal {
        uint256 electronBal = electron.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > electronBal) {
            transferSuccess = electron.transfer(_to, electronBal);
        } else {
            transferSuccess = electron.transfer(_to, _amount);
        }
        require(transferSuccess, "safeElectronTransfer: Transfer failed");
    }

    function getPoolInfo(uint256 _pid) external view
        returns(address lpToken, uint256 allocPoint,
                uint256 lastRewardBlock, uint256 accProtonPerShare,
                uint256 depositFeeBP, uint256 harvestInterval,
                bool isElectronRewards) {
        return (
            address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].accProtonPerShare,
            poolInfo[_pid].depositFeeBP,
            poolInfo[_pid].harvestInterval,
            poolInfo[_pid].isElectronRewards
        );
    }

    // Sets the dev address, can be changed only by the dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
        emit UpdatedDevAddress(msg.sender, _devAddress);
    }

    // Sets the fee address, can be changed only by the feeAddress.
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
        emit UpdatedFeeAddress(msg.sender, _feeAddress);
    }

    // Update Emission Rate to control the emission per block (TimeLocked).
    function updateEmissionRate(uint256 _protonPerBlock) public onlyOwner {
        massUpdatePools();
        protonPerBlock = _protonPerBlock;
        emit UpdateEmissionRate(msg.sender, _protonPerBlock);
    }
}