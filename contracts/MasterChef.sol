pragma solidity 0.6.12;

import '@kokomoswap-libs/kokomo-swap-lib/contracts/math/SafeMath.sol';
import '@kokomoswap-libs/kokomo-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@kokomoswap-libs/kokomo-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import '@kokomoswap-libs/kokomo-swap-lib/contracts/access/Ownable.sol';

import "./KokomoToken.sol";
import "./SyrupBar.sol";

// import "@nomiclabs/buidler/console.sol";

interface IMigratorChef {
    function migrate(IBEP20 token) external returns (IBEP20);
}

// MasterChef is the master of Kokomo. He can make Kokomo and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once KOKOMO is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of KOKOMOs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accKokomoPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accKokomoPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. KOKOMOs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that KOKOMOs distribution occurs.
        uint256 accKokomoPerShare; // Accumulated KOKOMOs per share, times 1e12. See below.
    }

    // The KOKOMO TOKEN!
    KokomoToken public kokomo;
    // The SYRUP TOKEN!
    SyrupBar public syrup;
    // team address.
    address public teamaddr;
    // bd/reserve address.
    address public bdaddr;
    // initial liquidity provider address.
    address public liquidityprovideraddr;
    // KOKOMO tokens created per block.
    uint256 public kokomoPerBlock;
    // Bonus muliplier for early kokomo makers.
    uint256 public BONUS_MULTIPLIER = 8;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when KOKOMO mining starts.
    uint256 public startBlock;
    
    bool public premintCompleted = false;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        KokomoToken _kokomo,
        SyrupBar _syrup,
        address _teamaddr,
        address _bdaddr,
        address _liquidityprovideraddr,
        uint256 _kokomoPerBlock,
        uint256 _startBlock
    ) public {
        kokomo = _kokomo;
        syrup = _syrup;
        teamaddr = _teamaddr;
        bdaddr = _bdaddr;
        liquidityprovideraddr = _liquidityprovideraddr;
        kokomoPerBlock = _kokomoPerBlock;
        startBlock = _startBlock;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _kokomo,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accKokomoPerShare: 0
        }));

        totalAllocPoint = 1000;

    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accKokomoPerShare: 0
        }));
        updateStakingPool();
    }

    // Update the given pool's KOKOMO allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IBEP20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IBEP20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending KOKOMOs on frontend.
    function pendingKokomo(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accKokomoPerShare = pool.accKokomoPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 kokomoReward = multiplier.mul(kokomoPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            uint256 kokomoLPReward = kokomoReward.mul(70).div(100);
            accKokomoPerShare = accKokomoPerShare.add(kokomoLPReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accKokomoPerShare).div(1e12).sub(user.rewardDebt);
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
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 kokomoReward = multiplier.mul(kokomoPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        uint256 kokomoLPReward = kokomoReward.mul(70).div(100);
        kokomo.mint(teamaddr, kokomoReward.mul(15).div(100));
        kokomo.mint(bdaddr, kokomoReward.mul(15).div(100));
        kokomo.mint(address(syrup), kokomoLPReward);
        pool.accKokomoPerShare = pool.accKokomoPerShare.add(kokomoLPReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for KOKOMO allocation.
    function deposit(uint256 _pid, uint256 _amount) public {

        require (_pid != 0, 'deposit KOKOMO by staking');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accKokomoPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeKokomoTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKokomoPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {

        require (_pid != 0, 'withdraw KOKOMO by unstaking');
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accKokomoPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeKokomoTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKokomoPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake KOKOMO tokens to MasterChef
    function enterStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accKokomoPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeKokomoTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKokomoPerShare).div(1e12);

        syrup.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw KOKOMO tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accKokomoPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeKokomoTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKokomoPerShare).div(1e12);

        syrup.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe kokomo transfer function, just in case if rounding error causes pool to not have enough KOKOMOs.
    function safeKokomoTransfer(address _to, uint256 _amount) internal {
        syrup.safeKokomoTransfer(_to, _amount);
    }

    // Update team address by the previous team.
    function team(address _teamaddr) public {
        require(msg.sender == teamaddr, "team: wut?");
        teamaddr = _teamaddr;
    }
    
    // Update bd address by the previous bd.
    // Only team address can change bd address.
    function bd(address _bdaddr) public {
        require(msg.sender == teamaddr, "bd: wut?");
        bdaddr = _bdaddr;
    }
    
    function premint() public {
        require(premintCompleted == false, 'already preminted');
        // Initial liquidity pre-mint
        kokomo.mint(address(liquidityprovideraddr), 7000000 * 10 ** 18);
        premintCompleted = true;
    }
}
