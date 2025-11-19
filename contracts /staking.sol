// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol"; // keep for OZ <5; works on 4.9.x
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * SRF Staking (Hardened v1.1)
 * - Tracks totalStaked to protect depositor principal from being mixed with rewards.
 * - Rewards are paid only from "available rewards" = balanceOf(this) - totalStaked.
 * - Supports fee-on-transfer tokens by using actual received amount.
 * - APR is snapshotted per-position (no retroactive changes).
 * - Adds emergencyWithdraw (principal only) when paused.
 * - Guardrails on admin setters.
 */
contract SRFStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct TierInfo {
        uint64 lockDuration; // seconds
        uint16 aprBps;       // 10000 = 100%
    }

    struct StakePosition {
        uint256 amount;          // principal actually received
        address owner;           // staker
        uint64 start;            // start time
        uint64 lockEnd;          // unlock time
        uint64 lastClaim;        // last claimed timestamp
        uint8 tier;              // 0..3
        uint16 aprBpsAtStake;    // snapshot of APR at stake time
        bool withdrawn;          // principal withdrawn?
    }

    // Tier indices
    uint8 public constant TIER_BRONZE = 0; // 3 months
    uint8 public constant TIER_SILVER = 1; // 6 months
    uint8 public constant TIER_GOLD   = 2; // 12 months
    uint8 public constant TIER_DIAMOND= 3; // 18 months

    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant YEAR = 365 days;

    // Approximate months by 30-day windows (except 12m which uses 365 days)
    uint64 public constant THREE_MONTHS   = 90 days;
    uint64 public constant SIX_MONTHS     = 180 days;
    uint64 public constant TWELVE_MONTHS  = 365 days;
    uint64 public constant EIGHTEEN_MONTHS= 540 days;

    IERC20 public immutable stakingToken;   // SRF token
    address public saleContract;            // optional reference

    TierInfo[4] public tiers;               // current tier config (new stakes)

    uint64 public claimInterval = 30 days;  // default monthly claims
    uint64 public programEnd;               // if > 0, rewards stop accruing after this time

    uint256 public nextStakeId = 1;
    uint256 public totalStaked;             // sum of principals for all open positions

    mapping(uint256 => StakePosition) public stakes;      // stakeId => position
    mapping(address => uint256[]) private _userStakeIds;  // user => stakeIds

    // ===== Events =====
    event Staked(address indexed user, uint256 indexed stakeId, uint256 amount, uint8 tier, uint64 start, uint64 lockEnd);
    event Claimed(address indexed user, uint256 indexed stakeId, uint256 reward);
    event Withdrawn(address indexed user, uint256 indexed stakeId, uint256 principal);
    event EmergencyWithdraw(address indexed user, uint256 indexed stakeId, uint256 principal);
    event TierUpdated(uint8 indexed tier, uint64 lockDuration, uint16 aprBps);
    event ClaimIntervalUpdated(uint64 newInterval);
    event ProgramEndUpdated(uint64 newProgramEnd);
    event SaleContractUpdated(address saleContract);
    event RewardsFunded(address indexed from, uint256 amount);
    event RewardsRescued(address indexed to, uint256 amount);

    constructor(address _stakingToken, address _saleContract, address _owner) Ownable(_owner) {
        require(_stakingToken != address(0), "token=zero");
        stakingToken = IERC20(_stakingToken);
        saleContract = _saleContract;

        // default tiers per plan
        tiers[TIER_BRONZE]  = TierInfo({lockDuration: THREE_MONTHS,   aprBps: 600});  // 6%
        tiers[TIER_SILVER]  = TierInfo({lockDuration: SIX_MONTHS,     aprBps: 1000}); // 10%
        tiers[TIER_GOLD]    = TierInfo({lockDuration: TWELVE_MONTHS,  aprBps: 1400}); // 14%
        tiers[TIER_DIAMOND] = TierInfo({lockDuration: EIGHTEEN_MONTHS,aprBps: 1800}); // 18%
    }

    // ===== Admin =====
    function setTier(uint8 tierIndex, uint64 lockDuration, uint16 aprBps) external onlyOwner {
        require(tierIndex < 4, "tier");
        require(lockDuration > 0 && lockDuration <= 1825 days, "lockDuration"); // up to 5 years
        require(aprBps <= 5000, "apr-too-high"); // 50% cap (adjust as needed)
        tiers[tierIndex] = TierInfo({lockDuration: lockDuration, aprBps: aprBps});
        emit TierUpdated(tierIndex, lockDuration, aprBps);
    }

    function setClaimInterval(uint64 newInterval) external onlyOwner {
        require(newInterval > 0 && newInterval <= 90 days, "interval");
        claimInterval = newInterval;
        emit ClaimIntervalUpdated(newInterval);
    }

    function setProgramEnd(uint64 newProgramEnd) external onlyOwner {
        // 0 disables end cap
        require(newProgramEnd == 0 || newProgramEnd > block.timestamp, "past");
        programEnd = newProgramEnd;
        emit ProgramEndUpdated(newProgramEnd);
    }

    function setSaleContract(address _sale) external onlyOwner {
        saleContract = _sale;
        emit SaleContractUpdated(_sale);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * Optional: Use token transfer to fund rewards, then call this for an event trail.
     */
    function announceFunding(uint256 amountJustTransferred) external onlyOwner {
        emit RewardsFunded(_msgSender(), amountJustTransferred);
    }

    /**
     * Rescue only "excess" rewards (never depositor principal).
     */
    function rescueRewards(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=zero");
        uint256 bal = stakingToken.balanceOf(address(this));
        uint256 excess = bal > totalStaked ? bal - totalStaked : 0;
        require(amount <= excess, "exceeds excess rewards");
        stakingToken.safeTransfer(to, amount);
        emit RewardsRescued(to, amount);
    }

    // ===== User: Stake / Claim / Withdraw =====
    function stake(uint256 amount, uint8 tierIndex) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        require(amount > 0, "amount=0");
        require(tierIndex < 4, "tier");

        TierInfo memory t = tiers[tierIndex];
        uint64 start = uint64(block.timestamp);
        uint64 lockEnd = start + t.lockDuration;

        // Support fee-on-transfer: compute actual received
        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(_msgSender(), address(this), amount);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        require(received > 0, "received=0");

        stakeId = nextStakeId++;
        stakes[stakeId] = StakePosition({
            amount: received,
            owner: _msgSender(),
            start: start,
            lockEnd: lockEnd,
            lastClaim: start,
            tier: tierIndex,
            aprBpsAtStake: t.aprBps,
            withdrawn: false
        });
        _userStakeIds[_msgSender()].push(stakeId);

        totalStaked += received;
        emit Staked(_msgSender(), stakeId, received, tierIndex, start, lockEnd);
    }

    function claim(uint256 stakeId) public nonReentrant whenNotPaused returns (uint256 paid) {
        StakePosition storage sp = stakes[stakeId];
        require(sp.owner == _msgSender(), "not-owner");
        require(!sp.withdrawn, "withdrawn");

        uint256 endTime = _effectiveNow();
        require(endTime > sp.lastClaim, "nothing");

        uint256 reward = _accrued(sp, endTime);
        require(reward > 0, "reward=0");

        bool unlocked = endTime >= sp.lockEnd;
        bool intervalOk = (endTime - sp.lastClaim) >= claimInterval;
        require(intervalOk || unlocked || (programEnd > 0 && endTime >= programEnd), "too-soon");

        sp.lastClaim = uint64(endTime);
        paid = _payout(sp.owner, reward); // pay up to available rewards
        emit Claimed(sp.owner, stakeId, paid);
    }

    function withdraw(uint256 stakeId) external nonReentrant returns (uint256 principal, uint256 rewardPaid) {
        StakePosition storage sp = stakes[stakeId];
        require(sp.owner == _msgSender(), "not-owner");
        require(!sp.withdrawn, "withdrawn");
        require(block.timestamp >= sp.lockEnd, "locked");

        uint256 endTime = _effectiveNow();
        uint256 reward = _accrued(sp, endTime);
        if (reward > 0) {
            sp.lastClaim = uint64(endTime);
            rewardPaid = _payout(sp.owner, reward);
            emit Claimed(sp.owner, stakeId, rewardPaid);
        }

        sp.withdrawn = true;
        principal = sp.amount;
        totalStaked -= principal;
        stakingToken.safeTransfer(sp.owner, principal);
        emit Withdrawn(sp.owner, stakeId, principal);
    }

    /**
     * Emergency exit for users: withdraw principal only (no rewards).
     * Can be used when the contract is paused.
     */
    function emergencyWithdraw(uint256 stakeId) external nonReentrant whenPaused returns (uint256 principal) {
        StakePosition storage sp = stakes[stakeId];
        require(sp.owner == _msgSender(), "not-owner");
        require(!sp.withdrawn, "withdrawn");

        sp.withdrawn = true;
        principal = sp.amount;
        totalStaked -= principal;
        stakingToken.safeTransfer(sp.owner, principal);
        emit EmergencyWithdraw(sp.owner, stakeId, principal);
    }

    // ===== Views =====
    function getUserStakeIds(address user) external view returns (uint256[] memory) {
        return _userStakeIds[user];
    }

    function previewClaimable(uint256 stakeId) external view returns (uint256) {
        StakePosition storage sp = stakes[stakeId];
        if (sp.withdrawn || sp.owner == address(0)) return 0;
        uint256 endTime = _effectiveNow();
        if (endTime <= sp.lastClaim) return 0;
        return _accrued(sp, endTime);
    }

    function previewUnlockTime(uint256 stakeId) external view returns (uint64) {
        return stakes[stakeId].lockEnd;
    }

    function tierInfo(uint8 tierIndex) external view returns (uint64 lockDuration, uint16 aprBps) {
        TierInfo memory t = tiers[tierIndex];
        return (t.lockDuration, t.aprBps);
    }

    function availableRewards() public view returns (uint256) {
        uint256 bal = stakingToken.balanceOf(address(this));
        return bal > totalStaked ? bal - totalStaked : 0;
    }

    function totalPrincipal() external view returns (uint256) {
        return totalStaked;
    }

    // ===== Internals =====
    function _effectiveNow() internal view returns (uint256) {
        if (programEnd == 0) return block.timestamp;
        return block.timestamp < programEnd ? block.timestamp : programEnd;
    }

    function _accrued(StakePosition storage sp, uint256 endTime) internal view returns (uint256) {
        if (endTime <= sp.lastClaim) return 0;
        uint256 elapsed = endTime - uint256(sp.lastClaim);
        // reward = amount * APR * elapsed / YEAR
        return (sp.amount * sp.aprBpsAtStake * elapsed) / (BPS_DENOM * YEAR);
    }

    function _payout(address to, uint256 amount) internal returns (uint256 paid) {
        uint256 avail = availableRewards();
        if (amount == 0 || avail == 0) return 0;
        paid = amount <= avail ? amount : avail; // cap to available rewards
        if (paid > 0) stakingToken.safeTransfer(to, paid);
    }
}
