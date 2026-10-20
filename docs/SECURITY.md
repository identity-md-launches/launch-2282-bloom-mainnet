# Security review and residual risks

This is an implementation review with executable adversarial tests, not an independent audit.
Independent contributor review and verification of the actual Mainnet tokens remain release
responsibilities. No Slither, Mythril or live Mainnet-fork result is claimed.

## Confirmed economic behavior requiring disclosure

### E1 — Immediate fee sniping can transfer value to a late depositor

**Impact: high economic exposure; intentional consequence of the required Model B rules.**
Reproduction: `AccountingTest.testFeeSnipingIsPossibleUnderImmediateEligibility`.

1. Alice deposits 1,000 underlying tokens.
2. Bob deposits 10 immediately before Alice exits.
3. Alice receives 850; 10 goes to Treasury; 140 remains for Bob's surviving shares.
4. Bob exits his 150-token gross position and receives 127.5.

Bob profits 117.5 without a waiting period, reward emission or share transfer. Deposit-time
eligibility restrictions would change the brief, so none were added. Public transaction ordering
and private order flow can influence who captures this redistribution. Minimum output checks
protect transaction amounts but do not eliminate this incentive.

### E2 — Partial exits and wallet splitting reduce aggregate effective fees

**Impact: significant difference between nominal per-exit fee and aggregate economic cost;
explicitly permitted by the brief.**
Reproduction: `testPartialWithdrawerIntentionallyBenefits`,
`testMultiWalletSplittingMatchesIntentionalPartialWithdrawalBenefit` and
`testRepeatedPartialWithdrawalsRetainTheModelBRecaptureBenefit`.

A sole 100-token depositor who burns half their shares receives 42.5 while their remaining shares
own 57. Closing those shares yields 48.45, totaling 90.95 instead of 85 from one full exit.
Two controlled wallets holding half each produce the same result. With repeated partial exits,
ignoring indivisible-unit rounding, total payout approaches `85/86 = 98.8372093%` of starting assets.
Each operation still charges 15% of gross; the continuing position recaptures the 14% retained
component. This is not a rounding bypass and cannot be removed while preserving the requested
partial-withdrawer benefit.

### E3 — Rounding and indivisible reward units

Withdrawal net rounds down; total fee and Treasury's 1% round up. Tiny repeated withdrawals cannot
avoid fees, but can pay a much higher effective percentage. A one-base-unit exit pays all of it as
fee. Share issuance rounds down by less than one internal share; the user controls minimum output.
Because of the virtual offset described in E4, one share is worth at most about one millionth of
the pool, so the entry rounding loss is bounded by that amount whatever the farm's history.

### E4 — Share-price inflation through retained fees (reported by independent review; fixed)

**Impact before the fix: high.** Donation protection only covered raw token transfers. The 14%
retained by every exit was credited to `accountedAssets` whatever the number of surviving shares,
and an 18-decimal farm minted exactly one share for a 1 wei first deposit. A first depositor could
therefore hold one share, route any amount `X` through a second wallet, and leave one share backed
by `0.14 X`, paying only the 1% Treasury part. Every deposit below that price then reverted with
`ZeroShares` forever, and every larger deposit lost up to one share price to the attacker.

Fix: every share price computation now uses an ERC-4626-style virtual offset of `1e6` shares and
`1e6` wei for an 18-decimal asset (`virtualShares / virtualAssets == 10^(18 - decimals)` so the
empty-farm price is unchanged). One real share can hold at most `1 / (1e6 + 1)` of the pool; the
rest of any retention lands on the virtual shares, which belong to nobody and are paid to the
Treasury when the last real share exits. Driving the share price to `P` now costs about
`1e6 * P / 0.14` routed through the farm with 15% lost per round trip, for a bounded loss of at most
`P` per later deposit and a `ZeroShares` floor of `P`. The price of one share is never below
`1 / scale` underlying units, so an 18-decimal position is always redeemable; a sub-unit position
in a lower-decimal asset is refused at deposit time and can otherwise be closed whole.
Reproductions: `testRetentionCannotInflateSharePriceAgainstLaterDepositors`,
`testZeroSharesOnlyBelowTheVirtuallyBoundedSharePrice`, `testDepositSlippageZeroSharesAndRoundingDust`
and `testLowDecimalDustDepositIsRejectedOrClosableWhole`.

