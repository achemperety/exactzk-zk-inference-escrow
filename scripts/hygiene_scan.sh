#!/usr/bin/env bash
# Hygiene scan. Fails if something that should never be published has entered
# the tree outside lib/:
#
#   pinned     a file listed in provenance/COPIED_FILES.sha256 is missing or changed
#   binary     a binary file that is not pinned
#   address    0x + 40 hex, unless allow-listed or inside deployments/; in specs/, also
#              an address that a deployments/*.json file lists (the spec's reference
#              implementation names the deployed contracts)
#   value32    64 hex (with or without 0x) in a file that is not pinned, unless
#              allow-listed or equal to a SHA-256 listed in a provenance/*.sha256 file
#   keyword    sepolia, basescan, alchemy, infura, private_key, or a PEM private-key
#              header, unless that keyword is allow-listed for that path
#   home-path  an absolute path into somebody's home directory
#
# deployments/ is where deployed addresses are recorded; specs/ may repeat them. Everywhere
# else an address must be a published constant listed in scripts/hygiene_allowlist.txt.
#
# Optional: HYGIENE_PRIVATE_REF=/path/to/a/private/tree makes the scan also fail if
# any address found in that tree appears anywhere here, deployments/ included.
# Matching values are never printed.
#
# Usage: bash scripts/hygiene_scan.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOW="scripts/hygiene_allowlist.txt"
PINNED="provenance/COPIED_FILES.sha256"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$ALLOW" ] || { echo "missing $ALLOW"; exit 2; }
[ -f "$PINNED" ] || { echo "missing $PINNED"; exit 2; }

if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

# ── Files to scan: everything git would commit, except lib/ ──────────────────
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files --cached --others --exclude-standard
else
  find . -type f -not -path './.git/*' -not -path './out/*' -not -path './cache/*' | sed 's|^\./||'
fi | grep -v '^lib/' | sort -u | while IFS= read -r f; do
  [ -f "$f" ] && printf '%s\n' "$f"
done > "$TMP/files"

: > "$TMP/fail"

