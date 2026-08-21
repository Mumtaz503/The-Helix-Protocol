# Helix Protocol — Build Specification
*A cross-margin lending & liquidation protocol with Dutch-auction liquidations, adaptive risk parameters, dynamic risk-adjusted interest rates, and full off-chain infrastructure.*

---

## Why This Project

This is designed to hit the same complexity class as the most complex DeFi projects in the space — multiple interacting precision domains, storage-packing constraints, adversarial edge cases that only surface under fuzzing — but in the lending/liquidation/derivatives domain, which is directly what Aave, Compound, Morpho, Lista, and Variational all explore. Every hard design decision here maps to a solid understanding of DeFi infrastructure.

The differentiator is **not** the Dutch auction (see prior art below). It's the adaptive risk layer in Phase 3 and the permissionless bounty design in Phase 2, both almost unheard of in mainstream lending protocols.

---

## Core Concept

A lending protocol where liquidations are resolved via **on-chain Dutch auctions** instead of fixed liquidation bonuses. This is harder than a standard liquidation engine (AAVE/Compound style) because:

- The liquidation discount is *dynamic* — it starts low and increases every block until a liquidator takes it, which requires careful gas-efficient on-chain price-decay math
- Auction manipulation (self-liquidation for profit, flash-loan sniping at the worst possible decay point) must be prevented
- Partial fills must be supported without breaking auction state for the remaining collateral

### Prior art — read this before you build

Dutch-auction liquidation is a solved problem in production. Read these first so you can articulate how Helix differs:

- **Maker LIQ 2.0** — `Clipper.sol` (auction lifecycle, partial fills, `take` mechanics) and the `Abacus` contracts, especially `StairstepExponentialDecrease`. This is the reference implementation of exponential on-chain price decay and it solves the gas problem flagged as "more interesting."
- **Ajna** — oracle-less lending with auction-based liquidation, useful as a contrast in how much you can remove.

Being able to say "Clipper does X, I do Y because Z" is worth more than the auction itself.

---

## Cross-Cutting Design Rules

These apply to every contract and should be written down before Phase 1 starts. Most real lending bugs live here, not in the business logic.

### Rounding policy

Every division must round in the protocol's favor. Decide this once, document it in a table, and enforce it with tests. Most complex protocols do this explicitly — their formulas use something like `FLOOR` and `CEILING` at every division, and the `CEILING` on late fees exists specifically so a position holding 1 atomic unit still accrues a nonzero fee rather than rounding to free.

| Operation | Direction | Rationale |
| :--- | :--- | :--- |
| Borrow shares minted | **up** | Borrower owes at least what they drew |
| Repay shares burned | **down** | Repayment never over-credits |
| Supply shares minted | **down** | Depositor receives no more than they paid for |
| Withdraw shares burned | **up** | Withdrawal never over-redeems |
| Collateral seized on liquidation | **down** | Liquidator never over-collects |
| Debt cleared by liquidation | **down** | Dust stays as protocol-owed |
| Interest index advance | **down** | See note |

**Interest index note:** round the index down (truncate). Rounding it up compounds, and any function that advances it must be idempotent within a single timestamp — otherwise repeated `accrue()` calls in the same block can ratchet debt upward. Test this explicitly.

**Invariant:** no user-facing operation, repeated any number of times, can leave the caller with more value than they started with. This is the fuzz target that catches rounding leaks.

### First-depositor / share inflation attack

Share-based accounting plus an empty pool is the classic ERC-4626 donation attack: first depositor mints 1 wei of shares, donates directly to the pool, and every subsequent depositor's shares round to zero. Pick one mitigation and state it:

- Virtual shares and virtual assets (OpenZeppelin ERC-4626 approach), **or**
- Dead-shares seed minted to address(0) at market initialization

We'll continue with the ERC-4626 approach at Market Initialization approach for now. (Research Needed)

### Dust / debt floor

Enforce a minimum borrow size per market (Maker calls this `dust`). Without it we get positions too small to liquidate profitably — gas exceeds the liquidation bonus — which become permanent uncollectable bad debt. Also enforce that a partial liquidation cannot leave a position *below* the floor; it must either stay above it or be fully closed.

