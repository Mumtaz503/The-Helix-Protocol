# InterestRateModel — Build Specification

*Helix Phase 1 · Kinked utilization curve · Swappable module · RAY per-second rates*

---

## Why this contract exists

`InterestRateModel` (IRM) answers one question for a single-asset market:

> **At the current pool utilization, what is the per-second borrow rate?**

`LendingPool` calls it inside `_accrueWithDebt()` **once per accrual**. The returned rate feeds `HelixMath.rayCompound()` to grow `borrowIndex`. The IRM does **not** move tokens, mint shares, or split reserve factor — that split lives in `LendingPool`.

**Upgradeability stance (Helix hybrid model):** IRM bytecode is **replaceable** via governance pointer swap on `LendingPool.interestRateModel`. Curve **parameters** (base, slopes, kink) are governance setters on the active IRM implementation, not an upgrade of `LendingPool` accounting.

---

## Relationship to LendingPool (READ THIS FIRST)

```text
User calls deposit / borrow / repay / …
        │
        ▼
LendingPool._accrueInterest()
        │
        ▼
LendingPool._accrueWithDebt(state, timeDelta)
        │
        ├─► IRM.getBorrowRate(totalSupplyAssets, totalBorrowAssets)  ← THIS CONTRACT
        │         returns borrowRatePerSecond (RAY)
        │
        ├─► newBorrowIndex = oldBorrowIndex × rayCompound(rate, timeDelta)   [floor]
        ├─► borrowInterest = newTotalBorrow − oldTotalBorrow                 [floor]
        ├─► reserves     += borrowInterest × reserveFactor / BASIS_POINTS  [floor]
        └─► suppliers    += borrowInterest − reserveIncrease                 [via supplyIndex]
```

**Reserve factor is NOT stored in the IRM.** It is a `LendingPool` parameter (`reserveFactor / BASIS_POINTS`). The IRM only prices **borrower** interest. Supplier yield is **derived**:

```text
impliedSupplyRatePerSecond ≈ borrowRatePerSecond × utilization × (1 − reserveFactor)
```

where `utilization = totalBorrowAssets / totalSupplyAssets` (see below).

---

## Precision & constants

| Symbol | Value | Meaning |
| :--- | :--- | :--- |
| `RAY` | `1e27` | 1.0 in 27-decimal fixed point (index / rate domain) |
| `WAD` | `1e18` | 1.0 in 18-decimal fixed point (utilization display) |
| `BASIS_POINTS` | `1e4` | 10_000 = 100%; 1000 = 10% reserve factor |
| `SECONDS_PER_YEAR` | `31_557_600` | 365.25 × 86400 (Julian year; document if changed) |

**Rate domain:**

- **Storage / constructor:** annual rates in **RAY** (APR-RAY), e.g. `4e25` = 4% APR.
- **`getBorrowRate` return:** **per-second** RAY (after `aprRayToPerSecond`), for pool accrual.

```text
ratePerSecond = floor( aprRay / SECONDS_PER_YEAR )
```

**Example:** 5% APR = `5e25` → per second ≈ `5e25 / 31_557_600 ≈ 1.585e18` RAY/sec.

---

## Utilization

```text
U = totalBorrowAssets / totalSupplyAssets    (WAD scale, floor division)
```

| Condition | Utilization | Borrow rate behavior |
| :--- | :--- | :--- |
| `totalSupplyAssets == 0` | undefined | return `baseRatePerSecond` (do not revert; pool has no suppliers) |
| `totalBorrowAssets == 0` | `0` | return `baseRatePerSecond` |
| `totalBorrowAssets >= totalSupplyAssets` | `≥ 1e18` (100%) | clamp to `maxRatePerSecond` if configured, else compute (may exceed kink) |

**Important:** `totalSupplyAssets` and `totalBorrowAssets` are **ledger totals** from `LendingPool` **after** the caller would accrue through the previous timestamp. The pool passes **current stored values**; accrual applies the rate for the elapsed `timeDelta` in one step (catch-up safe).

**Utilization in RAY** (internal, for slope math):

```text
U_ray = floor( totalBorrowAssets × RAY / totalSupplyAssets )
```

Use `U_ray` when multiplying by slopes stored in RAY/sec.

---

## Kinked rate curve (Compound-style)

Two-segment linear curve in utilization space.

### Parameters (immutable at deploy; governance-settable in Phase 3)

| Parameter | Type | Unit | Description |
| :--- | :--- | :--- | :--- |
| `baseAprRay` | `uint96` | APR-RAY | Rate when U = 0 |
| `slope1AprRay` | `uint96` | APR-RAY per 100% util | Rate increase below kink |
| `slope2AprRay` | `uint128` | APR-RAY per 100% util | Rate increase above kink (typically >> slope1) |
| `kink` | `uint64` | WAD | Utilization threshold (e.g. `0.8e18` = 80%) |
| `maxAprRay` | `uint128` | APR-RAY | Cap (`> 0` required) |

