#!/usr/bin/env bash
# Shows that scripts/hygiene_scan.sh fails when it should. Each case plants one
# violation in the working tree, runs the scan, checks the expected finding and
# removes the violation again. Planted values are random; none is a real address.
#
# Usage: bash scripts/hygiene_selftest.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCAN="bash scripts/hygiene_scan.sh"
PLANT="zz_hygiene_selftest_plant.txt"
DEPLOY_PLANT="deployments/zz_hygiene_selftest_plant.json"
SPEC_PLANT="specs/zz_hygiene_selftest_plant.md"
PINNED_VICTIM="measurements/2026-09-18-steady/proof2_status.json"
BACKUP="$(mktemp)"
REF="$(mktemp -d)"
MADE_DEPLOYMENTS=0

cleanup() {
  rm -f "$PLANT" "$PLANT.bin" "$DEPLOY_PLANT" "$SPEC_PLANT"
  [ -s "$BACKUP" ] && cp "$BACKUP" "$PINNED_VICTIM"
  rm -f "$BACKUP"; rm -rf "$REF"
  [ "$MADE_DEPLOYMENTS" = 1 ] && rmdir deployments 2>/dev/null
  return 0
}
trap cleanup EXIT

rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

PASS=0; FAILED=0
expect() { # name, expected exit code, expected text ("" for none)
  local name="$1" want_rc="$2" want_text="$3" out rc
  out="$($SCAN 2>&1)"; rc=$?
  if [ "$rc" = "$want_rc" ] && { [ -z "$want_text" ] || printf '%s' "$out" | grep -q "$want_text"; }; then
    PASS=$((PASS + 1)); echo "ok    $name"
  else
    FAILED=$((FAILED + 1)); echo "WRONG $name (exit $rc, wanted $want_rc with \"$want_text\")"; printf '%s\n' "$out" | tail -5
  fi
}

expect "clean tree passes" 0 "hygiene scan: OK"

ADDR="0x$(rand_hex 20)"
printf 'payTo = %s\n' "$ADDR" > "$PLANT"
expect "address outside deployments/ is caught" 1 "FAIL address   $PLANT:1"
rm -f "$PLANT"

[ -d deployments ] || { mkdir deployments; MADE_DEPLOYMENTS=1; }
printf '{"deployer": "%s"}\n' "$ADDR" > "$DEPLOY_PLANT"
expect "the same address inside deployments/ is accepted" 0 "hygiene scan: OK"

mkdir -p specs
printf 'Reference: %s\n' "$ADDR" > "$SPEC_PLANT"
expect "an address listed in deployments/ is accepted in specs/" 0 "hygiene scan: OK"
printf 'payTo = %s\n' "$ADDR" > "$PLANT"
expect "the same address elsewhere is still caught" 1 "FAIL address   $PLANT:1"
rm -f "$PLANT"
printf 'Reference: 0x%s\n' "$(rand_hex 20)" > "$SPEC_PLANT"
expect "an address not in deployments/ is caught in specs/" 1 "FAIL address   $SPEC_PLANT:1"
rm -f "$SPEC_PLANT"

printf '%s\n' "$ADDR" > "$REF/record.txt"
out="$(HYGIENE_PRIVATE_REF="$REF" $SCAN 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "FAIL private-ref $DEPLOY_PLANT:1" && ! printf '%s' "$out" | grep -qi "${ADDR#0x}"; then
  PASS=$((PASS + 1)); echo "ok    an address from the private reference tree is caught even in deployments/, value withheld"
else
  FAILED=$((FAILED + 1)); echo "WRONG private reference check (exit $rc)"; printf '%s\n' "$out" | tail -5
fi
rm -f "$DEPLOY_PLANT"

printf 'key = "%s"\n' "$(rand_hex 32)" > "$PLANT"
expect "bare 32-byte value is caught" 1 "FAIL value32   $PLANT:1"
printf 'key = 0x%s\n' "$(rand_hex 32)" > "$PLANT"
expect "0x-prefixed 32-byte value is caught" 1 "FAIL value32   $PLANT:1"

printf 'rpc = "https://example-%s.invalid/v2/key"\n' "alchemy" > "$PLANT"
expect "endpoint keyword is caught" 1 "FAIL keyword   $PLANT:1"
printf '%s BEGIN OPENSSH %s KEY-----\n' "-----" "PRIVATE" > "$PLANT"
expect "PEM private-key header is caught" 1 "FAIL keyword   $PLANT:1"

printf 'path = "/%s/someone/project"\n' "Users" > "$PLANT"
expect "home-directory path is caught" 1 "FAIL home-path $PLANT:1"
rm -f "$PLANT"

printf '\000\001\002binary' > "$PLANT.bin"
expect "unpinned binary file is caught" 1 "FAIL binary    $PLANT.bin"
rm -f "$PLANT.bin"

cp "$PINNED_VICTIM" "$BACKUP"
printf ' ' >> "$PINNED_VICTIM"
expect "a changed pinned file is caught" 1 "FAIL pinned    $PINNED_VICTIM"
cp "$BACKUP" "$PINNED_VICTIM"; : > "$BACKUP"

expect "clean tree passes again" 0 "hygiene scan: OK"

echo "hygiene self-test: $PASS passed, $FAILED wrong"
[ "$FAILED" = 0 ]
