#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the FULL upstream suite: cargo test = every unit test/proptest across src/
# (aabb, bvh, flat_bvh, ray, ball, point_query, ...) + doc-tests. build.sh already
# compiled the test binaries (cargo test --no-run) with the project's normal flags, so
# this run reuses that cache; cargo only re-links if sources changed.
echo "=== cargo test (upstream unit + integration + doc tests) ==="
log=/tmp/cargo-test.log
cargo test 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

passed=0; failed=0; skipped=0
while read -r p f i; do
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + i))
done < <(grep -oE 'test result: [a-zA-Z]+\. [0-9]+ passed; [0-9]+ failed; [0-9]+ ignored' "$log" \
         | awk '{print $4, $6, $8}')

if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "ERROR: no cargo test results parsed — test runner missing or output format changed" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi
# A compile error / harness abort exits nonzero without a parsed failure — count it.
if [ "$status" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