# ── pinned ───────────────────────────────────────────────────────────────────
awk '{print $2}' "$PINNED" | sort -u > "$TMP/pinned_paths"
# Every SHA-256 recorded in provenance/ is a known value, including the reference
# strings (SRS.sha256) and the source versions of files changed after copying.
cat provenance/*.sha256 | awk '{print tolower($1)}' | sort -u > "$TMP/pinned_hashes"
$SHA -c "$PINNED" > "$TMP/shacheck" 2>&1 || true
# Addresses recorded in deployments/, which specs/ may repeat.
cat deployments/*.json 2>/dev/null | grep -oE '0x[0-9a-fA-F]{40}' | tr 'A-F' 'a-f' | sort -u > "$TMP/deployed" || true
grep -v ': OK$' "$TMP/shacheck" | grep ': ' | sed 's/^/FAIL pinned    /' >> "$TMP/fail" || true

# ── collect hits ─────────────────────────────────────────────────────────────
: > "$TMP/hex"; : > "$TMP/kw"; : > "$TMP/home"
while IFS= read -r f; do
  [ "$f" = "$ALLOW" ] && continue
  [ -s "$f" ] || continue
  if ! grep -Iq . "$f"; then
    grep -qxF "$f" "$TMP/pinned_paths" || echo "FAIL binary    $f: binary file is not listed in $PINNED" >> "$TMP/fail"
    continue
  fi
  grep -I -noE '(0x)?[0-9a-fA-F]{40,}' "$f" 2>/dev/null | awk -v f="$f" -F: '{print f "\t" $1 "\t" $2}' >> "$TMP/hex" || true
  case "$f" in
    scripts/hygiene_scan.sh|scripts/hygiene_selftest.sh) ;;
    *)
      grep -I -noiE 'sepolia|basescan|alchemy|infura|private_key|BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null \
        | awk -v f="$f" -F: '{print f "\t" $1 "\t" tolower($2)}' >> "$TMP/kw" || true
      grep -I -noE '/(Users|home)/[A-Za-z0-9._-]+/' "$f" 2>/dev/null \
        | awk -v f="$f" -F: '{print f "\t" $1}' >> "$TMP/home" || true
      ;;
  esac
done < "$TMP/files"

# ── judge hits against the allow-list ────────────────────────────────────────
awk -F'\t' -v allow="$ALLOW" -v pinned_paths="$TMP/pinned_paths" -v pinned_hashes="$TMP/pinned_hashes" -v deployed_list="$TMP/deployed" '
function glob2re(g,    r) { r = g; gsub(/\./, "\\.", r); gsub(/\*/, ".*", r); return "^" r "$" }
BEGIN {
  while ((getline line < allow) > 0) {
    sub(/#.*/, "", line); n = split(line, a, " ")
    if (n < 2) continue
    if (a[1] == "addr") addr[tolower(a[2])] = 1
    else if (a[1] == "hash") { v = tolower(a[2]); sub(/^0x/, "", v); hash[v] = 1 }
    else if (a[1] == "kw" && n >= 3) { nk++; kwword[nk] = tolower(a[2]); kwre[nk] = glob2re(a[3]) }
  }
  while ((getline line < pinned_paths) > 0) pinned[line] = 1
  while ((getline line < pinned_hashes) > 0) hash[line] = 1
  while ((getline line < deployed_list) > 0) deployed[line] = 1
}
FILENAME ~ /hex$/ {
  v = tolower($3); had0x = (v ~ /^0x/); sub(/^0x/, "", v)
  if (length(v) == 40 && had0x) {
    if (("0x" v) in addr) next
    if ($1 ~ /^deployments\//) next
    if ($1 ~ /^specs\// && (("0x" v) in deployed)) next
    print "FAIL address   " $1 ":" $2 ": address is not allow-listed (0x" substr(v, 1, 6) "…)"
  } else if (length(v) == 64) {
    if (v in hash) next
    if ($1 in pinned) next
    print "FAIL value32   " $1 ":" $2 ": 32-byte value is not allow-listed (" substr(v, 1, 6) "…)"
  }
  next
}
FILENAME ~ /kw$/ {
  k = $3; if (k ~ /private key/) k = "pem-private-key"
  for (i = 1; i <= nk; i++) if (kwword[i] == k && $1 ~ kwre[i]) next
  print "FAIL keyword   " $1 ":" $2 ": \"" k "\" is not allow-listed for this path"
  next
}
FILENAME ~ /home$/ { print "FAIL home-path " $1 ":" $2 ": absolute path into a home directory" }
' "$TMP/hex" "$TMP/kw" "$TMP/home" >> "$TMP/fail"

# ── optional cross-check against a private tree ──────────────────────────────
if [ -n "${HYGIENE_PRIVATE_REF:-}" ]; then
  [ -d "$HYGIENE_PRIVATE_REF" ] || { echo "HYGIENE_PRIVATE_REF is not a directory"; exit 2; }
  grep -rIohE '0x[0-9a-fA-F]+' "$HYGIENE_PRIVATE_REF" \
      --exclude-dir=.git --exclude-dir=lib --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv \
      --exclude-dir=out --exclude-dir=cache --exclude='.env*' --exclude='*.key' --exclude='*.bin' \
      --exclude='*.onnx' --exclude='*.data' --exclude='*.compiled' 2>/dev/null \
    | awk 'length($0) == 42 {print tolower($0)}' | sort -u > "$TMP/ref_addrs" || true
  awk '$1 == "addr" {print tolower($2)}' "$ALLOW" | sort -u > "$TMP/allow_addrs"
  comm -23 "$TMP/ref_addrs" "$TMP/allow_addrs" > "$TMP/ref_deny"
  awk -F'\t' -v deny="$TMP/ref_deny" '
    BEGIN { while ((getline line < deny) > 0) d[line] = 1 }
    { v = tolower($3); if (length(v) == 42 && (v in d)) print "FAIL private-ref " $1 ":" $2 ": address also occurs in the private reference tree (value withheld)" }
  ' "$TMP/hex" >> "$TMP/fail"
  echo "private reference: $(wc -l < "$TMP/ref_deny" | tr -d ' ') addresses checked"
fi

# ── report ───────────────────────────────────────────────────────────────────
NFILES="$(wc -l < "$TMP/files" | tr -d ' ')"
NPIN="$(wc -l < "$TMP/pinned_paths" | tr -d ' ')"
if [ -s "$TMP/fail" ]; then
  sort -u "$TMP/fail"
  echo "hygiene scan: FAILED, $(sort -u "$TMP/fail" | wc -l | tr -d ' ') finding(s) in $NFILES files"
  exit 1
fi
echo "hygiene scan: OK ($NFILES files scanned, $NPIN pinned files verified)"