Phase 2 fuzzer will find the unprofitable-liquidation size immediately if we skip this.

### Token compatibility policy

State it explicitly and enforce it:

- **Fee-on-transfer** — unsupported, or measure balance delta rather than trusting the transfer amount
- **Rebasing** — unsupported; balances desync from share accounting silently
- **ERC-777 / callback tokens** — this is real reentrancy surface, especially in Phase 2 where partial fills transfer to arbitrary liquidator addresses

We don't need a new standard, but we do need a written policy.

*What Helix should do*
Default: unsupported for listed markets. Do not list FoT assets as collateral or borrowables.

Why that fits Helix better than “support via balance deltas”:

- **Share accounting** — deposit/borrow shares assume Δassets matches the user’s intent. FoT forces every path to measure balance before/after and mint/burn on the received amount, which is easy to get wrong on repay, liquidate, and partial auction fills.
- **Dutch auction + partial fills** — liquidator pays debt and receives collateral in multiple transfers. A tax on either leg desyncs “debt cleared” vs “collateral seized” and can leave the position under- or over-closed relative to health factor.
- **Production story** — Aave/Compound-class protocols mostly whitelist assets and refuse FoT. Supporting FoT is a niche Morpho/weird-asset problem, not the complexity we want Helix known for.

### Upgradeability stance

Take an explicit position and justify it. Genius is deliberately immutable with no admin key, and V2 ships as an entirely separate deployment with a `Migration.sol` handling the V1→V2 path. Having worked on that, you can speak to the tradeoff credibly.

If you choose immutable, sketch the migration story now. If you choose upgradeable, document exactly which storage layout constraints you're committing to.

---

## Phase 1 — Core Lending Primitives (Smart Contracts)

**Contracts to build:**
- `LendingPool.sol` — deposits, withdrawals, borrow, repay
- `InterestRateModel.sol` — kinked rate model (you already designed this conceptually in your Compound interview — now implement it), **including a reserve factor**: the slice of borrower interest that accrues to protocol reserves rather than suppliers. This funds the bad-debt backstop in Phase 2, so it can't be an afterthought.
- `CollateralManager.sol` — isolated + cross-margin position tracking
- `OracleAggregator.sol` — Chainlink primary feed + TWAP fallback with staleness checks

**Design constraints to enforce (this is where the Genius-level difficulty comes from):**

- Borrow index compounds via a global index rather than per-position updates every block (same pattern you described in your interview prep)

- **Catch-up accrual.** The index does not advance itself — someone has to poke it. If nobody touches a market for a month, the next interaction must compound a month of per-second interest in a single call. Naive looping runs out of gas. Use binary exponentiation of the per-second rate, or Aave's truncated-Taylor `calculateCompoundedInterest`, and document the precision-versus-gas tradeoff you chose.

  This is structurally the same problem the Genius Calendar solves: days don't roll automatically, and the tiered day/10/100/1000 summarization scheme exists so you can catch up from long idleness cheaply. Worth reading before you design yours.

- Pack each position's state (collateral amount, borrow shares, last interaction timestamp, health factor cache) into a **single 256-bit slot** — you'll need to decide precision tradeoffs, exactly like Genius's `uint80/32/24/96` packing problem

  **The health factor cache is never authoritative.** It is stale the instant the oracle moves, which is precisely the moment it matters. Use it for keeper triage and cheap off-chain sorting only. The liquidation authorization check must recompute from live oracle state, every time. Write this into the code as a comment and be ready to explain why — it's a better answer than the packing itself.

- Support at least 3 independent precision domains: collateral valuation precision (18 decimals), interest accrual precision (27 decimals, like RAY math in MakerDAO), and share-based accounting precision — and **prove drift between them stays bounded**. You cannot prove they never desync; truncation guarantees they will. What you prove is that drift is monotonically in the protocol's favor and bounded by a constant you can state.

**Test requirement — invariant suite.** Note that the naive form of this invariant is wrong:

> ~~`sum(all borrow shares) × current index == total protocol debt`~~