Cost of the fix: a whole-pool exit after retention deviates from the exact Model B figure by the
virtual shares' pro-rata part of the retention, about `1e6 / totalShares` of it (below `1e6` wei on
a 100-token position). Conservation stays exact; that dust reaches the Treasury, never a user.

### E5 — A 1 wei squatter share and the final 15% rule (reported; fixed by E4)

A permanently held 1 wei share meant that no other holder's exit was ever the "last", so a sole real
depositor's full exit paid 1% to the Treasury and 14% to the squatter. With the virtual offset the
squatter's share receives about one millionth of that retention; the rest is paid to the Treasury as
residual when the squatter finally exits (`testSquatterShareCannotCaptureTheFinalFifteenPercent`).
A squatter with a material position is an ordinary remaining shareholder under Model B (E1).

Rewards preserve account fractions across claims and global index fractions while shares are
unchanged. A full exit gives up less than one BLOOM base unit of fractional entitlement. A share
change drops the sub-index remainder from future distribution but keeps the corresponding tokens
conservatively locked in reward liabilities until the pool empties. Dust is then recycled only
after retaining every whole-unit claim. With the configured bounds, each dropped global remainder
represents less than `totalShares / 1e36` BLOOM base units (at most approximately 340.3 units at the
maximum allowed share supply). It does not become principal or owner-withdrawable funds.

## Token and administrative trust

- The owner attests real token identity during registration. Code, decimals and a nonzero evidence
  hash are checked, but authenticity cannot be proven from metadata. No verified BLOOM or official
  sIMD address was supplied, so no production farm or substitute token was created.
- Token registration is immutable. A wrong address requires replacement infrastructure; the review
  record should include official provenance, source, implementation/proxy status and transfer tests.
- Only exact-transfer, non-rebasing ERC-20s with 0–18 decimals are supported. A token that rebases,
  adds transfer fees, blocks the farm, pauses, confiscates balances or upgrades maliciously can
  prevent exits. Solvency checks reject deficits; they cannot make an insolvent token solvent.
  Positive unsolicited balance changes are excess rather than share yield. Do not register a
  rebasing official sIMD without a separate reviewed design change.
- Owner emission control can slow or restart **unvested** rewards for up to 3,650 days per restart,
  repeatedly while retained. Earned claims are protected. While EMISSION is active, funding is not
  recoverable by anyone. EMISSION can only be renounced with or after FUND (`RenouncementOrder`), so
  no token can be funded into a farm that can no longer schedule it; after that renouncement the
  unallocated reserve, including emissions that vest while nobody is staked, is recoverable to the
  Treasury by anyone (`recoverStrandedReserve`). This is an explicit, event-logged, one-way path
  that the owner can use to end a farm's rewards and reclaim the unscheduled part; scheduled and
  earned rewards are never affected (`testFundRoleMayGoFirstAndStrandedReserveIsRecoverableOnlyAfterEmissionRenouncement`).
- Owner deposit control can block new deposits, never withdrawals/claims. Renouncing it removes
  incident response for new deposits. Factory whitelist changes gate new farm creation only.
- Trust assumption on the pause: while deposits are paused, only existing shareholders receive the
  14% retained by exits, and the owner alone decides when deposits reopen. An owner wallet that
  also holds shares can therefore keep competing snipers out during large exits and collect that
  retention itself (`testPauseHolderCapturesRetentionOfExitsMadeWhilePaused`). This is the
  requested pause power combined with Model B, not a bypass; it ends when DEPOSIT is renounced.
