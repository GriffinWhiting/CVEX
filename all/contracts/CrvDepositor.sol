// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./Interfaces.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';


contract CrvDepositor{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant escrow = address(0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2); //Vote-escrowed CRV  托管 veCRV
    uint256 private constant MAXTIME = 4 * 364 * 86400;
    uint256 private constant WEEK = 7 * 86400;

    uint256 public lockIncentive = 10; //incentive to users who spend gas to lock crv 对花费汽油锁定crv的用户的激励
    uint256 public constant FEE_DENOMINATOR = 10000;  //fee 分母

    address public feeManager;  
    address public immutable staker;  //CurveVoterProxy  0x989AEb4d175e16225E39E87d0D97A3360524AD80
    address public immutable minter;  //cvxCrvToken 0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7
    uint256 public incentiveCrv = 0;
    uint256 public unlockTime;

    constructor(address _staker, address _minter) public {
        staker = _staker;
        minter = _minter;
        feeManager = msg.sender;
    }

    function setFeeManager(address _feeManager) external {
        require(msg.sender == feeManager, "!auth");
        feeManager = _feeManager;
    }

    function setFees(uint256 _lockIncentive) external{
        require(msg.sender==feeManager, "!auth");

        if(_lockIncentive >= 0 && _lockIncentive <= 30){
            lockIncentive = _lockIncentive;
       }
    }

    //初始化 lock
    function initialLock() external{
        require(msg.sender==feeManager, "!auth");

        //staker 的 veCrv 的数量
        uint256 vecrv = IERC20(escrow).balanceOf(staker);
        if(vecrv == 0){
            uint256 unlockAt = block.timestamp + MAXTIME;
            //清除 后面的 0  达到整数的 效果 
            uint256 unlockInWeeks = (unlockAt/WEEK)*WEEK;

            //release old lock if exists  把老的锁仓  释放掉
            IStaker(staker).release();
            //create new lock
            uint256 crvBalanceStaker = IERC20(crv).balanceOf(staker);
            //锁仓crv
            IStaker(staker).createLock(crvBalanceStaker, unlockAt);
            unlockTime = unlockInWeeks;
        }
    }

    //lock curve
    function _lockCurve() internal {
        //crv 数量
        uint256 crvBalance = IERC20(crv).balanceOf(address(this));
        if(crvBalance > 0){
            //转给 staker
            IERC20(crv).safeTransfer(staker, crvBalance);
        }
        
        //increase ammount
        //staker 的 crv余额
        uint256 crvBalanceStaker = IERC20(crv).balanceOf(staker);
        if(crvBalanceStaker == 0){
            return;
        }
        
        //increase amount  增加锁仓数量
        IStaker(staker).increaseAmount(crvBalanceStaker);
        

        uint256 unlockAt = block.timestamp + MAXTIME;
        uint256 unlockInWeeks = (unlockAt/WEEK)*WEEK;

        //increase time too if over 2 week buffer 
        if(unlockInWeeks.sub(unlockTime) > 2){
            //增加锁仓时间
            IStaker(staker).increaseTime(unlockAt);
            unlockTime = unlockInWeeks;
        }
    }

    function lockCurve() external {
        _lockCurve();

        //mint incentives
        if(incentiveCrv > 0){
            //增发 cvxCRV
            ITokenMinter(minter).mint(msg.sender,incentiveCrv);
            incentiveCrv = 0;
        }
    }

    //为cvxCrv存入crv
    //可以立即锁定或通过支付费用将锁定延迟给其他人。
    //虽然用户可以选择锁定或延迟，但这主要是为了
    // cvx 奖励合约要求奖励的成本并不高
    //deposit crv for cvxCrv
    //can locking immediately or defer locking to someone else by paying a fee.
    //while users can choose to lock or defer, this is mostly in place so that
    //the cvx reward contract isnt costly to claim rewards
    function deposit(uint256 _amount, bool _lock, address _stakeAddress) public {
        require(_amount > 0,"!>0");
        
        //_lock 为true  转到 staker 那边
        if(_lock){
            //lock immediately, transfer directly to staker to skip an erc20 transfer
            //转入crv  进来 给 staker =  CurveVoterProxy 
            IERC20(crv).safeTransferFrom(msg.sender, staker, _amount);
            //锁仓 cRV 到 vote escrow CRV
            _lockCurve();
            //如果 之前有剩余没有处理的  本次一次处理
            if(incentiveCrv > 0){
                //add the incentive tokens here so they can be staked together
                //在此处添加奖励代币，以便将它们押在一起
                _amount = _amount.add(incentiveCrv);
                incentiveCrv = 0;
            }
        }else{
            //不锁的话 转入到 address(this) 里面此合约
            //move tokens here 转账 crv进来 
            IERC20(crv).safeTransferFrom(msg.sender, address(this), _amount);
            //defer lock cost to another user  将锁定成本延迟给其他用户 （为什么要锁定成本 延迟付）
            uint256 callIncentive = _amount.mul(lockIncentive).div(FEE_DENOMINATOR);
            //剩余数量
            _amount = _amount.sub(callIncentive);

            //add to a pool for lock caller  延迟释放累加
            incentiveCrv = incentiveCrv.add(callIncentive);
        }

        //是否只存入  不另外stake
        bool depositOnly = _stakeAddress == address(0);
        if(depositOnly){
            //如果只是存入
            //mint for msg.sender
            //给用户cvxCRV 
            ITokenMinter(minter).mint(msg.sender,_amount);
        }else{
            //mint here   给这个合约 cvxCrv
            ITokenMinter(minter).mint(address(this),_amount);
            //stake for msg.sender
            IERC20(minter).safeApprove(_stakeAddress,0);
            IERC20(minter).safeApprove(_stakeAddress,_amount);
            //把 cvx staker 到 _stakeAddress
            IRewards(_stakeAddress).stakeFor(msg.sender,_amount);
        }
    }

    //只锁 不 stake
    function deposit(uint256 _amount, bool _lock) external {
        deposit(_amount,_lock,address(0));
    }

    //把 crv 转入 _stakeAddress
    function depositAll(bool _lock, address _stakeAddress) external{
        uint256 crvBal = IERC20(crv).balanceOf(msg.sender);
        deposit(crvBal,_lock,_stakeAddress);
    }
}