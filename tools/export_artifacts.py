#!/usr/bin/env python3
"""Export client ABIs and reproducible build facts after `forge build` (no network or extra packages)."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ("Treasury", "FarmFactory", "BloomFarm")


def main():
    destination = ROOT / "abi"
    destination.mkdir(exist_ok=True)
    contracts = {}
    for name in NAMES:
        artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
        abi = json.dumps(artifact["abi"], indent=2) + "\n"
        (destination / f"{name}.json").write_text(abi)
        creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
        runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
        assert not artifact["bytecode"].get("linkReferences"), f"{name} requires library linking"
        assert len(runtime) <= 24_576, f"{name} exceeds runtime limit"
        assert len(creation) <= 49_152, f"{name} exceeds creation-code limit"
        contracts[name] = {
            "source": f"src/{name}.sol",
            "abi": f"abi/{name}.json",
            "abi_sha256": hashlib.sha256(abi.encode()).hexdigest(),
            "creation_code_bytes_excluding_arguments": len(creation),
            "runtime_bytes": len(runtime),
            "creation_code_sha256_excluding_arguments": hashlib.sha256(creation).hexdigest(),
            "runtime_note": "Immutable fields are patched with real constructor arguments on deployment.",
        }
    sources = {}
    for directory in ("src", "script", "lib"):
        for path in sorted((ROOT / directory).rglob("*.sol")):
            sources[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    result = {
        "compiler": "0.8.26",
        "chain_id": 1,
        "optimizer": True,
        "optimizer_runs": 200,
        "via_ir": True,
        "evm_version": "cancun",
        "bytecode_hash": "none",
        "contracts": contracts,
        "source_sha256": sources,
        "deployment_status": "Awaiting IMD attested deployment; no Mainnet transactions were sent by this task.",
    }
    (ROOT / "docs" / "build-metadata.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Exported Treasury, FarmFactory and BloomFarm ABIs and build metadata.")


if __name__ == "__main__":
    main()
