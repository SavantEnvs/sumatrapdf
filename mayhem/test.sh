#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer oracle over the vendored MuPDF/dav1d libraries, via the plain-flags probe
# that mayhem/build.sh built (/mayhem/kat_probe). Builds nothing.
# exit 0 = pass. Asserts known-input -> known-output values; prints the CTRF summary.
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


: "${SRC:=/mayhem}"
PROBE="$SRC/kat_probe"
if [ ! -x "$PROBE" ]; then echo "missing $PROBE (mayhem/build.sh should have built it)" >&2; emit_ctrf "sumatrapdf-kat" 0 1; exit 1; fi

out="$("$PROBE" "$SRC/mayhem/kat/hello.pdf" 2>/dev/null)"
echo "$out"

passed=0; failed=0
expect() {
  if printf '%s\n' "$out" | grep -qxF -- "$1"; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: expected line: $1" >&2; fi
}
expect "pdf.pages 1"
expect "pdf.bounds 0 0 300 800"
expect "pdf.text [Hello Sumatra KAT 42]"
expect "pdf.pixmap 300x800"
expect "pdf.px 5,5=255,255,255"
expect "svg.pixmap 20x10"
expect "svg.left 4,4=255,0,0"
expect "svg.right 15,4=0,0,255"
expect "bmp.size 2x1"
expect "bmp.px 0,0=0,255,0"
expect "bmp.px 1,0=255,255,0"
expect "dav1d.version 1.5.4"

emit_ctrf "sumatrapdf-kat" "$passed" "$failed"
