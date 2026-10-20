# Recorded local validation

Final validation on 2026-10-20 used Foundry 1.8.3 and the project-pinned Solidity 0.8.26.
These are local results, not independent certification or Mainnet deployment evidence.

| Check | Result |
|---|---|
| `forge build --sizes` (includes `forge build`) | Passed |
| `forge test` | **82 passed, 0 failed, 0 skipped**, across 8 suites |
| `forge fmt --check` | Passed |
| `forge script script/Deploy.s.sol:DeployBloom --chain-id 1` | Local simulation passed; 4,127,439 simulated gas; no broadcast |
| `python3 tools/export_artifacts.py` | Exported all three application ABIs and build metadata |
| Reviewer proof `Proof_1083e6856077.t.sol` (copied under `test/scratch/`) | Both tests failed on the previous code and pass on this revision |

The final full test run took 58.02 seconds of wall time reported by Foundry. Its unedited test
output is [validation-results.txt](validation-results.txt). This project has 80 ordinary test
functions (including three fuzz functions) plus two grouped invariant suites, which Foundry 1.8.3
reports as 82 results. Each invariant group checks three properties.

This revision (after independent review) added the virtual share-price offset, the empty-pool
residual payment, whole-position dust closure, reward-only solvency on claims, the FUND-before-
EMISSION renouncement order and stranded-reserve recovery. Five existing accounting assertions
that pinned exact whole-pool exit figures now allow the sub-`1e6` wei deviation the offset
introduces and assert exact conservation instead; one renouncement test follows the new order.

The required seed is pinned in `foundry.toml`:

```text
0x12533046dbcf4bbf0f5b62b732c6552f118f9bc301c18748881405e20873ff35
```

Each fuzz function ran 512 cases. Each invariant group ran 128 histories at depth 64, totaling
8,192 calls per group, **16,384 calls overall**, with zero unexpected reverts. After each history,
the handler exits and claims all eight actors' positions and verifies terminal conservation.
Tests read no environment variables and require no network or preexisting token deployments.

## Coverage by suite

| Suite | Checks |
|---|---|
| `AccountingTest` (21) | Immediate exits; 85/14/1 conservation; final 15% Treasury plus residual; full compounded value; partial exits; tiny rounding; six-decimal normalization, zero-gross rejection and whole-position dust closure; non-transferability; donation inflation; retention inflation (reviewer's attack), bounded `ZeroShares` floor and squatter share; empty-pool residual isolation; min-output rejection; fee sniping and wallet splitting; 512 fuzz cases with 5–1,000 users |
| `RewardsTest` (16) | Funding does not schedule; proportional accrual; old-reward exclusion; fee-free claims; zero-staker reserve recycling; Continue/Restart/boost; over-allocation failures; tiny budgets over long durations; fraction/remainder carry; dust and old claims after emptying; BLOOM same-token isolation; independent farms; 1,000-user exit and reward claims |
| `AdminTest` (17) | Explicit ownership; token-unavailable launch and later configuration; unsupported assets; authorization failures; pause semantics and the pauser's retention trust assumption; claims under an underlying shortfall; selective/all-role renouncement with FUND-before-EMISSION order; stranded-reserve recovery; confirmation replay prevention; setup guards; immutable token settings; Treasury isolation |
| `NativeETHTest` (10) | Wrapping, native payouts, retained WETH assets, explicit WETH, receiver rejection, gas exhaustion, return-data bomb, reentrancy, Treasury failure fallback, unexpected and forced ETH |
| `AdversarialTest` (12) | Incoming/outgoing transfer fees; false/no-return tokens; reentrant token callbacks; reward double-claim attempt; negative balance change; arithmetic bounds; recipient and constructor validation; Treasury payment failure |
| `DeploymentTest` (4) | Explicit requester ownership through deployment code; wrong chain/owner rejection; empty-chain constructor compatibility; real runtime scanning and size limits |
| `SIMDInvariants` | Independent principal/token conservation; funded reward coverage; share totals and empty-pool isolation |
| `BLOOMInvariants` | The same properties with principal and reward obligations in a single ERC-20 balance |

Stateful actions include deposits, partial/full withdrawals, funding, epoch changes, claims, time
advancement, checkpointing, donations, sweeping and deposit pauses. The 1,000-user test's aggregate
gas is the sum of many simulated user actions, not a proposed single Mainnet batch transaction;
production user operations do not iterate over depositors.

## Deployability

| Application | Runtime bytes | Creation bytes before arguments | Constructor words |
|---|---:|---:|---:|
| Treasury | 854 | 1,012 | 1 |
| FarmFactory | 17,073 | 17,342 | 2 |
| BloomFarm | 12,647 | 13,573 | 6 |

Runtime is below 24,576 bytes and initcode including arguments is below 49,152 bytes. Tests scan
deployed runtime while skipping PUSH data, matching the supplied protected check's rule against
DELEGATECALL, CALLCODE and SELFDESTRUCT. Constructors do not call outside contracts or require
dependency code. The factory and farm are not upgradeable.

The supplied protected owner harness imports a launch-owned `OwnerChecks.sol` and consumes launch
environment values that this assignment does not include. Those exact service harnesses were
read, not fabricated or claimed to have been run. Local deployment tests independently rehearse
the constructor, ownership, size and opcode properties; the actual protected checks run during
the subsequent attested launch process.

Foundry emitted heuristic lint warnings; their review and remaining limitations are documented in
[SECURITY.md](SECURITY.md). A script rehearsal also reported stale Foundry-generated deployment
helper artifacts in the local cache; those generated artifacts are excluded from submission.
Application sources, ABIs and source hashes are ordinary delivered files.

## Not performed

No live Mainnet deployment, explorer source verification, actual BLOOM/sIMD/WETH integration,
Slither/Mythril run, formal verification or independent adversarial audit is claimed.
Mainnet addresses and verification links must come from successful service receipts, not from
the simulation's temporary addresses.
