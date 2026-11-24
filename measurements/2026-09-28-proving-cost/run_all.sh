#!/bin/bash
# Runs each EZKL stage twice (discard warm-up, keep second) for both circuits,
# wrapped in /usr/bin/time -l for an external peak-RSS reading independent of
# the in-process resource.getrusage reading in run_stage.py.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RESULTS="$HERE/results.jsonl"
: > "$RESULTS"

run_stage_twice() {
  local circuit="$1" stage="$2" work_dir="$3"
  echo "=== $circuit / $stage : warm-up (discarded) ==="
  /usr/bin/time -l python3 run_stage.py "$work_dir" "$stage" \
    > "$HERE/raw_logs/${circuit}_${stage}_warmup.stdout.log" \
    2> "$HERE/raw_logs/${circuit}_${stage}_warmup.time.log" || {
      echo "WARMUP FAILED for $circuit/$stage" >&2; cat "$HERE/raw_logs/${circuit}_${stage}_warmup.time.log" >&2; exit 1; }

  echo "=== $circuit / $stage : measured ==="
  /usr/bin/time -l python3 run_stage.py "$work_dir" "$stage" \
    > "$HERE/raw_logs/${circuit}_${stage}_measured.stdout.log" \
    2> "$HERE/raw_logs/${circuit}_${stage}_measured.time.log" || {
      echo "MEASURED RUN FAILED for $circuit/$stage" >&2; cat "$HERE/raw_logs/${circuit}_${stage}_measured.time.log" >&2; exit 1; }

  # Extract RESULT_JSON line, attach external time -l peak RSS, append to results.jsonl
  python3 merge_result.py \
    "$HERE/raw_logs/${circuit}_${stage}_measured.stdout.log" \
    "$HERE/raw_logs/${circuit}_${stage}_measured.time.log" \
    "$circuit" "$RESULTS"
}

for circuit_pair in "solo:solo_work" "batch:batch_work"; do
  circuit="${circuit_pair%%:*}"
  work_dir="$HERE/${circuit_pair##*:}"
  for stage in compile_setup witness prove verify; do
    run_stage_twice "$circuit" "$stage" "$work_dir"
  done
done

echo "=== DONE. Results in $RESULTS ==="
cat "$RESULTS"