Exact equality will not hold, because every share issuance and redemption truncates and the dust accumulates. You will lose days chasing correct rounding as if it were a bug. Assert the directional form instead:

1. `totalDebt >= sum(borrowShares) × index` — the protocol is always owed at least what shares represent
2. `totalDebt - sum(borrowShares) × index < DRIFT_BOUND` — and the gap never runs away
3. `totalSupplyAssets >= sum(supplyShares) × supplyIndex` — same shape on the supply side
4. Solvency: `totalCollateralValue >= totalDebtValue` for every healthy position, at all times
5. No-free-lunch: any round-trip sequence (deposit→withdraw, borrow→repay) leaves the caller with `<=` what they started with
6. Reserve monotonicity: protocol reserves never decrease except via explicit governance withdrawal
7. Index monotonicity: borrow and supply indices are non-decreasing, and idempotent within a timestamp

Run these under any sequence of deposits, borrows, repays, and liquidations.

---

## Phase 2 — Dutch Auction Liquidation Engine

**Contracts to build:**
- `LiquidationAuction.sol` — starts an auction when health factor < 1, discount increases linearly (or exponentially — your choice, more interesting if exponential) per block until claimed
- `AuctionHouse.sol` — manages multiple concurrent auctions, handles partial fills
- `BadDebtManager.sol` — deficit accounting and socialization (see below)

**The hard problems to solve (this is your "precision mismatch" equivalent):**

