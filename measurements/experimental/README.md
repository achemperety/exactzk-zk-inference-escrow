# EXPERIMENTAL measurements

**Everything under this folder is EXPERIMENTAL.** These runs made new circuit keys to answer design questions for a later version. None of them replaces or changes a canonical artifact: the two pinned circuits, their keys and their verifier bytecode are those in `circuits/spike-mlp/MANIFEST.md`, and they stay so. No key, verifier or contract from here is registered or deployed on any network. Proving keys were deleted after use.

| Folder | Question |
|---|---|
| `columns/` | How does the solo circuit's verifier gas change with its column count, and with an arg-max head instead of ten outputs? |
| `groth16/` | What would a Groth16 version of the same model cost to prove and to verify, and can it match EZKL's outputs exactly? Preliminary; single-party local setup, insecure for anything but measurement; its input commitment is Poseidon2, not the canonical one, so it does not prove the same statement. |

Machines are named in each folder: proving on 2 vCPUs of an Intel Xeon Gold 5220R, gas on the Mac (Apple M4 Pro; gas does not depend on the machine).
