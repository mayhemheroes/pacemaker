#!/usr/bin/env bash
#
# pacemaker/mayhem/test.sh — RUN the cmocka unit-test SUBSET (built by mayhem/build.sh) that covers
# the FUZZED parse functions, and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: each program is one of pacemaker's own known-answer tests asserting the exact
# behaviour of a fuzzed parser — e.g. pcmk_str_is_infinity("INFINITY")==true while " INFINITY" / ""
# / NULL are false; pcmk__parse_ms()/pcmk__numeric_strcasecmp()/pcmk__time_format_hr() check parsed
# values. They assert SPECIFIC RESULTS, so a no-op / exit(0) patch to the parsers cannot pass. This
# script only RUNS the pre-built binaries; it never compiles.
#
# This is a self-contained unit subset (pacemaker's full cts-* suite needs a running cluster).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

MANIFEST="$SRC/mayhem-build/unit/manifest"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -f "$MANIFEST" ]; then
  echo "missing $MANIFEST — run mayhem/build.sh first" >&2
  emit_ctrf "pacemaker-unit" 0 1 0; exit 2
fi

mapfile -t PROGS < "$MANIFEST"
if [ "${#PROGS[@]}" -eq 0 ]; then
  echo "no unit-test programs built — oracle is empty" >&2
  emit_ctrf "pacemaker-unit" 0 1 0; exit 2
fi

# The unit-test binaries are linked with ASan (so they share the instrumented project libs). A few
# of pacemaker's known-answer tests intentionally leave small allocations live at exit (e.g. the
# crm_time_t built by pcmk__time_format_hr_test) — benign HARNESS leaks, not parser bugs. Disable
# LeakSanitizer for the test RUN so those don't fail the oracle. (This is test.sh, not a Mayhemfile,
# so the "Mayhem owns ASAN_OPTIONS" rule does not apply; the FUZZERS keep full ASan.)
export ASAN_OPTIONS="detect_leaks=0:${ASAN_OPTIONS:-}"

PASS=0; FAIL=0
for p in "${PROGS[@]}"; do
  [ -x "$p" ] || { echo "missing test binary: $p" >&2; FAIL=$((FAIL+1)); continue; }
  echo "=== running $(basename "$p") ==="
  # cmocka programs exit non-zero on any failing assertion and emit TAP lines (ok N - <name>).
  # We capture stdout+stderr and verify that actual TAP test results were printed — a sabotaged
  # binary (_exit(0) via LD_PRELOAD) produces EMPTY output and would otherwise appear to pass.
  out="$("$p" 2>&1)" ; rc=$?
  printf '%s\n' "$out"
  # Count lines that start with "ok " or "not ok " — these are TAP result lines.
  tap_ok_count="$(printf '%s\n' "$out" | grep -c '^ok ' || true)"
  tap_fail_count="$(printf '%s\n' "$out" | grep -c '^not ok ' || true)"
  tap_total=$(( tap_ok_count + tap_fail_count ))
  if [ "$tap_total" -eq 0 ]; then
    echo ">> FAILED: $(basename "$p") — no TAP result lines in output (neutered or crashed before any test ran)" >&2
    FAIL=$((FAIL+1))
  elif [ "$rc" -ne 0 ] || [ "$tap_fail_count" -gt 0 ]; then
    echo ">> FAILED: $(basename "$p") ($tap_fail_count failing TAP assertions)" >&2
    FAIL=$((FAIL+1))
  else
    PASS=$((PASS+1))
  fi
done

emit_ctrf "pacemaker-unit" "$PASS" "$FAIL" 0