- What happens if the underlying oracle price moves *during* an active auction? Does the auction discount recalculate against the new price or stay anchored to the price at auction start?
- Partial liquidation: if a liquidator only wants to close 40% of a position, how do you correctly reduce both the debt and collateral proportionally without breaking the health factor calculation for the remainder? (Remember the debt floor from the cross-cutting rules — a partial fill can't strand a position below `dust`.)
- Self-liquidation griefing: prevent a position owner from liquidating themselves via a secondary address to capture the auction discount

### Bad debt — the path that must not be undefined

When an auction decays all the way down and the collateral still doesn't cover the debt, what happens? Right now this is the most common lending interview question there is, and the spec has to answer it. Specify all three layers:

1. **Reserve factor** (built in Phase 1) accrues protocol reserves from borrower interest. First loss absorber.
2. **Deficit accounting** — when an auction closes with unrecovered debt, write it off into a tracked per-market deficit rather than silently leaving phantom debt on the books. Pick a backstop model and be able to justify it against the alternatives: Aave tracks a per-reserve deficit with an umbrella backstop, Maker mints and auctions MKR via the flop auction, Compound draws down reserves.
3. **Cascade case** — if reserves are exhausted, does supplier share value get haircut, or does the protocol carry insolvency and halt withdrawals? There is no free answer here. Choose one, write down the consequence, and test it.

Genius's analogue is worth reading: its vault explicitly contemplates collateral failure (the whitepaper names LUNA by name), and the answer is that failed collateral simply reprices against the settlement rate rather than creating protocol-level insolvency, because the vault never promises a fixed redemption value. Different architecture from yours — but the lesson is that they wrote the failure case down at all.

### Permissionless bounties — the on-chain half of the keeper

Your keeper bot in Phase 4 is infrastructure. The interesting design work is on-chain, and it's the part most specs skip. Genius builds its entire maintenance layer this way — `releaseShares`, `shutdownMiner`, and the calendar summarizers are all callable by anyone and pay the caller, precisely because a transaction-based contract can't self-execute.

Specify:

- Is triggering an auction permissionless? (It should be.)
- What does the trigger caller earn, and is it paid from the position, from reserves, or from the auction proceeds?
- What's the minimum bounty that makes the call economical at realistic gas prices? Below that threshold you have a liveness hole.
- **If no keeper shows up for an hour, does the auction start retroactively from when health crossed 1, or from when it was triggered?** This has real consequences and is a strong thing to have an opinion on. Genius's answer to the equivalent problem is that penalties accrue from the true start day regardless of when someone calls, so lateness never discounts the protocol.

**Test requirement:** Fuzz test the auction decay function against rapid price movements, flash-loan-assisted liquidations, and simultaneous multi-auction scenarios. Add: auctions that exhaust collateral without clearing debt, partial fills that would strand a position below the debt floor, and the no-keeper-for-N-blocks liveness case.

---

## Phase 3 — Adaptive Risk Layer & Governance

### The adaptive layer (this is the differentiator)

Port the pattern that makes Genius genuinely novel. Genius keeps a **global penalty counter** that increments — weighted by position size — every time someone breaks their commitment, and decays by 1/φ every 90 days. Penalties scale with that counter. Critically, each position records the counter's value at creation as a **delta**, so a position's effective multiplier only reflects defections that happened *after* it was opened. Borrowers are never retroactively punished for other people's behavior.

The lending translation:

- A **global stress counter** that increments on each liquidation (weighted by liquidated debt size, so dust liquidations can't move it) and decays over time toward baseline
- The counter drives an **adaptive close factor** and **adaptive auction decay rate** — during a cascade, liquidations become more aggressive to clear risk fast; in calm periods it relaxes back
- Each position snapshots the counter at open time as its delta, so `effectiveMultiplier = f(max(0, globalCounter - positionDelta))`

Two reasons this is worth building:

1. It directly answers "how does your protocol behave during a liquidation cascade" with a mechanism instead of a theory.
2. It's structurally the *same trick as your borrow index* — a global accumulator plus a per-position checkpoint — so it reinforces the pattern rather than adding an unrelated one.

Size-weighting the counter matters. Genius uses a modified sigmoid (the "Senior Curve") mapping a position's principal percentile to a weight of roughly 0.00015 to 1.99888, specifically so dust positions can't spam global state. You don't need a sigmoid, but you do need *some* weighting, or someone opens 10,000 tiny positions and drives your stress counter wherever they want. That's a Sybil attack on your risk parameters.

**Test requirement:** invariant that a position opened at time T is never subject to a multiplier reflecting liquidations before T. Fuzz the counter against mass-liquidation and dust-spam scenarios.

### Governance

- `RiskDAO.sol` — timelocked governance controlling LTV, liquidation thresholds, interest rate curve parameters, reserve factors, and adaptive-layer bounds per asset
- Timelock delay enforced before any risk parameter change takes effect (map this directly to what you said in your Compound interview about governance risk)
- Emergency pause guardian role, separate from full governance, for fast incident response — mirrors your Beard Brothers emergency pause experience

**Scope the guardian's powers explicitly.** Genius spends several pages of its whitepaper arguing that its Origin Address Grantor isn't an admin key, and the argument holds because of one specific constraint: the grantor can pause *new* collateral deposits but can never block redemption of existing collateral. Copy that shape.

Your guardian may pause: new borrows, new deposits, new auctions.
Your guardian may **never** block: repayment, or withdrawal of unencumbered collateral.

Write that as a hard constraint, test it, and put it in the README. It converts "we have an emergency pause" from a centralization red flag into a defensible design — and it's a ready-made interview answer.

---

## Phase 4 — Off-Chain Infrastructure

This is where you round out the full stack and make it genuinely portfolio-differentiating:

**Indexer:**
- Node.js/TypeScript service listening to `LendingPool` and `LiquidationAuction` events via Ethers.js
- Writes normalized event data into **PostgreSQL** (positions, liquidation history, interest accrual snapshots)
- **Redis** as a caching layer for hot reads — current health factors, active auctions, protocol TVL — so your API doesn't hit Postgres or an RPC node on every request

**Keeper bot:**
- A standalone Node.js service that monitors all open positions, computes health factors off-chain for speed, and automatically triggers liquidation auctions on positions that cross the threshold
- This is a real production pattern (Aave, Compound, and every lending protocol run keeper networks) and gives you a genuine "I built a keeper bot" resume line
- Pair it with the on-chain bounty design from Phase 2 — the bot is the client, the bounty is the protocol-level guarantee that *someone* will run one

**Subgraph:**
- Build a proper subgraph indexing all protocol events for historical queries — you've done this before, but this time index derived entities (per-user P&L, protocol-wide utilization over time, stress counter history) not just raw events

**API layer:**
- Express/NestJS REST API serving position data, auction status, and protocol stats from the Postgres/Redis layer
- Rate limiting and caching strategy for public endpoints

---

## Phase 5 — Stretch Goals (pick based on which interviews you want to prep for)

**If prepping for Variational (derivatives):**
- Add a `FundingRateModule.sol` — synthetic perpetual funding rate calculated from the spread between index price and mark price, settled periodically

**If prepping for Morpho (peer-to-peer optimization):**
- Add a P2P matching layer that pairs lenders and borrowers directly when possible for better rates than the pool, falling back to pool liquidity otherwise

**If prepping for security/audit roles:**
- Run Slither and Echidna against the full codebase, document every finding and your remediation, and write it up as a mini audit report — this becomes a portfolio piece on its own

---

## Oracle Design (expand `OracleAggregator.sol`)

This section was the thinnest part of the original spec and it's where liquidation protocols actually die. Chainlink primary + TWAP fallback + staleness checks is the right shape. Add:

- **L2 sequencer uptime feed.** On any L2, check the sequencer uptime feed and enforce a grace period after restart before liquidations resume. Without it, everyone gets liquidated at stale prices the moment the sequencer comes back.
- **Deviation circuit breaker** between primary and fallback. If they disagree by more than X%, halt liquidations for that asset rather than picking one.
- **Staleness that actually reverts.** A Chainlink feed can return a stale-but-non-reverting answer; check `updatedAt` and `answeredInRound` yourself.
- **TWAP lag is the failure mode.** A TWAP fallback *lags by construction*, which means during a sharp crash it reports prices that are too high and you systematically under-liquidate — at exactly the moment you need liquidations most. Short windows are manipulable, long windows lag. State the window you chose and what you're trading away. Having thought about this is the differentiator; most candidates haven't.

---

## Suggested Build Order

**Be honest about scope.** The original six-week plan was aggressive to the point of forcing demo-quality work. Phase 1 alone — three precision domains, single-slot packing, catch-up accrual, and an invariant suite that's meaningful rather than decorative — is realistically two to three weeks on its own.

Better to ship Phases 1–3 at a standard you'd defend in an audit than all five at demo quality. The storage packing, rounding policy, bad-debt handling, and adaptive layer are what a reviewer will actually interrogate. Phase 4 is valuable but it's the part they'll skim.

1. **Week 1:** Cross-cutting design rules written down first — rounding table, token policy, upgradeability stance. Then `InterestRateModel` + index math + catch-up accrual.
2. **Week 2–3:** Rest of Phase 1 — pool, collateral manager, storage packing, full invariant suite. Do not move on until invariants 1–7 pass under fuzzing.
3. **Week 4:** Phase 2 auction engine + partial fills + bad debt path + bounty design, with fuzz tests.
4. **Week 5:** Phase 3 adaptive risk layer + governance + timelock + guardian scoping.
5. **Week 6–7:** Phase 4 indexer + Postgres + Redis + keeper bot.
6. **Week 8:** Subgraph + API layer, or pick one Phase 5 stretch goal — not both.
7. **Ongoing:** Deploy to Sepolia, write README with architecture diagrams, push to GitHub as a public portfolio piece.

---

## Why This Directly Helps Your Job Search

- Every design decision here is something you'll be asked about in DeFi lending interviews — you'll have a real, built answer instead of a theoretical one
- The bad-debt and cascade handling in Phase 2 is *the* question in lending interviews, and most candidates have only a hand-wave
- The adaptive risk layer in Phase 3 is a genuine differentiator — it's a pattern from Genius that almost nobody in mainstream lending has built, and it gives you something to talk about that isn't on everyone else's resume
- The rounding policy and bounded-drift invariants demonstrate the exact kind of precision thinking that Genius's `uint80/32/24/96` work trained you for, in a domain interviewers can immediately evaluate
- The full off-chain stack (Postgres, Redis, keeper bot, subgraph) directly addresses gaps we identified in the Sorbet and custody-backend applications (NestJS, Postgres, Prisma-adjacent patterns)
- A second live, open-source, complex protocol on your GitHub — alongside Genius — makes "I build production DeFi infrastructure" undeniable rather than a claim tied to one employer
