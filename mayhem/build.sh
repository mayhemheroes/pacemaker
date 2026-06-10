#!/usr/bin/env bash
#
# pacemaker/mayhem/build.sh — build ClusterLabs/pacemaker's four in-tree OSS-Fuzz harnesses as
# sanitized libFuzzer targets (+ standalone reproducers), AND a self-contained subset of pacemaker's
# own cmocka unit tests that exercise the FUZZED parse functions for mayhem/test.sh.
#
# Fuzzed surface (all libxml2-backed / glib-backed config + string parsing in libcrmcommon/libcib):
#   iso8601_fuzzer   — crm_time_parse_period() + pcmk__time_format_hr(): ISO-8601 time-period /
#                      duration strings (e.g. "2024-01-01/P1Y2M").
#   scores_fuzzer    — pcmk_str_is_infinity()/pcmk_str_is_minus_infinity(): pacemaker "score" tokens.
#   strings_fuzzer   — pcmk__numeric_strcasecmp() + pcmk_parse_interval_spec() + pcmk__parse_ms():
#                      interval-spec / millisecond / numeric-version strings used throughout the CIB.
#   cib_file_fuzzer  — cib_file_new()/cib_delete(): the CIB FILE backend constructor (input is the
#                      backing-file PATH string), the entry point pacemaker uses to load a CIB XML.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/OUT/
# STANDALONE_FUZZ_MAIN). pacemaker builds with autotools; we instrument the whole library tree with
# $SANITIZER_FLAGS so the fuzzed parsers (not just the harness) are sanitized, then link each harness
# the same way OSS-Fuzz does (libcib + libpe_rules + libcrmcommon + system libs, static where possible).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${SRC:=/mayhem}" ; : "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── 1) Configure pacemaker, building the libraries WITH sanitizers ────────────────────────────────
# -fsanitize=fuzzer-no-link lets the instrumented library objects carry coverage/cmp hooks that the
# libFuzzer driver (linked later) resolves, without pulling a main() into the .a files.
export CFLAGS="${CFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -Wno-deprecated-declarations"
export CXXFLAGS="${CXXFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -Wno-deprecated-declarations"

test -e configure -a -e libltdl || ./autogen.sh

# The strerror() AC_RUN_IFELSE probe runs a test binary that ASan's leak/exit handling trips; force
# the C99-compliant branch so ./configure succeeds under sanitizers (OSS-Fuzz does the same).
if [ -f configure ]; then
  sed -i 's/as_fn_error $? "strerror() is not C99-compliant" "$LINENO" 5/echo "Assuming strerror is C99-compliant for fuzzing build"/g' configure
fi

test -e Makefile || ./configure --enable-fuzzing 2>/dev/null || test -e Makefile || ./configure

# `core` builds the libraries (libcrmcommon, libcib, libpe_rules, ...) the harnesses link against.
make -j"$MAYHEM_JOBS" core

# ── 2) Build each in-tree harness twice: libFuzzer target + standalone reproducer ─────────────────
# pkg-config module names: libxml2's module is `libxml-2.0` (NOT `libxml2`); using the wrong name
# makes `pkg-config --libs` exit non-zero and silently drop EVERY lib (incl. glib/qb) — the link
# then fails with undefined g_quark_*/qb_log_* symbols.
PKG_MODS="glib-2.0 libxml-2.0 libxslt libqb"
GLIB_INC="$( { command -v pkg-config >/dev/null 2>&1 && pkg-config --cflags $PKG_MODS; } 2>/dev/null || echo '-I/usr/include/glib-2.0 -I/usr/lib/x86_64-linux-gnu/glib-2.0/include' )"
INC="-I./include -I/usr/local/include/libxml2 -I/usr/include/libxml2 $GLIB_INC"

# Static project archives (built by `make core` with sanitizers) + system deps.
# OSS-Fuzz statically builds libqb/libxslt/libxml2 from source; we instead use the distro dev
# packages, which ship shared libs, so we link the system deps DYNAMICALLY (-lfoo) rather than
# the OSS-Fuzz `-l:libfoo.a`. The fuzzed pacemaker code is still statically linked + instrumented.
LIBS="./lib/cib/.libs/libcib.a ./lib/pengine/.libs/libpe_rules.a ./lib/common/.libs/libcrmcommon.a"
SYS="$(pkg-config --libs $PKG_MODS 2>/dev/null) -luuid -licuuc -lz -lgnutls -lbz2 -lpcre2-8 -lpthread -lrt -ldl -lm"

