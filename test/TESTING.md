This contribution adds independent tests to the existing BLOOM implementation. Application
contracts, deployment scripts, dependencies and configuration were not changed.

Validation on 2026-10-20 with Foundry 1.8.3 and Solidity 0.8.26:

| Check | Observed result |
| --- | --- |
| `forge build` | Passed; existing source lint warnings remain |
| Full `forge test` | **107 passed, 0 failed, 0 skipped**, 13 suites, 57.68 seconds |
| New stateless fuzz properties | Six properties, 1,000 cases each, configured inline |
| New native custody invariants | 256 histories × 96 calls = 24,576 calls, no unexpected reverts |
| New reward oracle invariant | 256 histories × 96 calls = 24,576 calls, no unexpected reverts |
| Existing SIMD/BLOOM invariant campaigns | 8,192 calls each, no unexpected reverts |
| Reported defect reproduction | Standalone proof failed with `ZeroAssets()`, as reported separately |

Both build and test commands were executed with:

```sh
FOUNDRY_FUZZ_SEED=0x12533046dbcf4bbf0f5b62b732c6552f118f9bc301c18748881405e20873ff35 forge build
FOUNDRY_FUZZ_SEED=0x12533046dbcf4bbf0f5b62b732c6552f118f9bc301c18748881405e20873ff35 forge test
```

Foundry groups the three native invariant functions into one reported test result. The 107
results include four invariant campaigns and the original 74 results. This contribution adds
31 ordinary test functions, including six fuzz properties, and two invariant campaigns.
Across all four campaigns, the final run exercised 65,536 handler calls. Expected failure paths
use specific revert checks; the zero-revert campaign counts mean no *unexpected* handler revert.

| Added file | Properties and failure paths |
| --- | --- |
| `NativeCustodyInvariants.t.sol` | Five actors, including rejecting, gas-exhausting and reentrant recipients; deposits, partial/full exits, native/WETH delivery, pause, time, funding, epochs, claims, donations, sweeps and Treasury payments. Ghost inputs and measured recipient balance deltas enforce principal, fee, donation, reward and Treasury conservation. Every history ends by exiting and claiming all positions, including while deposits are paused. |
| `RewardOracle.t.sol` | Independent integration of emissions for fixed 1:3:4 share weights under random funding, claims, Continue, Restart, boost, pause and time changes. Expected rewards never use the farm's reward index or earned-value implementation. Separate fuzz tests cover staggered entries/exits and checkpoint/claim frequency up to the accounting cap. Deterministic tests cover epoch endpoints and recycling an expired zero-staker epoch without a keeper call. |
| `FailureAtomicity.t.sol` | Failed user payment after a successful Treasury payment; failed deposit/funding/claim/epoch/slippage settlement; reward deficits; exact reentrancy error selectors; owner-contract Treasury callbacks; malformed WETH mint/unwrap and failed fallback rewrap. Snapshots compare balances, user entitlements, share supply and reward/epoch accounting across reverts, followed by successful retries where applicable. |
| `BoundaryProperties.t.sol` | 0–18 decimal assets, same-token principal/reward separation at the funding cap, donation isolation, sub-unit partial withdrawal rejection, repeated 18-decimal round trips, all selective farm role masks, chain-bound confirmations, independent factory roles, missing dependencies, deferred activation and invalid token decimals. |

The required `.imd-findings.json` contains one **low-severity** issue and its complete,
self-contained Foundry proof. In a six-decimal farm, Alice and Bob each deposit 1,000 base units.
Alice exits, leaving 1,140 units behind 10^15 shares. Carol's one-unit deposit succeeds and
mints 877,192,982,456 shares, but redeeming that entire position immediately reverts because its
gross assets round to zero. The expected safe outcome is either rejection before taking that
deposit or a defined way to close the accepted dust position. The holder currently needs a top-up
or later redistribution. No theft or reward insolvency is demonstrated by this finding.

The proof was run as `forge test --match-path test/scratch/DustExitProof.t.sol -vv` and failed
with `ZeroAssets()`. Its source is embedded in the report, rather than submitted as a default
failing test or converted into a passing assertion of the defect. For reproduction, save the
report's `proof` string as a `.t.sol` file under `test/` and run `forge test --match-path` on it.
The retained repeated-round-trip fuzz property covers the 18-decimal fixture; low-decimal
full-position dust closure remains the reported finding. Lower-decimal pricing, custody and
partial-withdrawal failure cases remain in the passing suite.

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
