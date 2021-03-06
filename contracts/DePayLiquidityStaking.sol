// SPDX-License-Identifier: MIT

pragma solidity >=0.7.5 <0.8.0;

import './interfaces/IDePayLiquidityStaking.sol';
import './interfaces/IUniswapV2Pair.sol';

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract DePayLiquidityStaking is IDePayLiquidityStaking, Ownable, ReentrancyGuard {
  
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Epoch time when staking starts: People are allowed to stake
  uint256 public override startTime;

  // Epoch time when staking has been closed: People are not allowed to stake anymore
  uint256 public override closeTime;

  // Epoch time when staking releases staked liquidity + rewards: People can withdrawal
  uint256 public override releaseTime;

  // Total amount of staking rewards available
  uint256 public override rewardsAmount;

  // Percentage Yield, will be divided by 100, e.g. set 80 for 80%
  uint256 public override percentageYield;

  // Total amount of already allocated staking rewards
  uint256 public override allocatedStakingRewards;

  // Address of the Uniswap liquidity pair (token)
  IUniswapV2Pair public override liquidityToken;

  // Address of the token used for rewards
  IERC20 public override token;

  // Indicating if unstaking early is allowed or not
  // This is used to upgrade liquidity to uniswap v3
  bool public override unstakeEarlyAllowed;

  // Stores all rewards per address
  mapping (address => uint256) public override rewardsPerAddress;

  // Stores all amounts of staked liquidity tokens per address
  mapping (address => uint256) public override stakedLiquidityTokenPerAddress;

  modifier onlyUnstarted() {
    require(
      startTime == 0 || block.timestamp < startTime,
      "Staking has already started!"
    );
    _;
  }

  modifier onlyStarted() {
    require(block.timestamp > startTime, "Staking has not yet started!");
    _;
  }

  modifier onlyUnclosed() {
    require(block.timestamp < closeTime, "Staking has been closed!");
    _;
  }

  modifier onlyReleasable() {
    require(block.timestamp > releaseTime, "Staking is not releasable yet!");
    _;
  }
  
  modifier onlyUnstakeEarly() {
    require(unstakeEarlyAllowed, "Unstaking early not allowed!");
    _;
  }

  modifier onlyDistributedRewards(){
    require(allocatedStakingRewards == 0, 'Rewards were not distributed yet!');
    _;
  }

  function init(
      uint256 _startTime,
      uint256 _closeTime,
      uint256 _releaseTime,
      uint256 _percentageYield,
      address _liquidityToken,
      address _token
  ) override external onlyOwner onlyUnstarted {
    require(isContract(_token), '_token address needs to be a contract!');
    require(isContract(_liquidityToken), '_liquidityToken address needs to be a contract!');
    require(_startTime < _closeTime && _closeTime < _releaseTime, '_startTime needs to be before _closeTime needs to be before _releaseTime!');
    startTime = _startTime;
    closeTime = _closeTime;
    releaseTime = _releaseTime;
    percentageYield = _percentageYield;
    liquidityToken = IUniswapV2Pair(_liquidityToken);
    token = IERC20(_token);
    rewardsAmount = token.balanceOf(address(this));
  }

  function stake(
    uint256 stakedLiquidityTokenAmount
  ) override external onlyStarted onlyUnclosed nonReentrant {
    require(
      liquidityToken.transferFrom(msg.sender, address(this), stakedLiquidityTokenAmount),
      'Depositing liquidity token failed!'
    );

    uint112 reserve0;
    uint112 reserve1;
    uint32 blockTimestampLast;
    (reserve0, reserve1, blockTimestampLast) = liquidityToken.getReserves();

    require(
      liquidityToken.token0() == address(token),
      'Rewards must be calculated based on the reward token reserve!'
    );

    uint256 rewards = stakedLiquidityTokenAmount
      .mul(reserve0)
      .div(liquidityToken.totalSupply())
      .mul(percentageYield)
      .div(100);

    rewardsPerAddress[msg.sender] = rewardsPerAddress[msg.sender].add(rewards);
    stakedLiquidityTokenPerAddress[msg.sender] = stakedLiquidityTokenPerAddress[msg.sender].add(stakedLiquidityTokenAmount);

    allocatedStakingRewards = allocatedStakingRewards.add(rewards);
    require(allocatedStakingRewards <= rewardsAmount, 'Staking overflows rewards!');
  }

  function payableOwner() view private returns(address payable) {
    return payable(owner());
  }
    
  function withdraw(
    address tokenAddress,
    uint amount
  ) override external onlyOwner nonReentrant {
    require(tokenAddress != address(liquidityToken), 'Not allowed to withdrawal liquidity tokens!');
    
    if(tokenAddress == address(token)) {
      require(
        allocatedStakingRewards <= token.balanceOf(address(this)).sub(amount),
        'Only unallocated staking rewards are allowed to be withdrawn for roll-over to next staking contract!'
      );
      rewardsAmount = rewardsAmount.sub(amount);
    }

    IERC20(tokenAddress).safeTransfer(payableOwner(), amount);
  }

  function _unstakeLiquidity() private {
    uint256 liquidityTokenAmount = stakedLiquidityTokenPerAddress[msg.sender];
    stakedLiquidityTokenPerAddress[msg.sender] = 0;
    require(
      liquidityToken.transfer(msg.sender, liquidityTokenAmount),
      'Unstaking liquidity token failed!'
    );
  }

  function _unstakeRewards() private {
    uint256 rewards = rewardsPerAddress[msg.sender];
    allocatedStakingRewards = allocatedStakingRewards.sub(rewards);
    rewardsPerAddress[msg.sender] = 0;
    require(
      token.transfer(msg.sender, rewards),
      'Unstaking rewards failed!'
    );
  }

  function unstake() override external onlyReleasable nonReentrant {
    _unstakeLiquidity();
    _unstakeRewards();
  }

  function enableUnstakeEarly() override external onlyOwner {
    unstakeEarlyAllowed = true;
  }

  function unstakeEarly() override external onlyUnstakeEarly nonReentrant {
    _unstakeLiquidity();
    allocatedStakingRewards = allocatedStakingRewards.sub(rewardsPerAddress[msg.sender]);
    rewardsPerAddress[msg.sender] = 0;
  }

  function isContract(address account) internal view returns (bool) {
    // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
    // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
    // for accounts without code, i.e. `keccak256('')`
    bytes32 codehash;
    bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    // solhint-disable-next-line no-inline-assembly
    assembly { codehash := extcodehash(account) }
    return (codehash != accountHash && codehash != 0x0);
  }

  function destroy() public onlyOwner onlyDistributedRewards {
    selfdestruct(payable(owner()));
  }
}
