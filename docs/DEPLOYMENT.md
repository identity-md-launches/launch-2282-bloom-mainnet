# Mainnet deployment handoff

No worker transaction has been signed or broadcast. No confirmed application addresses or explorer
verification links exist in this deliverable. The IMD service performs the attested launch and source
verification after acceptance; it must return the actual receipts, addresses and explorer links.
Local deployment tests are simulations, not Mainnet deployments.

The two initial application contracts, in order:

| Contract | Constructor arguments | Mainnet status |
|---|---|---|
| `src/Treasury.sol:Treasury` | `address owner_ = $owner` | Pending IMD launch and verification |
| `src/FarmFactory.sol:FarmFactory` | `address owner_ = $owner`, `address treasury_ = $contract:Treasury` | Pending IMD launch and verification |

`$owner` resolves to **0xDEA11b3A70b77134424d436f6eb455f1Abbd4449**, supplied by this task's launch
context. `$contract:Treasury` means the actual earlier deployed Treasury, not a worker-selected
wallet. These are handoff descriptions for the later manifest step, not a manifest file.

Deploy only these two applications initially. Their nonpayable constructors make no calls to
dependencies, inspect no external code and need no post-deployment initialization. They can be
deployed with tokens unavailable. FarmFactory has no authority until called by its explicit owner;
token settings are genuinely unconfigured and farm creation reverts `NotConfigured`.

Later token registration, farm creation and activation are ordinary owner operations after verifying
the real tokens. They are not part of the infrastructure constructor or a hidden initialization
transaction. No farms are deployed by `script/Deploy.s.sol`.

## Rehearsal

```sh
forge test --match-path test/Deployment.t.sol -vv
forge script script/Deploy.s.sol:DeployBloom --chain-id 1
```

`DeployBloom.deploy(address)` is directly tested; `run()` uses the authenticated requester constant.
The script rejects other owners and chains and reads no environment or wallet credentials.
It contains no broadcast instruction. Production deployment uses each application's compiled
bytecode through the service, not the script contract as an additional application.

## Compiler and verification

Use Solidity 0.8.26, optimizer enabled with 200 runs, via-IR enabled, EVM Cancun, and metadata bytecode
hash `none`, exactly as `foundry.toml` specifies. All library functions inline; no library linking,
proxy implementation, delegatecall, selfdestruct, submodule or compiler path is required.

`python3 tools/export_artifacts.py` exports complete application ABIs and source/build hashes.
`docs/build-metadata.json` reports creation/runtime sizes; constructor arguments must be included
in the deployment service's actual initcode. Runtime immutable fields depend on those arguments.

After deployment the service should:

1. Verify chain ID 1, successful receipts and exact source/compiler settings.
2. Verify `Treasury.owner()`, `FarmFactory.owner()` and `FarmFactory.treasury()`.
3. Verify all three token addresses remain unconfigured and `farmCount() == 0`.
4. Publish source for each real address with its actual ABI-encoded constructor arguments using the
   configured explorer verification service (for example `forge verify-contract`).
5. Record confirmed addresses, transaction hashes, blocks and explorer verification links in the
   official launch handoff. Integrations should consume that record rather than guess addresses.

For later farms, record each `FarmCreated` event and verify `src/BloomFarm.sol:BloomFarm` with the
six exact constructor arguments: requester, actual Treasury, verified underlying, verified BLOOM,
underlying decimals, and kind enum encoded as uint8. Do not use a synthetic address to complete a
verification command.

No Mainnet fork integration or live token compatibility claim has been made: the token addresses
were not supplied. Source verification and independent adversarial review remain launch duties.