At runtime, each APR-RAY field is converted with `aprRayToPerSecond` before the kink formula.

### Math

Let `U` = utilization in WAD (`0 … WAD`).

**Below or at kink** (`U ≤ kink`):

```text
borrowRatePerSecond = baseRatePerSecond + floor( U × slope1PerSecond / WAD )
```

**Above kink** (`U > kink`):

```text
borrowRatePerSecond = baseRatePerSecond
                    + floor( kink × slope1PerSecond / WAD )
                    + floor( (U − kink) × slope2PerSecond / WAD )
```

**Cap (if `maxRatePerSecond != 0`):**

```text
borrowRatePerSecond = min(borrowRatePerSecond, maxRatePerSecond)
```

### Rounding policy (IRM-specific)

| Operation | Direction | Rationale |
| :--- | :--- | :--- |
| Utilization `U` | **down** | Pool size denominator — do not overstate utilization |
| Each slope term | **down** | Borrow rate never rounded up vs true real value |
| Cap `min()` | n/a | Safety ceiling |

Borrow rate rounded **down** pairs with `LendingPool` index advance rounded **down** — interest accrual stays in the protocol's favor in aggregate.

---

## Storage layout

**Committed model: Option B — store APR-RAY, expand to per-second at read.**

Strict budget: **≤3 storage slots** for IRM config. Implementation uses **2**; slot 3 reserved.

```solidity
// Slot 0 (256 bits): 96 + 96 + 64
struct RateParams {
    uint96 baseAprRay;      // annual RAY (e.g. 0)
    uint96 slope1AprRay;    // annual RAY per 100% util below kink (e.g. 4e25 = 4%)
    uint64 kink;            // WAD (e.g. 0.8e18 = 80%)
}

// Slot 1 (256 bits): 128 + 128
struct SteepParams {
    uint128 slope2AprRay;   // annual RAY above kink (e.g. 75e25 = 75%)
    uint128 maxAprRay;      // annual cap (e.g. 300e25 = 300%); must be > 0
}
// Slot 2: reserved
```

**Why APR-RAY (not per-second in storage):** packing per-second RAY into `uint64` overflows at ~58% APR. Spec needs 75% / 300%. Annual RAY (`4e25`, `75e25`, `300e25`) fits `uint96` / `uint128`.

**Runtime conversion** (`HelixMath.aprRayToPerSecond`):

```text
ratePerSecond = floor(aprRay / SECONDS_PER_YEAR)   // SECONDS_PER_YEAR = 31_557_600
```

`getBorrowRate` still returns **per-second RAY** for `LendingPool` accrual — only storage units changed.

**Validation:** `require(x <= type(T).max)` before cast — never bitwise-mask oversized values.

**Storage rule:** `baseAprRay` may be `0`; `maxAprRay == 0` is **invalid** (constructor requires `maxAprRay > 0`).

---

## Interface (frozen — pool depends on this)

File: `interfaces/IInterestRateModel.sol`

```solidity
function getBorrowRate(
    uint256 totalSupplyAssets,
    uint256 totalBorrowAssets
) external view returns (uint256 borrowRatePerSecond);
```

- **Must not revert** on zero supply (return `baseRatePerSecond`).
- **Must be view** (no state change).
- **Must be deterministic** given pool totals and block context (no `block.timestamp` inside IRM for MVP — rate is instant util snapshot; compounding happens in pool).

---

## Contract: `InterestRateModel.sol`

### Inheritance

```text
InterestRateModel is IInterestRateModel
```

Concrete implementation (not abstract in production). `MockInterestRateModel` remains for tests with flat rate.

---

### Constructor

```solidity
constructor(
    uint256 baseAprRay_,      // annual RAY
    uint256 slope1AprRay_,    // annual RAY
    uint256 slope2AprRay_,    // annual RAY
    uint256 kink_,            // WAD
    uint256 maxAprRay_        // annual RAY; must be > 0
)
```

**Validation (revert if violated):**

- `kink_ <= WAD`
- `baseAprRay_`, `slope1AprRay_` fit in `uint96`
- `slope2AprRay_`, `maxAprRay_` fit in `uint128`
- `slope2AprRay_ >= slope1AprRay_`
- `maxAprRay_ > 0 && maxAprRay_ >= baseAprRay_`

**Example deployment (USDC market — rates independent of token decimals):**

