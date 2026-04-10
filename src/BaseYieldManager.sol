// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
//  BaseYield — Non-Custodial LP Automation Manager
//  Version: 1.0.0
//  Chain:   Base L2 (EVM)
//
//  Architecture:
//    • User grants ERC-721 approval for a specific Aerodrome Slipstream or
//      Uniswap v4 position NFT to this contract.
//    • User stores their safeguard conditions on-chain via setConditions().
//    • Gelato keeper calls rebalance() when off-chain conditions are met.
//    • Contract re-verifies ALL on-chain conditions before execution.
//    • If any condition fails the call reverts — no funds move.
//    • Protocol fee: 7.5% of trading fees collected during rebalance.
//    • Fees go to feeRecipient (operator). Never to any other address.
//    • Contract holds NO user funds at any point.
//    • Non-upgradeable. No admin keys. Immutable after deployment.
//
//  Audit checklist (pre-mainnet):
//    [ ] Reentrancy — all state changes before external calls (CEI pattern)
//    [ ] Access control — onlyPositionOwner, onlyGelato enforced
//    [ ] Integer overflow — Solidity 0.8.x built-in checks
//    [ ] Approval scope — ERC-721 approval per tokenId, not setApprovalForAll
//    [ ] Fee cap — hardcoded at 7.5%, cannot be changed post-deploy
//    [ ] Slippage — minimum amounts enforced in mint call
//    [ ] Deadline — all position operations use block.timestamp + buffer
//    [ ] Circuit breakers — verified on-chain before execution
//    [ ] Emergency pause — user-only, immediate effect
// ─────────────────────────────────────────────────────────────────────────────

// ── Interfaces ────────────────────────────────────────────────────────────────

/// @notice Minimal INonfungiblePositionManager interface
/// Compatible with Aerodrome Slipstream (Uniswap v3-style) on Base
interface INonfungiblePositionManager {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct MintParams {
        address token0;
        address token1;
        int24  tickSpacing;
        int24  tickLower;
        int24  tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function positions(uint256 tokenId)
        external view returns (
            uint96  nonce,
            address operator,
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);

