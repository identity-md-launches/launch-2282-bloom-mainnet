# BLOOM farming contracts V2.4

Contracts-only Foundry project for Ethereum Mainnet, chain ID 1. It deploys no ERC-20 token,
liquidity pool, website, proxy, or buyback contract.

**Deployment status:** source and deployment rehearsal are provided here. Production deployment,
source verification and confirmed addresses belong to the IMD attested launch after acceptance.
This task has not broadcast a transaction. No Mainnet deployment or verified farm address is claimed.
See [deployment handoff](docs/DEPLOYMENT.md).

The requester address supplied by the launch context is
`0xDEA11b3A70b77134424d436f6eb455f1Abbd4449`.
Every production owner argument must resolve to that address. Constructors always take the explicit
owner; neither the worker, the deploying factory nor `tx.origin` receives authority.

## Build and test offline

```sh
forge build
forge test
forge fmt --check
python3 tools/export_artifacts.py
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200, IR compilation and
`bytecode_hash = "none"`. It pins the requested fuzz seed
`0x12533046dbcf4bbf0f5b62b732c6552f118f9bc301c18748881405e20873ff35`.
The verification environment needs that compiler and Foundry already installed; all Solidity
dependencies are vendored as ordinary files. There is no FFI, filesystem cheatcode permission,
environment-dependent test, submodule, package-install step or network-dependent test.

The vendored OpenZeppelin Contracts 5.1.0 subset supplies `Math.mulDiv`, `SafeERC20` and
`ReentrancyGuard`; forge-std 1.9.7 supplies testing utilities. Upstream licenses and hashes are in
`lib/`. See [dependency provenance](lib/DEPENDENCIES.json).

## Contracts and custody

| Contract | Purpose | Owner powers |
|---|---|---|
| `Treasury(address owner_)` | Receives withdrawal fees and unaccounted donations | Pay only its own token/ETH balances; permanent owner |
| `FarmFactory(address owner_, address treasury_)` | Registers verified tokens and creates isolated farms | One-time token registration, whitelist, creation |
| `BloomFarm(address owner_, address treasury_, address asset_, address rewardToken_, uint8 assetDecimals_, Kind kind_)` | Exactly one underlying position and one independent BLOOM reward program | Fund, schedule/boost, pause deposits |

Deploy Treasury and Factory first; leave tokens unconfigured until verified. The factory later deploys
full standalone `BloomFarm` instances. Every farm starts with deposits paused and emissions off.
Factory registry membership is how integrations distinguish official farms from arbitrary direct
deployments.

Supported kinds are `SIMD = 0`, native `ETH = 1`, and `BLOOM = 2`. The factory has no general-purpose
ERC-20 farm or IMD deposit-farm entry point. The owner must identify the real official sIMD when
registering the SIMD kind; a token symbol alone cannot establish authenticity.

Each farm owns its own deposits, shares, compounded underlying, reserve, epoch, reward liabilities
and administrative role flags. Farms cannot spend each other's balances. Treasury has no farm role.
There is no lending, strategy, trading, external yield assumption, automatic reward compounding or
conversion from IMD to sIMD.

## Shares, fees and rounding

Internal `sharesOf(account)` balances have 18 decimals and symbols `stakedSIMD`, `stakedETH` or
`stakedBLOOM`. They have no transfer, approval, permit or operator interface.

For an empty farm, initial shares are `assets * 10^(18 - assetDecimals)`. For a populated farm,
shares are `floor(assets * totalShares / accountedAssets)` using full-precision multiplication/division.
This normalizes denomination; it says nothing about sIMD's exchange rate against IMD.
Deposits cost 0%, require positive `minSharesOut`, reject zero shares and enforce the caller's
minimum. Deposit rounding of less than one internal share benefits existing holders. Set a meaningful
minimum from a current quote; a minimum of 1 only rejects total loss to rounding.

For withdrawal of `s` shares:

```text
gross       = floor(s * accountedAssets / totalShares)
totalFee    = ceil(gross * 15 / 100)
userReceives = gross - totalFee                   # floor(85% of gross)