# Pre-compile the standalone run-once driver (no libFuzzer runtime, reads one input file).
STANDALONE_OBJ="$SRC/mayhem-build/standalone_main.o"
mkdir -p "$SRC/mayhem-build"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"

build_one() {
  local src="$1" name
  name="$(basename "$src" .c)"

  # Harness object (instrumented, with libFuzzer coverage hooks).
  $CC $CFLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INC -c "$src" -o "$SRC/mayhem-build/$name.o"

  # libFuzzer target -> $OUT/<name>
  $CXX $CXXFLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/$name.o" \
      $LIBS $SYS -o "$OUT/$name"

  # standalone reproducer -> $OUT/<name>-standalone (no libFuzzer; one input file)
  $CXX $CXXFLAGS $DEBUG_FLAGS "$SRC/mayhem-build/$name.o" "$STANDALONE_OBJ" \
      $LIBS $SYS -o "$OUT/$name-standalone"

  echo "built $name (+ standalone)"
}

for src in lib/common/fuzzers/iso8601_fuzzer.c \
           lib/common/fuzzers/scores_fuzzer.c \
           lib/common/fuzzers/strings_fuzzer.c \
           lib/cib/fuzzers/cib_file_fuzzer.c; do
  build_one "$src"
done

# ── 3) Build the cmocka unit-test SUBSET that covers the fuzzed parse functions (for test.sh) ─────
# These are pacemaker's own known-answer tests (assert_true/assert_false/assert_int_equal against the
# real parsers). They are built with NORMAL flags into a separate object set so test.sh only RUNS
# them — a no-op / exit(0) patch to the parsers cannot keep them green.
UNIT_BUILD="$SRC/mayhem-build/unit"
mkdir -p "$UNIT_BUILD"
UNIT_INC="-I./include -I./include/crm -I./lib/common -I/usr/local/include/libxml2 -I/usr/include/libxml2 $GLIB_INC"
# Unit tests link the (already-built, instrumented is fine here) project libs + cmocka.
UNIT_LIBS="$LIBS $SYS -lcmocka"

# One test program per fuzzed function family. Names mirror the source basenames.
UNIT_TESTS=(
  "lib/common/tests/scores/pcmk_str_is_infinity_test.c"
  "lib/common/tests/scores/pcmk_str_is_minus_infinity_test.c"
  "lib/common/tests/strings/pcmk__numeric_strcasecmp_test.c"
  "lib/common/tests/strings/pcmk__parse_ms_test.c"
  "lib/common/tests/iso8601/pcmk__time_format_hr_test.c"
  "lib/common/tests/iso8601/crm_time_parse_duration_test.c"
)

# The project libs were compiled WITH $SANITIZER_FLAGS -fsanitize=fuzzer-no-link, so they reference
# the ASan/UBSan/sancov runtime symbols. The unit-test binary must therefore link the SAME runtime
# (-fsanitize=fuzzer-no-link pulls in libclang_rt sancov stubs) or the link fails with undefined
# __asan_*/__sancov_* references. We keep $SANITIZER_FLAGS here for that reason (the assertions are
# unaffected by instrumentation — this stays an honest known-answer oracle).
UNIT_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -Wno-deprecated-declarations"
> "$UNIT_BUILD/manifest"
for t in "${UNIT_TESTS[@]}"; do
  [ -f "$t" ] || { echo "WARN: unit test $t not present in this checkout — skipping" >&2; continue; }
  name="$(basename "$t" .c)"
  if $CC $UNIT_FLAGS $UNIT_INC \
       "$t" $UNIT_LIBS -o "$UNIT_BUILD/$name" 2>"$UNIT_BUILD/$name.log"; then
    echo "$UNIT_BUILD/$name" >> "$UNIT_BUILD/manifest"
    echo "built unit test $name"
  else
    echo "WARN: failed to build unit test $name (see $UNIT_BUILD/$name.log)" >&2
    sed 's/^/    /' "$UNIT_BUILD/$name.log" >&2 || true
  fi
done

echo "build.sh complete:"
ls -la "$OUT"/iso8601_fuzzer "$OUT"/scores_fuzzer "$OUT"/strings_fuzzer "$OUT"/cib_file_fuzzer \
       "$OUT"/iso8601_fuzzer-standalone "$OUT"/scores_fuzzer-standalone \
       "$OUT"/strings_fuzzer-standalone "$OUT"/cib_file_fuzzer-standalone 2>&1 || true