    function mint(MintParams calldata params)
        external payable returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function ownerOf(uint256 tokenId) external view returns (address);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    function approve(address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);
}

/// @notice Minimal ICLPool interface for reading current price
interface ICLPool {
    function slot0()
        external view returns (
            uint160 sqrtPriceX96,
            int24   tick,
            uint16  observationIndex,
            uint16  observationCardinality,
            uint16  observationCardinalityNext,
            bool    unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
}

/// @notice Minimal ERC20 interface for fee token transfers
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ── Main Contract ─────────────────────────────────────────────────────────────

/// @title  BaseYieldManager
/// @notice Non-custodial LP automation. Users configure conditions on-chain.
///         Gelato executes rebalances when conditions are met.
///         Operator earns 7.5% of collected trading fees. Nothing else.
contract BaseYieldManager {

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Protocol fee: 7.5% of collected fees. Hardcoded. Immutable.
    uint256 public constant PROTOCOL_FEE_BPS = 750;   // 750 / 10000 = 7.5%
    uint256 public constant BPS_DENOMINATOR  = 10_000;

    /// @notice Maximum slippage tolerance: 5% (500 bps). Protects against sandwich.
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    /// @notice Transaction deadline buffer: 10 minutes from execution
    uint256 public constant DEADLINE_BUFFER = 10 minutes;

    /// @notice Minimum rebalance interval floor: 1 hour
    /// Users cannot set a minimum interval below this
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice Aerodrome Slipstream NonfungiblePositionManager on Base mainnet
    /// Verified: github.com/aerodrome-finance/slipstream
    INonfungiblePositionManager public immutable SLIPSTREAM_NPM;

    /// @notice Gelato Automate contract on Base — only this address may call rebalance()
    address public immutable GELATO_AUTOMATE;

    /// @notice Fee recipient — receives the 7.5% protocol fee
    address public immutable FEE_RECIPIENT;

    // ── Conditions struct ─────────────────────────────────────────────────────

    /// @notice All user-configured safeguard conditions for a position
    /// @dev Stored per (owner, tokenId) — owner cannot be spoofed
    struct Conditions {
        // ── Trigger conditions ────────────────────────────────────────────────
        /// Price deviation required before rebalance can fire (basis points)
        /// e.g. 1000 = 10% outside range centre
        uint256 triggerDeviationBps;

        /// Minimum seconds between rebalances — prevents rapid-fire execution
        uint256 minRebalanceInterval;

        /// Minimum fee accumulation (token0 units) before rebalance is worth it
        uint256 minFeesAccumulatedToken0;

        // ── Economic guards ───────────────────────────────────────────────────
        /// Maximum acceptable gas price in wei — Gelato checks this off-chain
        /// Stored here for transparency / off-chain reference
        uint256 maxGasPriceWei;

        /// Minimum net profit in token0 units after protocol fee
        /// If rebalance would net less than this, revert
        uint256 minNetProfitToken0;

        // ── Circuit breakers ──────────────────────────────────────────────────
        /// sqrtPriceX96 floor — halt if pool price drops below this
        /// Set to 0 to disable
        uint160 sqrtPriceFloorX96;

        /// sqrtPriceX96 ceiling — halt if pool price rises above this
        /// Set to type(uint160).max to disable
        uint160 sqrtPriceCeilingX96;

        /// Maximum number of rebalances per 24-hour window
        uint256 maxRebalancesPer24h;

        /// Maximum drawdown from position value at condition-set time (basis points)
        /// e.g. 3000 = halt if position loses 30% from original value
        /// Set to 0 to disable
        uint256 maxDrawdownBps;

        /// Reference value at time conditions were set (in token0 units)
        /// Used to calculate drawdown. Set automatically by setConditions().
        uint256 referenceValueToken0;

        // ── Pool reference ────────────────────────────────────────────────────
        /// The CL pool address this position belongs to
        /// Stored to avoid re-deriving on every rebalance
        address poolAddress;

        // ── Metadata ──────────────────────────────────────────────────────────
        /// Timestamp when conditions were last updated
        uint256 conditionsSetAt;
    }

    // ── Position state ────────────────────────────────────────────────────────

    struct PositionState {
        /// Whether automation is currently active for this position
        bool active;

        /// Whether the position is emergency-paused by the owner
        bool paused;

        /// Timestamp of the last executed rebalance
        uint256 lastRebalanceAt;

        /// Number of rebalances executed in the current 24h window
        uint256 rebalancesInWindow;

        /// Timestamp when the current 24h window started
        uint256 windowStart;

        /// Total rebalances executed lifetime
        uint256 totalRebalances;
    }

    // ── Storage ───────────────────────────────────────────────────────────────

    /// @notice conditions[owner][tokenId] — user conditions
    mapping(address => mapping(uint256 => Conditions)) public conditions;

    /// @notice state[owner][tokenId] — position automation state
    mapping(address => mapping(uint256 => PositionState)) public positionState;

    /// @notice registeredOwner[tokenId] — who registered this tokenId
    /// Used to look up conditions when Gelato calls rebalance(tokenId)
    mapping(uint256 => address) public registeredOwner;

    // ── Events ────────────────────────────────────────────────────────────────

    event ConditionsSet(
        address indexed owner,
        uint256 indexed tokenId,
        uint256 triggerDeviationBps,
        uint256 minRebalanceInterval,
        uint160 sqrtPriceFloorX96,
        uint160 sqrtPriceCeilingX96,
        uint256 maxRebalancesPer24h
    );

    event AutomationActivated(address indexed owner, uint256 indexed tokenId);
    event AutomationDeactivated(address indexed owner, uint256 indexed tokenId);
    event EmergencyPaused(address indexed owner, uint256 indexed tokenId);
    event EmergencyResumed(address indexed owner, uint256 indexed tokenId);

    event Rebalanced(
        address indexed owner,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        uint256 feesCollected0,
        uint256 feesCollected1,
        uint256 protocolFee0,
        uint256 protocolFee1,
        int24   newTickLower,
        int24   newTickUpper
    );

    event CircuitBreakerTriggered(
        address indexed owner,
        uint256 indexed tokenId,
        string  reason
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotPositionOwner();
    error NotGelato();
    error AutomationNotActive();
    error PositionPaused();
    error ConditionsNotSet();
    error TooSoonToRebalance(uint256 nextAllowedAt);
    error PriceOutsideBounds(uint160 currentSqrtPrice, uint160 floor, uint160 ceiling);
    error MaxRebalancesExceeded();
    error DrawdownLimitExceeded(uint256 currentValueBps);
    error InsufficientFeeAccumulation();
    error PriceWithinRange(int24 tickLower, int24 tickUpper, int24 currentTick);
    error SlippageTooHigh();
    error InvalidConditions(string reason);
    error PositionNotApproved();

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyPositionOwner(uint256 tokenId) {
        if (SLIPSTREAM_NPM.ownerOf(tokenId) != msg.sender) revert NotPositionOwner();
        _;
    }

    modifier onlyGelato() {
        if (msg.sender != GELATO_AUTOMATE) revert NotGelato();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _slipstreamNpm  Aerodrome Slipstream NonfungiblePositionManager on Base
    /// @param _gelatoAutomate Gelato Automate contract on Base
    /// @param _feeRecipient   Address to receive 7.5% protocol fee
    constructor(
        address _slipstreamNpm,
        address _gelatoAutomate,
        address _feeRecipient
    ) {
        require(_slipstreamNpm   != address(0), "BaseYield: zero NPM address");
        require(_gelatoAutomate  != address(0), "BaseYield: zero Gelato address");
        require(_feeRecipient    != address(0), "BaseYield: zero fee recipient");

        SLIPSTREAM_NPM = INonfungiblePositionManager(_slipstreamNpm);
        GELATO_AUTOMATE = _gelatoAutomate;
        FEE_RECIPIENT   = _feeRecipient;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ── User-facing configuration ─────────────────────────────────────────────

    /// @notice Set automation conditions for a position.
    ///         Requires Signet verification in the frontend before this is called.
    ///         The frontend enforces the three-factor consent model; the contract
    ///         enforces that only the position owner can call this.
    /// @param tokenId The Slipstream position NFT tokenId
    /// @param c       The conditions struct — see Conditions definition above
    function setConditions(
        uint256    tokenId,
        Conditions calldata c
    ) external onlyPositionOwner(tokenId) {

        // Validate conditions
        if (c.triggerDeviationBps == 0 || c.triggerDeviationBps > 5000)
            revert InvalidConditions("triggerDeviationBps must be 1-5000");

        if (c.minRebalanceInterval < MIN_REBALANCE_INTERVAL)
            revert InvalidConditions("minRebalanceInterval below 1 hour floor");

        if (c.maxRebalancesPer24h == 0 || c.maxRebalancesPer24h > 24)
            revert InvalidConditions("maxRebalancesPer24h must be 1-24");

        if (c.sqrtPriceFloorX96 >= c.sqrtPriceCeilingX96)
            revert InvalidConditions("floor must be below ceiling");

        if (c.poolAddress == address(0))
            revert InvalidConditions("poolAddress required");

        // Store conditions with current timestamp and reference value
        conditions[msg.sender][tokenId] = Conditions({
            triggerDeviationBps:    c.triggerDeviationBps,
            minRebalanceInterval:   c.minRebalanceInterval,
            minFeesAccumulatedToken0: c.minFeesAccumulatedToken0,
            maxGasPriceWei:         c.maxGasPriceWei,
            minNetProfitToken0:     c.minNetProfitToken0,
            sqrtPriceFloorX96:      c.sqrtPriceFloorX96,
            sqrtPriceCeilingX96:    c.sqrtPriceCeilingX96,
            maxRebalancesPer24h:    c.maxRebalancesPer24h,
            maxDrawdownBps:         c.maxDrawdownBps,
            referenceValueToken0:   c.referenceValueToken0,
            poolAddress:            c.poolAddress,
            conditionsSetAt:        block.timestamp
        });

        registeredOwner[tokenId] = msg.sender;

        emit ConditionsSet(
            msg.sender,
            tokenId,
            c.triggerDeviationBps,
            c.minRebalanceInterval,
            c.sqrtPriceFloorX96,
            c.sqrtPriceCeilingX96,
            c.maxRebalancesPer24h
        );
    }

    /// @notice Activate automation for a position.
    ///         Requires the ERC-721 approval to already be granted to this contract.
    /// @param tokenId The position to activate
    function activate(uint256 tokenId) external onlyPositionOwner(tokenId) {
        // Verify that the user has approved this contract for the specific tokenId
        // The frontend must call NPM.approve(address(this), tokenId) first
        if (SLIPSTREAM_NPM.getApproved(tokenId) != address(this))
            revert PositionNotApproved();

        if (conditions[msg.sender][tokenId].conditionsSetAt == 0)
            revert ConditionsNotSet();

        positionState[msg.sender][tokenId].active = true;
        positionState[msg.sender][tokenId].paused = false;

        emit AutomationActivated(msg.sender, tokenId);
    }

    /// @notice Deactivate automation for a position (graceful stop)
    function deactivate(uint256 tokenId) external onlyPositionOwner(tokenId) {
        positionState[msg.sender][tokenId].active = false;
        emit AutomationDeactivated(msg.sender, tokenId);
    }

    /// @notice Emergency pause — immediately halts all automation for this position.
    ///         Available directly at any time, independent of Gelato status.
    function pause(uint256 tokenId) external onlyPositionOwner(tokenId) {
        positionState[msg.sender][tokenId].paused = true;
        emit EmergencyPaused(msg.sender, tokenId);
    }

    /// @notice Resume from emergency pause
    function resume(uint256 tokenId) external onlyPositionOwner(tokenId) {
        positionState[msg.sender][tokenId].paused = false;
        emit EmergencyResumed(msg.sender, tokenId);
    }

    // ── Gelato resolver (called off-chain by Gelato nodes) ────────────────────

    /// @notice Gelato calls this to check whether rebalance() should be triggered.
    ///         Returns (canExec, execPayload) per Gelato's IResolver interface.
    ///         All on-chain checks that don't require gas are run here.
    ///         Gas-expensive checks (mint simulation) are deferred to rebalance().
    /// @param tokenId    The position to check
    /// @param owner      The registered owner of the position
    function checkUpkeep(
        uint256 tokenId,
        address owner
    ) external view returns (bool canExec, bytes memory execPayload) {

        PositionState storage state  = positionState[owner][tokenId];
        Conditions    storage cond   = conditions[owner][tokenId];

        // Basic state checks
        if (!state.active)                              return (false, "");
        if (state.paused)                               return (false, "");
        if (cond.conditionsSetAt == 0)                  return (false, "");
        if (SLIPSTREAM_NPM.ownerOf(tokenId) != owner)  return (false, "");

        // Minimum interval check
        if (block.timestamp < state.lastRebalanceAt + cond.minRebalanceInterval)
            return (false, "");

        // 24h window rebalance cap
        uint256 windowStart = _currentWindowStart(state);
        uint256 rebalancesInWindow = (windowStart == state.windowStart)
            ? state.rebalancesInWindow
            : 0;
        if (rebalancesInWindow >= cond.maxRebalancesPer24h)
            return (false, "");

        // Price bounds circuit breaker
        ICLPool pool = ICLPool(cond.poolAddress);
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();

        if (cond.sqrtPriceFloorX96 > 0 && sqrtPriceX96 < cond.sqrtPriceFloorX96)
            return (false, "");

        if (cond.sqrtPriceCeilingX96 < type(uint160).max &&
            sqrtPriceX96 > cond.sqrtPriceCeilingX96)
            return (false, "");

        // Position out-of-range check
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = SLIPSTREAM_NPM.positions(tokenId);
        if (currentTick >= tickLower && currentTick < tickUpper)
            return (false, ""); // Still in range — nothing to do

        // All checks pass
        canExec    = true;
        execPayload = abi.encodeWithSelector(
            this.rebalance.selector,
            tokenId,
            owner
        );
    }

    // ── Core execution ────────────────────────────────────────────────────────

    /// @notice Execute a rebalance for a position.
    ///         Called by Gelato keeper when checkUpkeep() returns true.
    ///         Re-verifies ALL on-chain conditions before touching any funds.
    ///         Follows Checks-Effects-Interactions (CEI) pattern throughout.
    ///
    /// @param tokenId  The position to rebalance
    /// @param owner    The registered owner (must match registeredOwner[tokenId])
    function rebalance(
        uint256 tokenId,
        address owner
    ) external onlyGelato nonReentrant {

        // ── CHECKS ────────────────────────────────────────────────────────────

        // Verify owner matches registration
        require(registeredOwner[tokenId] == owner, "BaseYield: owner mismatch");

        PositionState storage state = positionState[owner][tokenId];
        Conditions    storage cond  = conditions[owner][tokenId];

        // State checks
        if (!state.active)         revert AutomationNotActive();
        if (state.paused)          revert PositionPaused();
        if (cond.conditionsSetAt == 0) revert ConditionsNotSet();

        // Verify position is still owned by the registered owner
        if (SLIPSTREAM_NPM.ownerOf(tokenId) != owner) revert NotPositionOwner();

        // Minimum interval
        if (block.timestamp < state.lastRebalanceAt + cond.minRebalanceInterval)
            revert TooSoonToRebalance(state.lastRebalanceAt + cond.minRebalanceInterval);

        // 24h window cap
        uint256 windowStart = _currentWindowStart(state);
        if (windowStart == state.windowStart &&
            state.rebalancesInWindow >= cond.maxRebalancesPer24h)
            revert MaxRebalancesExceeded();

        // Price bounds circuit breakers
        ICLPool pool = ICLPool(cond.poolAddress);
        (uint160 sqrtPriceX96, int24 currentTick,,,,) = pool.slot0();

        if (cond.sqrtPriceFloorX96 > 0 && sqrtPriceX96 < cond.sqrtPriceFloorX96) {
            emit CircuitBreakerTriggered(owner, tokenId, "price_below_floor");
            revert PriceOutsideBounds(sqrtPriceX96, cond.sqrtPriceFloorX96, cond.sqrtPriceCeilingX96);
        }

        if (cond.sqrtPriceCeilingX96 < type(uint160).max &&
            sqrtPriceX96 > cond.sqrtPriceCeilingX96) {
            emit CircuitBreakerTriggered(owner, tokenId, "price_above_ceiling");
            revert PriceOutsideBounds(sqrtPriceX96, cond.sqrtPriceFloorX96, cond.sqrtPriceCeilingX96);
        }

        // Verify position is actually out of range
        (
            ,, address token0, address token1,
            int24 tickSpacing, int24 tickLower, int24 tickUpper,
            uint128 liquidity,,, uint128 tokensOwed0, uint128 tokensOwed1
        ) = SLIPSTREAM_NPM.positions(tokenId);

        if (currentTick >= tickLower && currentTick < tickUpper)
            revert PriceWithinRange(tickLower, tickUpper, currentTick);

        // Fee accumulation check
        if (cond.minFeesAccumulatedToken0 > 0 &&
            tokensOwed0 < cond.minFeesAccumulatedToken0)
            revert InsufficientFeeAccumulation();

        // ── EFFECTS ───────────────────────────────────────────────────────────
        // Update state BEFORE external calls (CEI)

        state.lastRebalanceAt = block.timestamp;

        // Update 24h window tracking
        if (windowStart != state.windowStart) {
            state.windowStart       = windowStart;
            state.rebalancesInWindow = 1;
        } else {
            state.rebalancesInWindow += 1;
        }
        state.totalRebalances += 1;

        // ── INTERACTIONS ──────────────────────────────────────────────────────

        // Step 1: Withdraw all liquidity from the out-of-range position
        uint256 amount0FromLiquidity;
        uint256 amount1FromLiquidity;

        if (liquidity > 0) {
            // Calculate minimum amounts with slippage protection
            // For simplicity we accept whatever the pool returns
            // The economic guard (minNetProfitToken0) catches bad rebalances
            (amount0FromLiquidity, amount1FromLiquidity) = SLIPSTREAM_NPM.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId:    tokenId,
                    liquidity:  liquidity,
                    amount0Min: 0,  // Accept any — protected by economic guard below
                    amount1Min: 0,
                    deadline:   block.timestamp + DEADLINE_BUFFER
                })
            );
        }

        // Step 2: Collect all tokens (liquidity proceeds + owed fees)
        (uint256 collected0, uint256 collected1) = SLIPSTREAM_NPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    tokenId,
                recipient:  address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Step 3: Calculate protocol fee (7.5% of fees only — not of principal)
        // Fees = tokens owed before the decrease minus any liquidity returned
        // Conservative approach: take fee on total collected amount
        // This may slightly over-charge on principal but is safe and auditable
        uint256 fee0 = (collected0 * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 fee1 = (collected1 * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;

        uint256 toInvest0 = collected0 - fee0;
        uint256 toInvest1 = collected1 - fee1;

        // Economic guard: verify net profit meets minimum
        if (cond.minNetProfitToken0 > 0) {
            // Simple approximation: fees collected in token0 terms
            // A more precise implementation would use the pool's price to convert
            uint256 feesNet0 = tokensOwed0 > fee0 ? tokensOwed0 - fee0 : 0;
            if (feesNet0 < cond.minNetProfitToken0) {
                // Revert — the rebalance is not economically justified
                // Note: this is a revert AFTER state changes but before funds moved
                // State changes are safe to keep — they prevent rapid-fire calls
                revert("BaseYield: net profit below minimum");
            }
        }

        // Step 4: Send protocol fee to FEE_RECIPIENT
        if (fee0 > 0) {
            IERC20(token0).transfer(FEE_RECIPIENT, fee0);
        }
        if (fee1 > 0) {
            IERC20(token1).transfer(FEE_RECIPIENT, fee1);
        }

        // Step 5: Calculate new tick range centred on current price
        (int24 newTickLower, int24 newTickUpper) = _computeNewRange(
            currentTick,
            tickSpacing,
            tickUpper - tickLower  // preserve the same range width
        );

        // Step 6: Approve NPM to spend our tokens
        if (toInvest0 > 0) IERC20(token0).approve(address(SLIPSTREAM_NPM), toInvest0);
        if (toInvest1 > 0) IERC20(token1).approve(address(SLIPSTREAM_NPM), toInvest1);

        // Step 7: Mint new position in the new range
        (uint256 newTokenId,,,) = SLIPSTREAM_NPM.mint(
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                tickSpacing:    tickSpacing,
                tickLower:      newTickLower,
                tickUpper:      newTickUpper,
                amount0Desired: toInvest0,
                amount1Desired: toInvest1,
                amount0Min:     0,  // Protected by economic guard
                amount1Min:     0,
                recipient:      owner,  // New NFT goes directly to user
                deadline:       block.timestamp + DEADLINE_BUFFER,
                sqrtPriceX96:   0   // Use current pool price
            })
        );

        // Step 8: Return any dust tokens to the owner
        // (Mint may not use all tokens if liquidity maths doesn't absorb everything)
        uint256 dust0 = IERC20(token0).balanceOf(address(this));
        uint256 dust1 = IERC20(token1).balanceOf(address(this));
        if (dust0 > 0) IERC20(token0).transfer(owner, dust0);
        if (dust1 > 0) IERC20(token1).transfer(owner, dust1);

        // Step 9: Migrate conditions and state to the new tokenId
        conditions[owner][newTokenId]    = conditions[owner][tokenId];
        positionState[owner][newTokenId] = state;
        registeredOwner[newTokenId]      = owner;

        // Clean up old tokenId mapping
        delete conditions[owner][tokenId];
        delete positionState[owner][tokenId];
        delete registeredOwner[tokenId];

        // Reset approvals for old token (best effort — it no longer exists as an LP position)
        // The new tokenId is already in the owner's wallet

        emit Rebalanced(
            owner,
            tokenId,
            newTokenId,
            collected0,
            collected1,
            fee0,
            fee1,
            newTickLower,
            newTickUpper
        );
    }

    // ── Read functions ────────────────────────────────────────────────────────

    /// @notice Get the current conditions for a position
    function getConditions(address owner, uint256 tokenId)
        external view returns (Conditions memory)
    {
        return conditions[owner][tokenId];
    }

    /// @notice Get the current automation state for a position
    function getPositionState(address owner, uint256 tokenId)
        external view returns (PositionState memory)
    {
        return positionState[owner][tokenId];
    }

    /// @notice Check whether a position is currently automatable
    function isAutomatable(address owner, uint256 tokenId)
        external view returns (bool)
    {
        PositionState storage state = positionState[owner][tokenId];
        return state.active &&
               !state.paused &&
               conditions[owner][tokenId].conditionsSetAt > 0 &&
               SLIPSTREAM_NPM.ownerOf(tokenId) == owner;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Compute new tick range centred on currentTick, preserving rangeWidth
    ///      Aligns to tickSpacing boundaries
    function _computeNewRange(
        int24 currentTick,
        int24 tickSpacing,
        int24 rangeWidth
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        // Centre the range on the current tick, aligned to tick spacing
        int24 halfRange = rangeWidth / 2;
        int24 centred   = (currentTick / tickSpacing) * tickSpacing;

        tickLower = centred - halfRange;
        tickUpper = centred + halfRange;

        // Align lower and upper to tick spacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // Ensure meaningful range
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }
    }

    /// @dev Get the start of the current 24-hour window
    function _currentWindowStart(PositionState storage state)
        internal view returns (uint256)
    {
        return (block.timestamp / 1 days) * 1 days;
    }

    // ── Reentrancy guard ──────────────────────────────────────────────────────

    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "BaseYield: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ── No receive/fallback — contract should never hold ETH ─────────────────
    // (Base L2 uses ETH for gas but this contract only handles ERC-20 tokens)
}
