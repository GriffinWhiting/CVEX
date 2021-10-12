// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./interfaces/MathUtil.sol";
import "./interfaces/IStakingProxy.sol";
import "./interfaces/IRewardStaking.sol";
import "./interfaces/BoringMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


// CVX Locking contract for https://www.convexfinance.com/
// CVX locked in this contract will be entitled to voting rights for the Convex Finance platform
// Based on EPS Staking contract for http://ellipsis.finance/
// Based on SNX MultiRewards by iamdefinitelyahuman - https://github.com/iamdefinitelyahuman/multi-rewards
contract CvxLocker is ReentrancyGuard, Ownable {

    //Vote Locked Convex Token (vlCVX)

    using BoringMath for uint256;
    using BoringMath224 for uint224;
    using BoringMath112 for uint112;
    using BoringMath32 for uint32;
    using SafeERC20
    for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        bool useBoost;     //是否使用加速
        uint40 periodFinish;//上次结算时间
        uint208 rewardRate;//奖励率
        uint40 lastUpdateTime;//最后更新时间
        uint208 rewardPerTokenStored;//每个币 对应的奖励 
    }
    //余额 总体
    struct Balances {
        uint112 locked;       //锁仓数量
        uint112 boosted;       //加速的数量
        uint32 nextUnlockIndex;//下一个解锁索引
    }
    //锁仓余额  单个的 锁仓余额
    struct LockedBalance {
        uint112 amount;    //余额
        uint112 boosted;    //加速数量
        uint32 unlockTime;  //解锁时间
    }

    //获得数据  返回结果
    struct EarnedData {
        address token;    //token address
        uint256 amount;    //数量
    }
    struct Epoch {
        uint224 supply; //epoch boosted supply  加速 supply
        uint32 date; //epoch start date  纪元开始日期
    }

    //token constants
    
    IERC20 public constant stakingToken = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B); //cvx
    address public constant cvxCrv = address(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);

    //rewards 奖励代币列表
    address[] public rewardTokens;
    //奖励数据
    mapping(address => Reward) public rewardData;

    //奖励流的持续时间
    // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 86400 * 7;

    //锁定/赢得处罚期的持续时间
    // Duration of lock/earned penalty period 
    uint256 public constant lockDuration = rewardsDuration * 17;

    //rewardDistributors 奖励分配者
    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    //supplies and epochs 
    uint256 public lockedSupply;
    uint256 public boostedSupply;
    Epoch[] public epochs;

    //mappings for balance data
    //用户锁仓余额
    mapping(address => Balances) public balances;
    //用户锁仓列表
    mapping(address => LockedBalance[]) public userLocks;

    //boost  奖励加速
    //TreasuryFunds  
    address public boostPayment = address(0x1389388d01708118b497f59521f6943Be2541bb7); 
    uint256 public maximumBoostPayment = 0;
    uint256 public boostRate = 10000;
    uint256 public nextMaximumBoostPayment = 0;
    uint256 public nextBoostRate = 10000;
    uint256 public constant denominator = 10000;

    //staking
    uint256 public minimumStake = 10000;
    uint256 public maximumStake = 10000;
    //CvxStakingProxy 0xE096ccEc4a1D36F191189Fe61E803d8B2044DFC3
    address public stakingProxy;
    address public constant cvxcrvStaking = address(0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e);
    uint256 public constant stakeOffsetOnLock = 500; //allow broader range for staking when depositing

    //management
    uint256 public kickRewardPerEpoch = 100;
    uint256 public kickRewardEpochDelay = 4;

    //shutdown
    bool public isShutdown = false;

    //erc20-like interface
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /* ========== CONSTRUCTOR ========== */

    constructor() public Ownable() {
        _name = "Vote Locked Convex Token";
        _symbol = "vlCVX";
        _decimals = 18;
        //  ?
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        epochs.push(Epoch({
            supply: 0,
            date: uint32(currentEpoch)
        }));
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /* ========== ADMIN CONFIGURATION ========== */

    //添加新的奖励token 
    // Add a new reward token to be distributed to stakers  
    function addReward(
        address _rewardsToken,
        address _distributor,
        bool _useBoost
    ) public onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime == 0);
        require(_rewardsToken != address(stakingToken));
        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = uint40(block.timestamp);
        rewardData[_rewardsToken].periodFinish = uint40(block.timestamp);
        rewardData[_rewardsToken].useBoost = _useBoost;
        rewardDistributors[_rewardsToken][_distributor] = true;
    }
    //添加 奖励分配人 _distributor
    // Modify approval for an address to call notifyRewardAmount 
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0);
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }
    
    //设置staking 的 代理合约
    //Set the staking contract for the underlying cvx. only allow change if nothing is currently staked
    //为基础cvx设定立桩合同。仅在当前未进行任何标记时才允许更改
    function setStakingContract(address _staking) external onlyOwner {
        require(stakingProxy == address(0) || (minimumStake == 0 && maximumStake == 0), "!assign");

        stakingProxy = _staking;
    }

    //设置staking 的最大 最小 限制
    //set staking limits. will stake the mean of the two once either ratio is crossed
    function setStakeLimits(uint256 _minimum, uint256 _maximum) external onlyOwner {
        require(_minimum <= denominator, "min range");
        require(_maximum <= denominator, "max range");
        minimumStake = _minimum;
        maximumStake = _maximum;
        //?
        updateStakeRatio(0);
    }

    //set boost parameters
    function setBoost(uint256 _max, uint256 _rate, address _receivingAddress) external onlyOwner {
        require(maximumBoostPayment < 1500, "over max payment"); //max 15%
        require(boostRate < 30000, "over max rate"); //max 3x
        require(_receivingAddress != address(0), "invalid address"); //must point somewhere valid
        nextMaximumBoostPayment = _max;
        nextBoostRate = _rate;
        boostPayment = _receivingAddress;
    }

    //？ kick 比例  kick是干啥的 ？
    //kick 是 delay  奖励 
    //set kick incentive  kick
    function setKickIncentive(uint256 _rate, uint256 _delay) external onlyOwner {
        require(_rate <= 500, "over max rate"); //max 5% per epoch
        require(_delay >= 2, "min delay"); //minimum 2 epochs of grace
        kickRewardPerEpoch = _rate;
        kickRewardEpochDelay = _delay;
    }

    //关闭合约
    //shutdown the contract. unstake all tokens. release all locks
    function shutdown() external onlyOwner {
        if (stakingProxy != address(0)) {
            uint256 stakeBalance = IStakingProxy(stakingProxy).getBalance();
            IStakingProxy(stakingProxy).withdraw(stakeBalance);
        }
        isShutdown = true;
    }

    //approve 授权 数量
    //set approvals for staking cvx and cvxcrv
    function setApprovals() external {
        //为啥需要 先授权0  再授权最大值 
        IERC20(cvxCrv).safeApprove(cvxcrvStaking, 0);
        IERC20(cvxCrv).safeApprove(cvxcrvStaking, uint256(-1));

        IERC20(stakingToken).safeApprove(stakingProxy, 0);
        IERC20(stakingToken).safeApprove(stakingProxy, uint256(-1));
    }

    /* ========== VIEWS ========== */
    //一个token 分多少 reward
    function _rewardPerToken(address _rewardsToken) internal view returns(uint256) {
        //没有加速 就没有收益
        if (boostedSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
        uint256(rewardData[_rewardsToken].rewardPerTokenStored).add(
            //预计结束 和 当前 取小 算出时间段
            //时间差.mul(奖励率).mul(1e18).div(总数量（加速或者锁的）)
            _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish).sub(
                rewardData[_rewardsToken].lastUpdateTime).mul(
                rewardData[_rewardsToken].rewardRate).mul(1e18).div(rewardData[_rewardsToken].useBoost ? boostedSupply : lockedSupply)
        );
    }

    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance
    ) internal view returns(uint256) {
        //余额 *（当前比例 - 已经结算的 比例） + 已经存在的 奖励
        return _balance.mul(
            _rewardPerToken(_rewardsToken).sub(userRewardPerTokenPaid[_user][_rewardsToken])
        ).div(1e18).add(rewards[_user][_rewardsToken]);
    }

    function _lastTimeRewardApplicable(uint256 _finishTime) internal view returns(uint256){
        return Math.min(block.timestamp, _finishTime);
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns(uint256) {
        return _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) external view returns(uint256) {
        return _rewardPerToken(_rewardsToken);
    }

    function getRewardForDuration(address _rewardsToken) external view returns(uint256) {
        return uint256(rewardData[_rewardsToken].rewardRate).mul(rewardsDuration);
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address _account) external view returns(EarnedData[] memory userRewards) {
        userRewards = new EarnedData[](rewardTokens.length);
        Balances storage userBalance = balances[_account];
        uint256 boostedBal = userBalance.boosted;
        for (uint256 i = 0; i < userRewards.length; i++) {
            address token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(_account, token, rewardData[token].useBoost ? boostedBal : userBalance.locked);
        }
        return userRewards;
    }

    // Total BOOSTED balance of an account, including unlocked but not withdrawn tokens
    function rewardWeightOf(address _user) view external returns(uint256 amount) {
        return balances[_user].boosted;
    }

    // total token balance of an account, including unlocked but not withdrawn tokens
    function lockedBalanceOf(address _user) view external returns(uint256 amount) {
        return balances[_user].locked;
    }

    //BOOSTED balance of an account which only includes properly locked tokens as of the most recent eligible epoch
    function balanceOf(address _user) view external returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;

        //start with current boosted amount
        amount = balances[_user].boosted;

        uint256 locksLength = locks.length;
        //remove old records only (will be better gas-wise than adding up)
        for (uint i = nextUnlockIndex; i < locksLength; i++) {
            if (locks[i].unlockTime <= block.timestamp) {
                amount = amount.sub(locks[i].boosted);
            } else {
                //stop now as no futher checks are needed
                break;
            }
        }

        //also remove amount in the current epoch
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        if (locksLength > 0 && uint256(locks[locksLength - 1].unlockTime).sub(lockDuration) == currentEpoch) {
            amount = amount.sub(locks[locksLength - 1].boosted);
        }

        return amount;
    }

    //BOOSTED balance of an account which only includes properly locked tokens at the given epoch
    function balanceAtEpochOf(uint256 _epoch, address _user) view external returns(uint256 amount) {
        LockedBalance[] storage locks = userLocks[_user];

        //get timestamp of given epoch index
        uint256 epochTime = epochs[_epoch].date;
        //get timestamp of first non-inclusive epoch
        uint256 cutoffEpoch = epochTime.sub(lockDuration);

        //current epoch is not counted
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);

        //need to add up since the range could be in the middle somewhere
        //traverse inversely to make more current queries more gas efficient
        for (uint i = locks.length - 1; i + 1 != 0; i--) {
            uint256 lockEpoch = uint256(locks[i].unlockTime).sub(lockDuration);
            //lock epoch must be less or equal to the epoch we're basing from.
            //also not include the current epoch
            if (lockEpoch <= epochTime && lockEpoch < currentEpoch) {
                if (lockEpoch > cutoffEpoch) {
                    amount = amount.add(locks[i].boosted);
                } else {
                    //stop now as no futher checks matter
                    break;
                }
            }
        }

        return amount;
    }

    //supply of all properly locked BOOSTED balances at most recent eligible epoch
    function totalSupply() view external returns(uint256 supply) {

        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        uint256 cutoffEpoch = currentEpoch.sub(lockDuration);
        uint256 epochindex = epochs.length;

        //do not include current epoch's supply
        if ( uint256(epochs[epochindex - 1].date) == currentEpoch) {
            epochindex--;
        }

        //traverse inversely to make more current queries more gas efficient
        for (uint i = epochindex - 1; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(e.supply);
        }

        return supply;
    }

    //supply of all properly locked BOOSTED balances at the given epoch
    function totalSupplyAtEpoch(uint256 _epoch) view external returns(uint256 supply) {

        uint256 epochStart = uint256(epochs[_epoch].date).div(rewardsDuration).mul(rewardsDuration);
        uint256 cutoffEpoch = epochStart.sub(lockDuration);
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);

        //do not include current epoch's supply
        if (uint256(epochs[_epoch].date) == currentEpoch) {
            _epoch--;
        }

        //traverse inversely to make more current queries more gas efficient
        for (uint i = _epoch; i + 1 != 0; i--) {
            Epoch storage e = epochs[i];
            if (uint256(e.date) <= cutoffEpoch) {
                break;
            }
            supply = supply.add(epochs[i].supply);
        }

        return supply;
    }

    //find an epoch index based on timestamp
    function findEpochId(uint256 _time) view external returns(uint256 epoch) {
        uint256 max = epochs.length - 1;
        uint256 min = 0;

        //convert to start point
        _time = _time.div(rewardsDuration).mul(rewardsDuration);

        for (uint256 i = 0; i < 128; i++) {
            if (min >= max) break;

            uint256 mid = (min + max + 1) / 2;
            uint256 midEpochBlock = epochs[mid].date;
            if(midEpochBlock == _time){
                //found
                return mid;
            }else if (midEpochBlock < _time) {
                min = mid;
            } else{
                max = mid - 1;
            }
        }
        return min;
    }


    // Information on a user's locked balances
    function lockedBalances(
        address _user
    ) view external returns(
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    ) {
        LockedBalance[] storage locks = userLocks[_user];
        Balances storage userBalance = balances[_user];
        uint256 nextUnlockIndex = userBalance.nextUnlockIndex;
        uint256 idx;
        for (uint i = nextUnlockIndex; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked.add(locks[i].amount);
            } else {
                unlockable = unlockable.add(locks[i].amount);
            }
        }
        return (userBalance.locked, unlockable, locked, lockData);
    }

    //number of epochs
    function epochCount() external view returns(uint256) {
        return epochs.length;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function checkpointEpoch() external {
        _checkpointEpoch();
    }

    //如果需要，请插入新纪元。填补任何空白
    //insert a new epoch if needed. fill in any gaps
    function _checkpointEpoch() internal {
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        uint256 epochindex = epochs.length;

        //first epoch add in constructor, no need to check 0 length

        //check to add  判断最后一个的日期是否小区当前的时间
        if (epochs[epochindex - 1].date < currentEpoch) {
            //fill any epoch gaps
            while(epochs[epochs.length-1].date != currentEpoch){
                //如果不想等 就累加一个rewardsDuration  报酬期限
                uint256 nextEpochDate = uint256(epochs[epochs.length-1].date).add(rewardsDuration);
                epochs.push(Epoch({
                    supply: 0,
                    date: uint32(nextEpochDate)
                }));
            }

            //update boost parameters on a new epoch  看看是否改变 -> 更新
            if(boostRate != nextBoostRate){
                //持续关注  boostRate  应该会变化
                boostRate = nextBoostRate;
            }

            //最大加速支付 数量 看看是否更新 -> 更新
            if(maximumBoostPayment != nextMaximumBoostPayment){
                //持续关注 maximumBoostPayment 应该会变化
                maximumBoostPayment = nextMaximumBoostPayment;
            }
        }
    }

    //锁仓  地址  数量  加速比例
    // Locked tokens cannot be withdrawn for lockDuration and are eligible to receive stakingReward rewards
    //??_spendRatio
    function lock(address _account, uint256 _amount, uint256 _spendRatio) external nonReentrant updateReward(_account) {

        //pull tokens  转入cvx
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        //lock 调用_lock
        _lock(_account, _amount, _spendRatio);
    }

    //lock tokens
    function _lock(address _account, uint256 _amount, uint256 _spendRatio) internal {
        require(_amount > 0, "Cannot stake 0");
        //??maximumBoostPayment   啥意思  支付比例 不能超过
        require(_spendRatio <= maximumBoostPayment, "over max spend");
        require(!isShutdown, "shutdown");

        //锁仓 余额 
        Balances storage bal = balances[_account];

        //must try check pointing epoch first
        _checkpointEpoch();

        //calc lock and boosted amount 
        //计算 spendAmount  
        uint256 spendAmount = _amount.mul(_spendRatio).div(denominator); 
        //计算 boost 加速的 比例              
        uint256 boostRatio = boostRate.mul(_spendRatio).div(maximumBoostPayment==0?1:maximumBoostPayment);
        //锁仓数量 = 传入数量 - 花费数量 
        uint112 lockAmount = _amount.sub(spendAmount).to112();
        // boostedAmout =  数量 + 支付的 数量 spendAmount
        uint112 boostedAmount = _amount.add(_amount.mul(boostRatio).div(denominator)).to112();

        //add user balances  
        //添加用户余额 vlcvx
        bal.locked = bal.locked.add(lockAmount);
        //添加 boostedAmount
        bal.boosted = bal.boosted.add(boostedAmount);

        //add to total supplies 
        //锁仓 supply 
        lockedSupply = lockedSupply.add(lockAmount);
        //boostedSupply 增长
        boostedSupply = boostedSupply.add(boostedAmount);

        //add user lock records or add to current
        //确认时间
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        //锁仓时间 119 天
        uint256 unlockTime = currentEpoch.add(lockDuration);
        //该用户锁仓所有数据
        uint256 idx = userLocks[_account].length;
        if (idx == 0 || userLocks[_account][idx - 1].unlockTime < unlockTime) {
            //新增锁仓数据
            userLocks[_account].push(LockedBalance({
                amount: lockAmount,
                boosted: boostedAmount,
                unlockTime: uint32(unlockTime)
            }));
        } else {
            //在最后一个基础上 加amount  和 boosted数量
            LockedBalance storage userL = userLocks[_account][idx - 1];
            userL.amount = userL.amount.add(lockAmount);
            userL.boosted = userL.boosted.add(boostedAmount);
        }

        
        //update epoch supply, epoch checkpointed above so safe to add to latest
        //更新epoch供应，epoch检查点位于上方，以便安全添加到最新版本
        //增加 Epoch.supply
        Epoch storage e = epochs[epochs.length - 1];
        e.supply = e.supply.add(uint224(boostedAmount));

        //send boost payment  转给boostPayment 为加速 支付金额
        if (spendAmount > 0) {
            stakingToken.safeTransfer(boostPayment, spendAmount);
        }

        //update staking, allow a bit of leeway for smaller deposits to reduce gas
        //更新staking，为较小的沉积物留出一点余地，以减少气体  更新 stake的比例，多了取回来，少了继续 stake
        updateStakeRatio(stakeOffsetOnLock);

        emit Staked(_account, _amount, lockAmount, boostedAmount);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    // 在解锁时间已过的情况下提取所有当前锁定的令牌
    function _processExpiredLocks(address _account, bool _relock, uint256 _spendRatio, address _withdrawTo, address _rewardAddress, uint256 _checkDelay) internal updateReward(_account) {
        //用户锁仓的列表
        LockedBalance[] storage locks = userLocks[_account];
        //用户 锁仓的总余额
        Balances storage userBalance = balances[_account];
        uint112 locked;
        uint112 boostedAmount;
        uint256 length = locks.length;
        uint256 reward = 0;
        
        if (isShutdown || locks[length - 1].unlockTime <= block.timestamp.sub(_checkDelay)) {
            //if time is beyond last lock, can just bundle everything together
            //如果时间超过了最后一个锁，我们可以把所有的东西捆绑在一起   预计 解锁所有
            locked = userBalance.locked;
            boostedAmount = userBalance.boosted;

            //dont delete, just set next index  设置 下一个解锁为 length
            userBalance.nextUnlockIndex = length.to32();

            //check for kick reward 检查踢腿奖励
            //this wont have the exact reward rate that you would get if looped through  这将不会有确切的回报率，你会得到如果循环通过
            //but this section is supposed to be for quick and easy low gas processing of all locks 但这一部分应该用于所有船闸的快速、简单的低气体处理
            //we'll assume that if the reward was good enough someone would have processed at an earlier epoch 我们假设，如果奖励足够好的话，有人会在更早的时期处理
            if (_checkDelay > 0) {
                uint256 currentEpoch = block.timestamp.sub(_checkDelay).div(rewardsDuration).mul(rewardsDuration);
                uint256 epochsover = currentEpoch.sub(uint256(locks[length - 1].unlockTime)).div(rewardsDuration);
                uint256 rRate = MathUtil.min(kickRewardPerEpoch.mul(epochsover+1), denominator);
                reward = uint256(locks[length - 1].amount).mul(rRate).div(denominator);
            }
        } else {

            //use a processed index(nextUnlockIndex) to not loop as much
            //deleting does not change array length
            uint32 nextUnlockIndex = userBalance.nextUnlockIndex;
            for (uint i = nextUnlockIndex; i < length; i++) {
                //unlock time must be less or equal to time
                if (locks[i].unlockTime > block.timestamp.sub(_checkDelay)) break;

                //add to cumulative amounts
                locked = locked.add(locks[i].amount);
                boostedAmount = boostedAmount.add(locks[i].boosted);

                //check for kick reward 检查踢腿奖励
                //each epoch over due increases reward
                //每超过一个时代，奖励就会增加
                if (_checkDelay > 0) {
                    uint256 currentEpoch = block.timestamp.sub(_checkDelay).div(rewardsDuration).mul(rewardsDuration);
                    //计算过去了多少周
                    uint256 epochsover = currentEpoch.sub(uint256(locks[i].unlockTime)).div(rewardsDuration);

                    //计算kickRewardPerEpoch
                    uint256 rRate = MathUtil.min(kickRewardPerEpoch.mul(epochsover+1), denominator);
                    //累加奖励 reward =  reward + locks[i].amount(锁仓数量)
                    reward = reward.add(uint256(locks[i].amount).mul(rRate).div(denominator));
                }
                //set next unlock index
                nextUnlockIndex++;
            }
            //update next unlock index
            userBalance.nextUnlockIndex = nextUnlockIndex;
        }
        require(locked > 0, "no exp locks");

        //update user balances and total supplies  减去余额
        userBalance.locked = userBalance.locked.sub(locked);
        userBalance.boosted = userBalance.boosted.sub(boostedAmount);
        lockedSupply = lockedSupply.sub(locked);
        boostedSupply = boostedSupply.sub(boostedAmount);

        emit Withdrawn(_account, locked, _relock);

        //send process incentive  判断奖励是否大于 0 
        if (reward > 0) {
            //if theres a reward(kicked), it will always be a withdraw only
            // 如果有奖励（踢），它将永远是一个退出只
            //preallocate enough cvx from stake contract to pay for both reward and withdraw
            //从股权合同中预先分配足够的cvx，以支付报酬和退出
            allocateCVXForTransfer(uint256(locked));

            //reduce return amount by the kick reward
            locked = locked.sub(reward.to112());
            
            //transfer reward 转账奖励
            transferCVX(_rewardAddress, reward, false);

            emit KickReward(_rewardAddress, _account, reward);
        }else if(_spendRatio > 0){
            //preallocate enough cvx to transfer the boost cost   加速
            allocateCVXForTransfer( uint256(locked).mul(_spendRatio).div(denominator) );
        }

        //relock or return to user
        if (_relock) {
            _lock(_withdrawTo, locked, _spendRatio);
        } else {
            transferCVX(_withdrawTo, locked, true);
        }
    }

    //_relock :是否重新锁仓  _spendRatio：加速 花费比例 _withdrawTo： 提现接受地址 

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    //撤消/重新锁定解锁时间已过的所有当前锁定令牌
    function processExpiredLocks(bool _relock, uint256 _spendRatio, address _withdrawTo) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, _spendRatio, _withdrawTo, msg.sender, 0);
    }

    // Withdraw/relock all currently locked tokens where the unlock time has passed
    //撤消/重新锁定解锁时间已过的所有当前锁定令牌
    function processExpiredLocks(bool _relock) external nonReentrant {
        _processExpiredLocks(msg.sender, _relock, 0, msg.sender, msg.sender, 0);
    }

    function kickExpiredLocks(address _account) external nonReentrant {
        //allow kick after grace period of 'kickRewardEpochDelay'  
        //允许在“kickrewardedpochdelay”宽限期后踢       7 day * 4
        _processExpiredLocks(_account, false, 0, _account, msg.sender, rewardsDuration.mul(kickRewardEpochDelay));
    }

    //pull required amount of cvx from staking for an upcoming transfer
    function allocateCVXForTransfer(uint256 _amount) internal{
        uint256 balance = stakingToken.balanceOf(address(this));
        if (_amount > balance) {
            IStakingProxy(stakingProxy).withdraw(_amount.sub(balance));
        }
    }

    //transfer helper: pull enough from staking, transfer, updating staking ratio
    //ExpiredTransfer助手：从锁紧、转移、更新锁紧比率中拉出足够的力
    function transferCVX(address _account, uint256 _amount, bool _updateStake) internal {
        //从立桩中为转移分配足够的cvx
        //allocate enough cvx from staking for the transfer
        allocateCVXForTransfer(_amount);
        //transfer
        stakingToken.safeTransfer(_account, _amount);

        //update staking
        if(_updateStake){
            updateStakeRatio(0);
        }
    }

    //calculate how much cvx should be staked. update if needed
    //计算应标多少cvx。如果需要，请更新
    function updateStakeRatio(uint256 _offset) internal {
        if (isShutdown) return;

        //get balances cvx
        uint256 local = stakingToken.balanceOf(address(this));
        //获得 stakingProxy 在 cvxRewardPool  的余额 (CVX)
        uint256 staked = IStakingProxy(stakingProxy).getBalance();
        //计算 总额
        uint256 total = local.add(staked);
        
        if(total == 0) return;

        //current staked ratio  计算 staked 占 全部的 比例  。分母为 10000 先放大 分母这么大的倍数 
        uint256 ratio = staked.mul(denominator).div(total);
        //mean will be where we reset to if unbalanced
        // 如果不平衡，平均值将是我们重置的位置
        uint256 mean = maximumStake.add(minimumStake).div(2);
        uint256 max = maximumStake.add(_offset);
        uint256 min = Math.min(minimumStake, minimumStake - _offset);
        //如果 比例 大于 最大值
        if (ratio > max) {
            //remove
            //提取移除部分 = staked -  均值比例 * 总和
            uint256 remove = staked.sub(total.mul(mean).div(denominator));
            IStakingProxy(stakingProxy).withdraw(remove);
        } else if (ratio < min) {
            //add
            //转出部分 = 均值比例 * 总和 - staked
            uint256 increase = total.mul(mean).div(denominator).sub(staked);
            stakingToken.safeTransfer(stakingProxy, increase);
            IStakingProxy(stakingProxy).stake();
        }
    }

    // Claim all pending rewards  提取所有 pending 奖励， 
    function getReward(address _account, bool _stake) public nonReentrant updateReward(_account) {
        for (uint i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[_account][_rewardsToken];
            if (reward > 0) {
                rewards[_account][_rewardsToken] = 0;
                //如果 奖励代币 是 cvxCrv 和  stake 进去 
                if (_rewardsToken == cvxCrv && _stake) {
                    IRewardStaking(cvxcrvStaking).stakeFor(_account, reward);
                } else {
                    IERC20(_rewardsToken).safeTransfer(_account, reward);
                }
                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }
    }

    // claim all pending rewards
    function getReward(address _account) external{
        getReward(_account,false);
    }


    /* ========== RESTRICTED FUNCTIONS ========== */
    //更新rewardRate  每秒对应的收益
    function _notifyReward(address _rewardsToken, uint256 _reward) internal {
        Reward storage rdata = rewardData[_rewardsToken];

        //判断当前时间 是否 >= 上次计算时间 （已经超过 结束时间）
        if (block.timestamp >= rdata.periodFinish) {
            //7天内 一秒的  奖励数量
            rdata.rewardRate = _reward.div(rewardsDuration).to208();
        } else {
            //需要结算的 时间 
            uint256 remaining = uint256(rdata.periodFinish).sub(block.timestamp);
            //预计产生的收益
            uint256 leftover = remaining.mul(rdata.rewardRate);
            //更新 每秒收益比例
            rdata.rewardRate = _reward.add(leftover).div(rewardsDuration).to208();
        }

        rdata.lastUpdateTime = block.timestamp.to40();
        rdata.periodFinish = block.timestamp.add(rewardsDuration).to40();
    }

    function notifyRewardAmount(address _rewardsToken, uint256 _reward) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender]);
        require(_reward > 0, "No reward");

        _notifyReward(_rewardsToken, _reward);

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the _reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), _reward);
        
        emit RewardAdded(_rewardsToken, _reward);

        if(_rewardsToken == cvxCrv){
            //update staking ratio if main reward
            updateStakeRatio(0);
        }
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    // 增加了支持从其他系统（如分配给持有人的BAL）中回收LP奖励的功能
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        require(rewardData[_tokenAddress].lastUpdateTime == 0, "Cannot withdraw reward token");
        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* ========== MODIFIERS ========== */
    //更新奖励
    modifier updateReward(address _account) {
        {//stack too deep
            //用户余额数据
            Balances storage userBalance = balances[_account];
            //加速余额
            uint256 boostedBal = userBalance.boosted;
            for (uint i = 0; i < rewardTokens.length; i++) {
                address token = rewardTokens[i];
                //rewardData 数据
                rewardData[token].rewardPerTokenStored = _rewardPerToken(token).to208();
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(rewardData[token].periodFinish).to40();
                if (_account != address(0)) {
                    //check if reward is boostable or not. use boosted or locked balance accordingly
                    rewards[_account][token] = _earned(_account, token, rewardData[token].useBoost ? boostedBal : userBalance.locked );
                    //本次支付的 比例
                    userRewardPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
                }
            }
        }
        _;
    }

    /* ========== EVENTS ========== */
    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(address indexed _user, uint256 _paidAmount, uint256 _lockedAmount, uint256 _boostedAmount);
    event Withdrawn(address indexed _user, uint256 _amount, bool _relocked);
    event KickReward(address indexed _user, address indexed _kicked, uint256 _reward);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _reward);
    event Recovered(address _token, uint256 _amount);
}