| Param | Human | Stored (APR-RAY) |
| :--- | :--- | :--- |
| base | 0% APR | `0` |
| slope1 | 4% APR per 100% util below kink | `4e25` |
| slope2 | 75% APR per 100% util above kink | `75e25` |
| kink | 80% | `0.8e18` |
| max | 300% APR cap | `300e25` |

Hot path expands: `aprRayToPerSecond(4e25) ≈ 1.267e18` RAY/sec.

---

### `getBorrowRate(totalSupplyAssets, totalBorrowAssets)`

**Purpose:** Primary pool entry point.

**Algorithm:**

1. If `totalBorrowAssets == 0` → return `baseRatePerSecond`.
2. If `totalSupplyAssets == 0` → return `baseRatePerSecond` (edge: borrows without supply should not happen in healthy pool; still deterministic).
3. Compute `U = (totalBorrowAssets * WAD) / totalSupplyAssets` (floor).
4. Apply kinked formula (§ Kinked rate curve).
5. Apply cap if enabled.
6. Return `borrowRatePerSecond`.

**Gas notes:**

- Single code path; use branch on `U <= kink` (SWITCH style), not nested chains.
- Cache `totalSupplyAssets`, `totalBorrowAssets` in stack once.
- No external calls.
- No events.

---

### `getUtilization(totalSupplyAssets, totalBorrowAssets)` (view, recommended)

**Purpose:** Off-chain dashboards, keeper bots, subgraph.

```solidity
function getUtilization(
    uint256 totalSupplyAssets,
    uint256 totalBorrowAssets
) external pure returns (uint256 utilizationWad);
```

Returns `0` if `totalSupplyAssets == 0`; else floor ratio in WAD.

---

### `getSupplyRate(totalSupplyAssets, totalBorrowAssets, reserveFactorBps)` (view, recommended)

**Purpose:** Display APY to suppliers. **Not called by pool on-chain** (reserve factor lives on pool).

```text
borrowRate = getBorrowRate(supply, borrow)
U          = utilizationWad
supplyRate = floor( borrowRate × U / WAD × (BASIS_POINTS − reserveFactorBps) / BASIS_POINTS )
```

Each multiply/divide floors.

**Example:** borrowRate = `1e16` RAY/sec (illustrative), U = 80%, reserve = 10%  
→ supplyRate ≈ `1e16 × 0.8 × 0.9 = 7.2e15` RAY/sec.

---

### `getBorrowRateAtUtilization(uint256 utilizationWad)` (view, recommended)

**Purpose:** Pure curve preview without needing pool totals.

Same kink math with `U = min(utilizationWad, WAD)`.

---

### Governance setters (Phase 3 — specify now, implement when timelock exists)

| Function | Auth | Notes |
| :--- | :--- | :--- |
| `setBaseRatePerSecond(uint256)` | timelock | Re-validate uint64 bound |
| `setSlope1PerSecond(uint256)` | timelock | |
| `setSlope2PerSecond(uint256)` | timelock | |
| `setKink(uint256)` | timelock | `≤ WAD` |
| `setMaxRatePerSecond(uint256)` | timelock | |

**Hard rule:** module swap or param change **must not** rewrite historical indexes. Only forward accruals change.

---

## Walkthrough examples (Foundry mental model)

### Example A — Flat region below kink

**Setup:**

- `base = 0`
- `slope1` = 4% APR equivalent per-second
- `kink = 0.8e18`
- `totalSupplyAssets = 1_000_000e6`
- `totalBorrowAssets = 400_000e6` → U = 40%

**Call:** `getBorrowRate(1_000_000e6, 400_000e6)`

**Expect:**

```text
borrowRate ≈ 0 + slope1 × 0.4
           ≈ 40% of slope1 segment maximum
```

**FAST FORWARD 1 day in EVM, accrue in pool:**

- Pool calls same rate (util unchanged if no user ops).
- `borrowIndex` grows by ≈ `(1 + rate)^86400` via `rayCompound` (binary exponentiation, ~17 loops).
- On 500k USDC borrowed at ~5% APR, expect ~68 USDC interest/day order-of-magnitude (see `AccrueInterest.t.sol`).

---

### Example B — Above kink (steep region)

**Setup:**

- Same curve; `totalBorrowAssets = 900_000e6`, `totalSupplyAssets = 1_000_000e6` → U = 90%

**Call:** `getBorrowRate(...)`

**Expect:**

```text
borrowRate = base + kink×slope1 + (0.9 − 0.8)×slope2
           = base + 0.8×slope1 + 0.1×slope2
```

Rate ** jumps** from slope1 to slope2 contribution above 80% util — this is the “kink”.

---

### Example C — Zero borrows

**Setup:** `totalBorrowAssets = 0`, any supply.

**Call:** `getBorrowRate(1e12, 0)`

**Expect:** `baseRatePerSecond` exactly (often `0` in production).

