#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer oracle over the vendored MuPDF/dav1d/djvu/chm/jxl/heic libraries, via the plain-flags probe
# that mayhem/build.sh built (/mayhem/kat_probe). Builds nothing.
# exit 0 = pass. Asserts known-input -> known-output values; prints the CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")

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


cd "$SRC"
PROBE="$SRC/kat_probe"
if [ ! -x "$PROBE" ]; then echo "missing $PROBE (mayhem/build.sh should have built it)" >&2; emit_ctrf "sumatrapdf-kat" 0 1; exit 1; fi

out="$("$PROBE" "$SRC/mayhem/kat/hello.pdf" "$SRC/mayhem/kat" 2>/dev/null)"
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
expect "djvu.pages 1"
expect "djvu.page0 1200x400 dpi=100"
expect "djvu.render 1200x400 fmt=3"
expect "djvu.hash 02c5d2c1"
expect "chm.index.len 91 read=91"
expect 'chm.index.text [<html><body><font face="Courier New">CHM font override regression test</font></body></html>]'
expect "jxl.info 64x64 frames=1"
expect "jxl.render 64x64"
expect "jxl.px 32,32=4,37,28,255"
expect "jxl.hash 9577cade"
expect "heic.info 16x8 depth=8"
expect "heic.render 16x8"
expect "heic.left 2,4=255,1,1,255"
expect "heic.right 13,4=0,0,254,255"

emit_ctrf "sumatrapdf-kat" "$passed" "$failed"