- Claims check only the reward side of solvency: a shortfall of the unrelated underlying asset (a
  slashing or negatively rebasing sIMD, which is outside the supported token set) blocks withdrawals
  but not BLOOM claims (`testClaimsSurviveAnUnderlyingShortfallWhileWithdrawalsRejectIt`).
- Ownership is immutable. Lost-key recovery and ownership transfer do not exist; a compromised
  owner retains any unrenounced configuration/emission/pause rights and Treasury spending rights.
- Treasury can spend its actual received fees/donations. It has no farm role, token approval,
  arbitrary-call executor or path into principal/reward backing.

## Implementation review

Reviewed external state-changing paths: token/native deposits, withdrawals, claims, funding,
epoch setting, boosts, pause changes, global checkpointing, both donation sweeps, factory token
registration/whitelisting/creation, role renouncement and Treasury payouts.

The fund-moving paths use OpenZeppelin SafeERC20 and ReentrancyGuard. Withdrawal/claim entitlement
effects precede token or ETH delivery. Deposits measure actual incoming balances; outgoing
transfers verify both the farm's decrease and recipient's increase. False returns revert;
no-return ERC-20s are supported. All mutating callbacks into a farm's balance/reward paths are
guarded. Unknown share transfer/approval selectors revert.

Native payouts use a bounded call with discarded return data, then WETH fallback. Tests cover
rejection, gas exhaustion, a 64 KiB return-data bomb, direct WETH selection, reentrancy and rejected
Treasury ETH. A caller providing insufficient transaction gas can still cause their transaction to
revert; retrying with adequate gas or direct WETH is required.

Solvency views and post-transfer assertions cover combined BLOOM principal/rewards. All reserve,
scheduled and earned buckets are excluded from sweeps. Factory-created farms have explicit
requester ownership and immutable dependencies. No production external-call loop scales with the
number of depositors. Deployment tests scan actual runtime bytes for forbidden escape opcodes,
enforce EIP-170/EIP-3860 bounds, and rehearse constructors without dependency code.

## Compiler lint review

`forge build` emits heuristic lint warnings; those are not represented as a clean analyzer audit:

- ETH-send warnings: Treasury payout is owner-only; farm payout spends only the caller's burned
  shares. Receivers are validated and reentrancy guards apply.
- Reentrancy/balance/event warnings: token and ETH calls are external, but every affected
  transaction path holds the guard. Tests exercise callbacks. Events emitted after successful
  delivery describe final outcomes; integrations should read confirmed receipts.
- Strict-equality warnings: exact token balance deltas intentionally reject inexact/rebasing
  behavior. Whole-farm solvency itself uses `>=`, so donations do not block withdrawals.
- Timestamp warnings: emissions depend on elapsed time by design, not randomness or privileged
  transaction ordering. Block production time can affect small amounts near schedule boundaries.
- Return-data-bomb warnings: only the success flag is used; Solidity does not materialize unused
  return bytes. An executable bomb-recipient test confirms WETH fallback.
- Authorization-modifier-order warnings: the owner/role checks before the guard are storage reads
  only; they make no external call. Recipient-validation warnings follow helper calls that do check
  nonzero/self addresses. Zero-initialized local accumulators are intentional Solidity semantics.

## What remains unproven

Local tests exercise test tokens, not the future BLOOM or official sIMD contracts. There is no
formal proof, live transaction, source-verification receipt, gas estimate against the deployment
service's exact transaction, or independent audit in this assignment. Stateful tests cover eight
actors across randomized histories; separate tests cover 5–1,000 actors and a full 1,000-user reward
exit. They cannot exhaust every transaction sequence, token implementation or MEV strategy.

No unresolved implementation exploit was found in the recorded checks. That statement is limited
to the tests and review described here; E1/E2 are demonstrated material economic risks retained
because the brief explicitly requires their underlying rules. E4 and E5 were found by an
independent reviewer after the first acceptance and are fixed in this revision; the reviewer's
proof test passes against the current code.