if shares remain after burning s:
    treasuryFee = ceil(gross * 1 / 100)
    retainedFee = totalFee - treasuryFee
else:
    treasuryFee = totalFee
    retainedFee = 0

newAccountedAssets = oldAccountedAssets - gross + retainedFee
```

Fees use the **entire compounded position**. Shares are burned before retained fees increase the
remaining shares' backing. For exact percentage amounts this is 85% user / 14% remaining shares /
1% Treasury; if no shares remain it is 85% / 15% Treasury. Every underlying unit is conserved.
Both fee ceilings prevent fee avoidance by splitting into tiny withdrawals. Rounding deviates by
less than one smallest underlying unit per rounded component; a one-unit exit pays the full unit
as a fee. `minAssetsOut` lets the user reject an undesirable payout.

A partial withdrawer participates in retained fees through their remaining shares. There is no
eligibility delay. **Fee sniping and multi-wallet splitting remain economic risks of Model B.**
For example, after Alice deposits 1,000 tokens and Bob deposits 10, Alice's full withdrawal leaves
150 backing Bob's shares. Bob's full withdrawal then pays 127.5. Tests explicitly demonstrate this.
No transfer or fee bypass is used. See [security findings](docs/SECURITY.md).

Direct donations never change `accountedAssets`, share prices or reward funding. Only recorded
deposits and retained exit fees change underlying backing. The final share withdrawal consumes all
accounted assets, including principal rounding dust. Excess balances stay separate and anyone may
send them to Treasury with `sweepSurplus`; they never subsidize future depositors.

## Rewards and epochs

Rewards are BLOOM, independent of withdrawal fees and immediately claimable. Claims survive full
withdrawals and an empty farm. Deposits, withdrawals and claims checkpoint the global index and that
user before changing their position. Schedule changes checkpoint the global index first, preserving
every user's accrued index entitlement.

The token backing is partitioned into:

1. `accountedAssets`: share-backed underlying, including retained exit fees.
2. `rewardReserve`: funded but unallocated rewards, plus zero-staker emissions and recyclable dust.
3. `scheduledRewards()`: allocation not yet released by the last global checkpoint.
4. `rewardLiability`: conservatively reserved accrued rewards, including unsettled users and dust.

`rewardBacking() = rewardReserve + scheduledRewards() + rewardLiability`.
For a BLOOM farm, the BLOOM balance must cover **accountedAssets + rewardBacking()**; for other farms
each token separately covers its obligations. `totalFunded = totalClaimed + rewardBacking()`.
No reserve, allocation or liability is administratively withdrawable.

`fundRewards(amount)` only adds reserve. It never starts emissions.
`setEpoch(newlyAllocated, durationDays, mode)` allocates *additional* reserve; its amount argument is
not a replacement total and does not include the existing unvested amount.

| Mode | Arguments and result |
|---|---|
| `Continue = 0` | Requires an active epoch and `durationDays = 0`; keeps its finish, ID and original start. Re-spreads unvested rewards plus the added allocation over remaining time. |
| `Restart = 1` | Requires 1–3,650 integer days; increments epoch ID and starts a new finish from now. Uses only unvested rewards plus the added allocation. |
| `boost(additionalRewards)` | Positive reserve allocation with Continue semantics; increases the remaining emission rate. |

`epochStartedAt` records the original epoch start; `epochStart` records the current rate segment
start. Emissions use cumulative `floor(epochBudget * elapsed / segmentDuration)` rather than a
truncated integer per-second rate. Even one reward unit over many days vests by the end. Funding
cannot over-allocate; earned rewards can never be rescheduled.

Zero-staker elapsed emissions return to reserve when the next action or permissionless
`checkpoint()` settles time. They are not assigned to the next depositor. No keeper is required.
Stored reserve/liability/scheduled buckets reflect the last checkpoint; `earned(account)` previews
current time without a transaction.

The index uses precision `1e36` and carries a division remainder while total shares are unchanged.
Account fractions carry across claims. On a share change, a global fractional index remainder is
conservatively retained in liabilities, not assigned to new shareholders. A full exit forfeits less
than one indivisible BLOOM unit of that user's fractional reward. When the pool empties, all
whole-unit claims remain backed and only the excess liability dust returns to reserve. This
prevents recycled dust from consuming someone else's outstanding claim.

## Native ETH

`depositETH(minSharesOut)` wraps native ETH into the configured, verified WETH9. Ordinary ETH sends
to a farm are rejected; forced ETH is isolated from accounting. Native withdrawals unwrap each
payout. The recipient gets a bounded 50,000-gas ETH call; a failure rewraps exactly that payout and
sends WETH instead. `withdraw(..., asWETH = true)` selects WETH directly. Treasury receives native
ETH when possible and WETH on failure. User and Treasury fallbacks are independent.

Every balance-changing path uses a reentrancy guard. Contracts reject inexact token transfers,
including transfer taxes. Rebasing assets, changing transfer semantics and malicious token code are
unsupported; verification before registration is an owner's operational responsibility.

## After launch

Follow [owner operations](docs/OPERATIONS.md). The required external settings are deliberately
unset, not populated with substitute addresses:

| Setting | Setter | Source of the real value |
|---|---|---|
| BLOOM reward/deposit token | `configureToken(2, token, evidenceHash)` | Requester's independently launched and source-verified Mainnet ERC-20 |
| sIMD underlying | `configureToken(0, token, evidenceHash)` | Official IMD staking deployment records and verified Mainnet sIMD contract |
| WETH9 underlying | `configureToken(1, token, evidenceHash)` | Canonical Ethereum WETH9 official deployment, checked against live chain code and interface |
| Allowed assets | `setWhitelisted(token, true)` | Explicit owner approval after the above review |

Registration is one-time per kind and validates deployed code and decimals (0–18; ETH must be 18).
The evidence hash records the owner's off-chain verification record; it does not prove token
identity on-chain. Confirm that sIMD is an exact-transfer, non-rebasing ERC-20 before registration.
Do not replace sIMD with IMD, or substitute a mock token for missing BLOOM.

The owner then creates each desired farm, checks its immutable settings, funds it, chooses an epoch
and deliberately activates deposits. Funding and activation are separate controls; reserve funding
or a factory whitelist never automatically starts a farm.

## Role renouncement and responsibilities

All roles belong to the explicit immutable owner. Factory bits are CONFIG=1 and CREATE=2.
Farm bits are FUND=1, EMISSION=2 and DEPOSIT=4. The owner calls
`renounceRoles(mask, renouncementHash(mask))` on a specific contract. This only clears bits.
There is no grant function, ownership transfer, role recovery, proxy or upgrade.

Factory CONFIG renouncement requires all three tokens to be registered and whitelisted; CREATE
renouncement requires at least one created farm. Farm renouncement requires prior activation;
FUND/EMISSION require a previously scheduled epoch; DEPOSIT can only be renounced while deposits
are open. Renouncing CREATE can intentionally prevent the creation of farm kinds not yet deployed.
Review the full intended farm list first.

Treasury ownership cannot be renounced. Renouncing a farm's powers leaves withdrawals and claims
available. Renouncing a factory power does not change existing farms' own roles. New farms are new,
separate custody contracts and do not recover any role on an old farm. **An immutable owner cannot
rotate a lost or compromised key.** Treasury can pay a chosen beneficiary, but its control remains
at the authenticated wallet.

Operational numeric choices: assets, total shares and lifetime funding are bounded at `2^128 - 1`
base units per farm; reward index precision is `1e36`; maximum epoch duration is 3,650 days; native
delivery gas is 50,000. These bounds, integer rounding and supported token semantics are part of
the implementation.

[Client API and ABIs](docs/INTEGRATION.md) · [actual validation](docs/VALIDATION.md) ·
[security findings and residual risks](docs/SECURITY.md)
