This contribution adds independent tests to the existing BLOOM implementation. Application
contracts, deployment scripts, dependencies and configuration were not changed.

Revision on 2026-10-20 (Foundry 1.8.3, Solidity 0.8.26), after the implementation added ERC-4626
virtual offsets, the last-exit residual rule, the FUND-before-EMISSION renouncement order and
`recoverStrandedReserve`:

| Check | Observed result |
| --- | --- |
| `forge build` | Passed; existing source lint warnings remain |
| Full `forge test` | **119 passed, 0 failed, 0 skipped**, 14 suites, 140.7 seconds |
| Native custody invariants | 256 histories × 96 calls = 24,576 calls, no unexpected reverts |
| Reward oracle invariant | 256 histories × 96 calls = 24,576 calls, no unexpected reverts |
| Existing SIMD/BLOOM invariant campaigns | 8,192 calls each, no unexpected reverts |

Both commands were run with
`FOUNDRY_FUZZ_SEED=0x12533046dbcf4bbf0f5b62b732c6552f118f9bc301c18748881405e20873ff35`.

Changes in this revision:

- `NativeCustodyInvariants.t.sol`: the handler now models deposits and exits independently with
  the virtual-offset price `floor(x * (S + vS) / (A + vA))`. Deposits must mint exactly that quote,
  or revert `ZeroShares` when it is zero. Partial exits with zero gross must revert `ZeroAssets`.
  The last exit must pay the Treasury `A - net`. No exit may ever lower the price of a remaining
  share.
- `BoundaryProperties.t.sol`: the role-mask fuzz now expects `RenouncementOrder` whenever EMISSION
  would go while FUND survives. It checks that the rejected call removes nothing, then renounces FUND
  first and continues.
- New `VirtualOffsetAndRecovery.t.sol`:
  - Model B retention reaches remaining holders of at least 1e12 shares, except at most one
    millionth of the pool.
  - Exact fee conservation, the last-exit residual going to the Treasury, and the empty farm
    restarting at the initial price.
  - The share price never falls across random deposits and exits.
  - Every rejected renouncement order.
  - `recoverStrandedReserve` on the BLOOM farm, where principal and rewards are the same token,
    called by any address at any time. It takes only unallocated reserve and never scheduled
    rewards, earned rewards or principal, and `claimed + recovered + backing == funded`.

`.imd-findings.json` holds one **low-severity** finding. Under the virtual offset, the 14%
retention is shared with 1e6 virtual shares, and their part goes to the Treasury on the last exit.
For a remaining position of about 1e6 wei this is half the retention. In the reproduction (a 1e6
wei stayer and a 100-token leaver), the Treasury receives 9.05 tokens against Model B's 3.1. For
positions of at least 1e12 wei the loss is at most one millionth, and the suite asserts that bound
rather than the dust-holder behaviour. The previous round's low-decimal dust finding is resolved
by the new deposit-time `ZeroAssets` check and full-position close; the existing suite covers
both.

These tests run offline with local external-token and WETH fixtures. They create no production
token and do not verify the identity or behavior of the future BLOOM or official sIMD contracts.
The malformed wrapper fixture tests rejection behavior; it is not a claim about official WETH9.
Live token provenance, decimals, transfer/rebase/upgrade behavior and mainnet-fork integration
still require verification before activation. No deployment or explorer verification was
performed as part of this bounded testing assignment.

The reward oracle uses exact integer rates and fixed weights to isolate emission scheduling;
it is complemented by the original changing-share invariants, the new native custody handler,
and staggered-entry/frequent-claim fuzz tests. Random histories do not exhaust the state space.
The supplied launch-owned protected checks were read, but their service environment and owner
harness were not fabricated or claimed as executed. The original suite's fee-sniping and partial
withdrawal recapture scenarios remain relevant economic risks explicitly permitted by Model B.
