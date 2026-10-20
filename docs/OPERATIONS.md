# Owner operations

Use the confirmed Mainnet Treasury and Factory addresses from the launch receipt. Connect the
authenticated owner wallet. Confirm chain ID 1 and inspect `owner()` and `treasury()` before acting.
The ownership model is immutable, with no worker/admin intermediary.

## 1. Verify token identity and register it

For each real token, record its chain, address, official deployment source, verification link,
runtime code/proxy implementation, decimals, transfer behavior and a review date/block.
Hash the record to obtain the nonzero `evidence` value. Do not treat an ERC-20 symbol as proof.

- BLOOM: use the requester's independently launched token. Confirm exact transfers and non-rebasing
  balances. Register with `configureToken(2, realBloom, evidenceHash)`.
- sIMD: obtain the official sIMD address from IMD's official staking deployment information, confirm
  its ERC-20 behavior, and register with `configureToken(0, officialSIMD, evidenceHash)`.
- ETH: verify canonical Ethereum Mainnet WETH9 and its `deposit()` / `withdraw(uint256)` interface,
  then register with `configureToken(1, verifiedWETH9, evidenceHash)`.

Addresses can be registered in any order; each kind is set only once. Invalid code, decimals over
18, missing evidence, reuse of another kind's token or reconfiguration is rejected. Incorrect
registration cannot be repaired in place; review it before signing. Unavailable BLOOM or sIMD is
left unconfigured. The existing infrastructure can wait indefinitely without being redeployed.

Registration does not activate anything. Call `setWhitelisted(token, true)` separately for the
underlying and BLOOM. Whitelisting gates creation only; removing an asset later does not confiscate
or freeze an existing farm. Use the farm's deposit control when necessary.

## 2. Create and inspect farms

Call `createFarm(kind)` for each desired independent farm. Store its address from `FarmCreated`,
confirm `isFarm(address)`, and inspect:

- Owner, Treasury, underlying, BLOOM address, underlying decimals and kind.
- `depositsPaused() == true`, `totalShares() == 0`, and `epochBudget() == 0`.
- Source verification and ABI match the accepted build.

Multiple independent farms of one kind are supported, with separate schedules and funds.
No IMD deposit route exists. Never register IMD in place of official sIMD.

## 3. Fund, open and schedule deliberately

Approve the chosen farm to transfer exactly the desired BLOOM funding and call `fundRewards(amount)`.
All amounts are smallest ERC-20 units, not human decimal strings. Check `rewardReserve()`;
`accountedAssets()` must not increase from reward funding.

Call `setDepositsPaused(false)` only when the token and farm review is complete. There is no
eligibility delay. Start rewards when intended with `setEpoch(newlyAllocated, days, 1)`.
It is usually useful to open deposits before starting the schedule; rewards emitted while empty
return to reserve instead of becoming a windfall for the next depositor.

Examples in **human token quantities**, to convert using verified BLOOM decimals:

- Fund 1,500 BLOOM; start 1,000 BLOOM over 10 days: allocate 1,000, duration 10, Restart.
- Halfway through, add 200 from reserve to the existing finish: allocate 200, duration 0, Continue,
  or call `boost(200)`. 500 unvested + 200 newly allocated become 700 over the remaining 5 days.
- Restart at that point over 20 days: the same 700 form a new epoch; previously earned rewards
  remain separately claimable. The amount argument is still 200, not 700.

Funding alone never extends or starts a schedule. Expired Continue attempts revert. To start
another epoch use Restart. Checkpointing first can make newly recycled zero-staker reserve visible.

## 4. Operate without touching user funds

`setDepositsPaused(true)` pauses only new deposits. Exits and claims continue, as do scheduled
emissions. The owner cannot arbitrarily withdraw farm balances, unvested funding or user rewards.
`sweepSurplus(token)` is permissionless and sends only balances above all accounting obligations to
Treasury. Forced ETH has its own donation sweep.

Treasury's `payToken(token, recipient, amount)` and `payNative(recipient, amount)` pay its actual
receipts. Recipient must be nonzero and different from Treasury. Treasury ownership cannot be
renounced or changed. A failed native Treasury payment reverts; choose a recipient able to receive
ETH, or pay existing WETH with `payToken`.

## 5. Selective, irreversible renouncement

Inspect `activeRoles()` on the exact target and fetch `renouncementHash(mask)`. Review the mask,
chain and address, then submit `renounceRoles(mask, confirmation)`.

| Contract | Bit | Lost capability | Required prior setup |
|---|---:|---|---|
| Factory | 1 | Register/whitelist tokens | All three kinds registered and whitelisted |
| Factory | 2 | Create any more farms | At least one farm created |
| Farm | 1 | Accept further owner reward funding | Deposits activated once and an epoch scheduled once |
| Farm | 2 | Set/continue/restart/boost epochs | Deposits activated once and an epoch scheduled once |
| Farm | 4 | Pause or reopen deposits | Deposits activated and currently open |

Combine bits to give up several powers. A confirmation for another contract, role set or chain
will fail. Already-renounced bits cannot be renounced again or regranted. Finalizing CREATE before
all intended farms exist is irreversible; finalizing EMISSION eventually leaves no new scheduled
rewards. Finalizing FUND leaves only existing reserves to use. Finalizing DEPOSIT removes the
ability to pause new deposits in an incident.

No renouncement transfers ownership. No other wallet can recover the capabilities. Losing the
requester key also loses all remaining owner capabilities, including Treasury control.