Pool skips IRM call entirely when `totalBorrowAssets == 0` (gas opt in `LendingPool`) — IRM must still be correct if called.

---

### Example D — Reserve factor split (pool, not IRM)

**Setup:**

- Borrow interest accrued in one accrual = `1000` (underlying units)
- `reserveFactor = 1000` (10%)

**Expect in pool:**

```text
reserves      += 100
supplyInterest = 900   → supplyIndex bump
```

Supplier APY < borrower APY even at 100% util because of reserve slice.

---

## Implied APY helpers (off-chain or view)

Convert per-second RAY to approximate APR for UI:

```text
APR_ray ≈ borrowRatePerSecond × SECONDS_PER_YEAR   (floor — underestimate OK for display)
APR_pct ≈ APR_ray / RAY × 100
```

Exact compounding over a year differs slightly due to truncation; UI should label “approx APR”.

---

## Invariants & fuzz targets

1. **Monotonicity in utilization:** holding supply fixed, `getBorrowRate` is non-decreasing as borrow increases.
2. **Kink continuity (optional):** at `U = kink`, both branches produce the same rate (design slopes accordingly).
3. **Zero borrow:** rate = base.
4. **Cap:** rate ≤ `maxRatePerSecond` when cap enabled.
5. **Determinism:** same inputs → same rate; no timestamp dependency in MVP.
6. **Bounded rates:** rate fits in uint256 after cap; no overflow in slope math if inputs bounded by governance.

**Integration invariants (pool + IRM):**

7. After accrual with flat IRM mock, `borrowIndex` non-decreasing.
8. Idempotent accrual same block (pool rule) — IRM may be called twice in tests but index must not double-advance (pool guards timestamp).

---

## Test requirements

### Unit (`test/unit/InterestRateModel.t.sol`)

| Test | Assert |
| :--- | :--- |
| `test_rateAtZeroUtil` | equals base |
| `test_rateBelowKink_linear` | matches formula at 40%, 80% |
| `test_rateAboveKink_steep` | slope2 dominates |
| `test_rateAt100Util` | U = WAD |
| `test_zeroSupply_returnsBase` | no revert |
| `test_capEnforced` | rate ≤ max |
| `test_getSupplyRate_reserveSplit` | 90% of borrow share when RF=10%, U=100% |

### Fuzz

- Random `(supply, borrow)` with borrow ≤ supply; monotonicity.
- Random util in WAD for `getBorrowRateAtUtilization`; never overflow.

### Integration (existing)

- `AccrueInterest.t.sol` continues using `MockInterestRateModel`; add one test with real kinked IRM once implemented.

---

## Gas / implementation checklist 

- [ ] **No events** on `getBorrowRate` (hot path).
- [ ] **Pure/view math** — no external calls inside IRM.
- [ ] **Packed `RateParams` + `SteepParams`** in 2 slots (APR-RAY Option B); slot 3 reserved.
- [ ] **`aprRayToPerSecond`** in HelixMath; constructor takes APR-RAY.
- [ ] **`!= 0` guards** before divide where denominator can be zero.
- [ ] **Named returns** on internal helpers (`utilizationWad`, `borrowRatePerSecond`).
- [ ] **Floor divisions** only (protocol favor).
- [ ] **Do not multiply by powers of 2** for time — compounding stays in `HelixMath.rayCompound` in pool.
- [ ] **Centralize constants** in `HelixLib.sol` (`RAY`, `WAD`, `BASIS_POINTS`, `SECONDS_PER_YEAR`).
- [ ] **IRM address** stored on pool, not duplicated inside IRM.
- [ ] **Callable sparingly** — pool calls once per accrual; IRM stays O(1).

---

## File map (target)

```text
contracts/src/
├── interfaces/IInterestRateModel.sol   ← frozen API
├── InterestRateModel.sol               ← kinked implementation
├── mocks/MockInterestRateModel.sol     ← flat rate for accrual tests
└── libraries/HelixMath.sol             ← compounding (used by pool, not IRM)
```

---

## Open decisions (resolve before coding)

| # | Question | Recommendation |
| :--- | :--- | :--- |
| 1 | `SECONDS_PER_YEAR` = 365 vs 365.25? | **365.25** (`31_557_600`) — match existing test constant |
| 2 | Revert if `borrow > supply`? | **No revert** — compute U > 100%; cap rate with `maxRatePerSecond` |
| 3 | Supply rate function on IRM vs off-chain SDK? | **View on IRM** for subgraph/keeper convenience |
| 4 | Abstract vs concrete base class? | **Concrete** `InterestRateModel`; delete broken abstract stub |


---

*Spec version: Phase 1 · aligns with `helix_protocol_spec.md` and `LendingPool._accrueWithDebt` as implemented.*
