#!/usr/bin/env bash
# Download the two structured reference strings (SRS) the pinned circuits were set
# up with, and put each in place only if its SHA-256 equals the value in
# provenance/SRS.sha256.
#
# Source: the public repository achemperety/exactzk-mnistmlp-provenance-demo, which
# publishes the same two files for independent reproduction of the verifying keys.
# Each URL names a commit, so it cannot change. The hash check is what is trusted,
# not the URL.
#
# Nothing in the Foundry tests reads these files. They are needed only to regenerate
# verifying keys, verifiers or proofs with EZKL (see circuits/spike-mlp/MANIFEST.md).
#
# Usage: bash scripts/fetch_srs.sh   (files already present with the right hash are kept)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PINS="provenance/SRS.sha256"
BASE="https://raw.githubusercontent.com/achemperety/exactzk-mnistmlp-provenance-demo"

if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

# path in this repository | commit in the source repository | path there
SOURCES="
circuits/spike-mlp/run_t3_k5_nonces/srs.bin 40e9ca269dfb3d0a4ab53aaf339d5f22c0a1203f solo/srs.bin
circuits/spike-mlp/run_mnist_mw_k8/srs.bin b35e0d95b299d3d351b9fdd30455b04f49438885 srs.bin
"

status=0
while read -r dest commit src; do
  [ -n "$dest" ] || continue
  want="$(awk -v p="$dest" '$2 == p {print tolower($1)}' "$PINS")"
  [ -n "$want" ] || { echo "no pinned hash for $dest in $PINS"; exit 2; }

  if [ -f "$dest" ] && [ "$($SHA "$dest" | cut -d' ' -f1)" = "$want" ]; then
    echo "ok       $dest (already present)"
    continue
  fi

  part="$dest.part"
  rm -f "$part"
  echo "fetching $dest"
  curl -fL --retry 3 --silent --show-error -o "$part" "$BASE/$commit/$src"
  got="$($SHA "$part" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then
    mv "$part" "$dest"
    echo "ok       $dest ($(wc -c < "$dest" | tr -d ' ') bytes, SHA-256 matches)"
  else
    rm -f "$part"
    echo "FAIL     $dest: SHA-256 does not match $PINS; nothing was written"
    status=1
  fi
done <<< "$SOURCES"

exit "$status"
