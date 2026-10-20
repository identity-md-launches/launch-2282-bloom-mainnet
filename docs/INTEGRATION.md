# Future website / client integration

The `abi/` directory contains complete generated ABIs for the three application contracts.
They are reproducible with `forge build && python3 tools/export_artifacts.py`.
Use addresses from confirmed deployment records and `FarmCreated` events; none are invented here.

## Discovery and units

Read Factory `farmCount()`, `farms(index)`, `isFarm(address)` and `FarmCreated` logs.
Each farm exposes `kind`, `asset`, `assetDecimals`, `rewardToken`, `treasury`, `owner` and
`shareSymbol`. Read BLOOM decimals from the verified ERC-20. Internal shares always have 18 decimals.

`sharesOf` is an internal claim balance, not an ERC-20 token. Do not present transfer/approve/permit
buttons for it. Approvals are only for the actual deposit asset or reward-funding token.

For sIMD, the user first obtains real sIMD through the official staking application or independently
verified staking interface, approves the farm, then deposits it. Use the official staking contract's
current conversion preview/exchange-rate methods for IMD conversions; this project neither assumes
a 1:1 conversion nor invents a staking ABI or endpoint. A farm withdrawal returns sIMD, not IMD.

## Transactions

| Action | Farm method | Notes |
|---|---|---|
| Token deposit | `deposit(assets, minSharesOut)` | Caller deposits for themselves; approve actual underlying first |
| Native deposit | `depositETH(minSharesOut)` with `msg.value` | Only ETH-kind farms |
| Withdraw own shares | `withdraw(shares, minAssetsOut, recipient, asWETH)` | Gross includes compounded assets; quote all fee components |
| Claim BLOOM | `claim(recipient)` | No withdrawal fee; valid after full exit |
| Refresh global accounting | `checkpoint()` | Permissionless, optional |

Before a deposit, read `depositsPaused` and `previewDeposit(amount)`. Set positive `minSharesOut`
to an explicit slippage tolerance; do not silently default it to 1. A failed minimum reverts the
whole transaction. Set a suitable transaction deadline at the wallet/application layer: the
contracts have minimum outputs but no on-chain deadline parameter.

Before withdrawal, read `sharesOf(account)` and `previewWithdraw(shares)`, which returns
`(gross, net, retainedFee, treasuryFee)`. Display fees on gross, not initial deposit value.
There is no lock or waiting period. When `shares == totalShares` (the last position in the farm),
`retainedFee` is 0 and `treasuryFee` is everything the user does not receive: the whole rounded 15%
plus the dust absorbed by the virtual shares, so `net + treasuryFee == accountedAssets`. A full
position worth less than one underlying unit (sub-18-decimal assets only) returns all zeros and can
still be closed with `withdraw(allShares, 0, ...)`. For native payouts, support either ETH or WETH as
the actual received asset and watch `WETHFallback`.

## Read surfaces and indexer rules

- The share price is `(accountedAssets + virtualAssets) / (totalShares + virtualShares)`; read the
  two immutables once. Do not use raw token balances, and do not divide the two storage values alone
  for tiny pools.
- `earned(account)` previews currently claimable BLOOM, including elapsed time.
- `rewardReserve`, `scheduledRewards()` and `rewardLiability` are stored accounting buckets.
  They may not yet reflect elapsed time until checkpointed; their sum remains all reward backing.
- `totalAccrued` sums settled whole-unit claims; liabilities also include users not yet settled.
- `epochId` increments only on Restart; `epochStartedAt` persists through Continue/boost.
  `epochStart`, `epochBudget`, `epochEnd` and `epochReleased` describe the current rate segment.
- Fractional emissions are represented by cumulative vesting, not a rounded integer rate. For a
  display rate, use the rational `epochBudget / (epochEnd - epochStart)` in token units per second.
- Watch `Deposited`, `Withdrawn`, `Claimed`, `RewardsFunded`, `EpochSet`,
  `DepositsPauseChanged`, `RolesRenounced`, `WETHFallback`, `SurplusSwept`,
  `EmptyPoolResidualToTreasury` and `StrandedReserveRecovered`.
- `totalFunded == totalClaimed + totalRecovered + rewardBacking()` at all times.
- Treat balances read inside a token/ETH callback as intermediate transaction state; wait for the
  confirmed receipt and reconcile state after the transaction.

Important revert categories include `NotConfigured`, `NotWhitelisted`, `DepositsPaused`, `Slippage`,
`ZeroShares`, `ZeroAssets`, `InsufficientShares`, `InexactTransfer`, `Insolvent`,
`InsufficientReserve`, `NoActiveEpoch`, `InvalidDuration`, `Unauthorized`, `RoleDisabled`,
`RenouncementOrder` and `RoleStillActive`.

No website, signer service, router, staking wrapper, reward token or liquidity pool is included.
