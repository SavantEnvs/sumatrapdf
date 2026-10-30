#!/usr/bin/env bash
# Builds, from the vendored ext/ sources only (no network):
#   * the sanitized fuzz harnesses  /mayhem/fuzz_<fmt>  and their  /mayhem/fuzz_<fmt>-standalone  reproducers
#   * a plain-flags KAT probe  /mayhem/kat_probe  that mayhem/test.sh runs
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS
cd "$SRC"

OUT="$SRC/out"
rm -rf "$OUT"
mkdir -p "$OUT/gen"
M="$SRC/mayhem"
E="$SRC/ext"
D1="$E/dav1d"

throttle() { while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || exit 1; done; }
wait_all() { local rc=0; while [ "$(jobs -rp | wc -l)" -gt 0 ]; do wait -n || rc=1; done; [ "$rc" -eq 0 ] || exit 1; }
# cc_obj <name> <compiler> <flags...> <src>  → $OBJ/<name>.o   (background; wait_all joins)
cc_obj() {
  local name="$1" comp="$2"; shift 2
  throttle
  "$comp" "$@" -c -o "$OBJ/$name.o" &
}

# dav1d with the portable C paths (HAVE_ASM=0), the way cmd/helper/ng-targets.ts builds it off Windows.
cat > "$OUT/gen/config.h" <<'CFG'
#pragma once
#define ARCH_AARCH64 0
#define ARCH_ARM 0
#define ARCH_PPC64LE 0
#define ARCH_X86 1
#define ARCH_X86_32 0
#define ARCH_X86_64 1
#define CONFIG_16BPC 1
#define CONFIG_8BPC 1
#define CONFIG_LOG 1
#define ENDIANNESS_BIG 0
#define HAVE_ASM 0
#define HAVE_CLOCK_GETTIME 1
#define HAVE_DLSYM 1
#define HAVE_POSIX_MEMALIGN 1
#define STACK_ALIGNMENT 16
CFG
DAV1D_INC="-I$OUT/gen -I$D1 -I$D1/include -D_GNU_SOURCE"

# MuPDF is built with a reduced feature set (no OCR/barcode/libarchive/OpenSSL; built-in fonts limited to the Base-14).
MUINC="-Isrc/shared/mupdf -Isrc -Iext/mupdf/source/fitz -Iext/jxldec -Iext/mupdf/include -Iext/a-jbig2dec \
 -Iext/libjpeg-turbo/src -Iext/a-openjpeg -Iext/mupdf/scripts/freetype -Iext/a-freetype/include -Iext/a-mujs \
 -Iext/a-brotli -Iext/cmark-gfm/src -Iext/cmark-gfm/extensions -Iext/mupdf/scripts/cmark-gfm -Iext/a-harfbuzz \
 -Iext/a-lcms2 -Iext/a-gumbo -Iext/a-extract -Iext/a-libwebp -Iext/a-zlib"
MUDEF="-DUSE_JPIP -DOPJ_EXPORTS -DOPJ_STATIC -DHAVE_LCMS2MT=1 -DHAVE_WEBP=1 -DSHARE_JPEG -DTOFU -DTOFU_CJK -DHAVE_OBJCOPY \
 -DFZ_ENABLE_PDF=1 -DFZ_ENABLE_SVG=1 -DFZ_ENABLE_BROTLI=1 -DFZ_ENABLE_JS=1 -DFZ_ENABLE_HYPHEN=0 -DFZ_ENABLE_MD=1 \
 -DCMARK_GFM_STATIC_DEFINE -DFZ_ENABLE_BARCODE=0"

# compile_libs <objdir> <lib-flags> <mupdf-extra-flags> : every vendored library as objects in <objdir>.
compile_libs() {
  OBJ="$1"; local LF="$2" MX="$3"
  mkdir -p "$OBJ"
  for s in cdf cpu ctx data decode dequant_tables getbits intra_edge itx_1d lf_mask lib log mem msac obu pal \
           picture qm ref refmvs scan tables thread_task warpmv wedge \
           sumatra_bitdepth_8 sumatra_bitdepth_8_2 sumatra_bitdepth_16 sumatra_bitdepth_16_2 x86/cpu; do
    cc_obj "dav1d_${s//\//_}" "$CC" $LF $DAV1D_INC "$D1/src/$s.c"
  done
  cc_obj a_zlib   "$CC" $LF -include unistd.h -I"$E/a-zlib" "$E/a-zlib/zlib.c"
  cc_obj a_brotli "$CC" $LF -I"$E/a-brotli" "$E/a-brotli/brotli.c"

  # shift-base relaxed: these C decoders left-shift negative ints (benign on clang/x86); everything else stays halting.
  local DF="$LF $MX_SHIFT"
  cc_obj djvudec "$CC" $DF -I"$E/djvudec" "$E/djvudec/djvu.c"
  cc_obj chmdec  "$CC" $DF -I"$E/chmdec"  "$E/chmdec/chm.c"
  cc_obj jxldec  "$CC" $DF -I"$E/jxldec"  "$E/jxldec/jxl.c"
  cc_obj heicdec "$CC" $DF -msse4.1 -DHEIC_HAVE_DAV1D -DHEIC_HAVE_ZLIB -DHEIC_HAVE_BROTLI \
    -I"$E/heicdec" -I"$D1/include" -I"$E/a-zlib" -I"$E/a-brotli" "$E/heicdec/heic.c"

  # MuPDF + libs: relax alignment (fz_xml node + trailing data), pointer-overflow (NULL+0, wrapping index math),
  # shift-base, nonnull-attribute (memcpy(p, NULL, 0)) and function (callback type punning in C).
  local MF="$LF $MX"
  local n=0 f
  for f in ext/mupdf/source/{cbz,fitz,html,pdf,svg,xps,reflow}/*.c; do
    case "$f" in *leptonica-wrap.c|*load-jxr-win.c) continue;; esac
    n=$((n+1)); cc_obj "mupdf_$n" "$CC" $MF $MUINC $MUDEF "$f"
  done
  cc_obj mupdf_jxl "$CXX" $MF -std=c++17 $MUINC $MUDEF "src/shared/mupdf/load-jxl.cpp"
  cc_obj mupdf_hballoc "$CC" $LF "$M/hb_alloc.c"
  cc_obj a_freetype "$CC" $MF -DFT2_BUILD_LIBRARY '-DFT_CONFIG_MODULES_H="slimftmodules.h"' '-DFT_CONFIG_OPTIONS_H="slimftoptions.h"' \
    -Iext/mupdf/scripts/freetype -Iext/a-freetype/include -Iext/a-brotli -Iext/a-zlib ext/a-freetype/freetype.c
  cc_obj a_harfbuzz "$CXX" $MF -std=c++17 -DHAVE_FALLBACK=1 -DHAVE_OT -DHAVE_FREETYPE -DHB_NO_VISIBILITY=1 \
    -Dhb_malloc_impl=sumatra_hb_malloc -Dhb_calloc_impl=sumatra_hb_calloc -Dhb_realloc_impl=sumatra_hb_realloc -Dhb_free_impl=sumatra_hb_free \
    -Iext/a-harfbuzz -Iext/mupdf/scripts/freetype -Iext/a-freetype/include ext/a-harfbuzz/harfbuzz.cc
  cc_obj a_jbig2dec "$CC" $MF -DHAVE_STRING_H=1 -DJBIG_NO_MEMENTO -Iext/a-jbig2dec ext/a-jbig2dec/jbig2dec.c
  cc_obj a_openjpeg "$CC" $MF -DUSE_JPIP -DOPJ_STATIC -DOPJ_EXPORTS -Iext/a-openjpeg ext/a-openjpeg/openjpeg.c
  cc_obj a_lcms2 "$CC" $MF -Iext/a-lcms2 ext/a-lcms2/lcms2.c
  cc_obj a_mujs "$CC" $MF -Iext/a-mujs ext/a-mujs/mujs.c
  cc_obj a_extract "$CC" $MF -DEXTRACT_NO_OWN_MEMENTO -Iext/a-extract -Iext/a-zlib ext/a-extract/extract.c
  cc_obj a_gumbo "$CC" $MF -Iext/a-gumbo ext/a-gumbo/gumbo.c
  cc_obj a_libwebp "$CC" $MF -Iext/a-libwebp ext/a-libwebp/libwebp.c
  for f in jaricom jcapimin jcarith jchuff jcicc jcinit jclhuff jcmarker jcmaster jcomapi jcparam jcphuff jctrans jdapimin \
           jdarith jdatadst jdatasrc jdhuff jdicc jdinput jdlhuff jdmarker jdmaster jdphuff jdtrans jerror jfdctflt \
           jmemmgr jmemnobs jpeg_nbits; do
    cc_obj "jpeg_$f" "$CC" $MF -DWITHOUT_SIMD -Iext/libjpeg-turbo/src "ext/libjpeg-turbo/src/$f.c"
  done
  for f in ext/libjpeg-turbo/src/wrapper/*-8.c; do
    case "$f" in */rdcolmap-8.c|*/rdppm-8.c|*/wrgif-8.c|*/wrppm-8.c) continue;; esac
    cc_obj "jpeg_w_$(basename "$f" .c)" "$CC" $MF -DWITHOUT_SIMD -Iext/libjpeg-turbo/src "$f"
  done
  n=0
  for f in ext/cmark-gfm/src/*.c ext/cmark-gfm/extensions/*.c; do
    n=$((n+1)); cc_obj "cmark_$n" "$CC" $MF -DCMARK_GFM_STATIC_DEFINE -Iext/cmark-gfm/src -Iext/cmark-gfm/extensions -Iext/mupdf/scripts/cmark-gfm "$f"
  done
  # Base-14 font data linked the way mupdf's Makefile does (ld -r -b binary → _binary_resources_fonts_urw_*)
  (cd ext/mupdf && for f in resources/fonts/urw/*.cff; do
    ld -r -b binary -z noexecstack -o "$OBJ/font_$(basename "$f" .cff).o" "$f"
  done)
  wait_all

  ar rcs "$OBJ/libdav1d.a" "$OBJ"/dav1d_*.o
  
  ar rcs "$OBJ/libmupdf.a" "$OBJ"/mupdf_*.o "$OBJ"/a_freetype.o "$OBJ"/a_harfbuzz.o "$OBJ"/a_jbig2dec.o \
    "$OBJ"/a_openjpeg.o "$OBJ"/a_lcms2.o "$OBJ"/a_mujs.o "$OBJ"/a_extract.o "$OBJ"/a_gumbo.o \
    "$OBJ"/a_libwebp.o "$OBJ"/jpeg_*.o "$OBJ"/cmark_*.o "$OBJ"/font_*.o "$OBJ"/a_brotli.o "$OBJ"/a_zlib.o "$OBJ"/jxldec.o
}

# ------------------------------------------------------------------ 1) sanitized, coverage-instrumented libraries
# Library code is instrumented with -fsanitize=fuzzer-no-link, unconditionally.
MX_SHIFT="-fno-sanitize=shift-base"
compile_libs "$OUT/san" "-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -w" \
  "-fno-sanitize=alignment,pointer-overflow,shift-base,nonnull-attribute,function"
S="$OUT/san"

"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.cc" -o "$S/lsan_off.o"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$S/standalone_main.o"

# link_target <name> <harness-src> <compile flags> <objs/libs...> → /mayhem/<name>, /mayhem/<name>-standalone
link_target() {
  local name="$1" harness="$2" cflags="$3"; shift 3
  "$CC" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $cflags -c "$harness" -o "$S/h_$name.o"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$S/h_$name.o" "$@" "$S/lsan_off.o" -lm -lpthread -ldl -o "$SRC/$name"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS "$S/standalone_main.o" "$S/h_$name.o" "$@" "$S/lsan_off.o" -lm -lpthread -ldl -o "$SRC/$name-standalone"
}

link_target fuzz_djvu "$M/fuzz_djvu.c" "-I$E/djvudec" "$S/djvudec.o"
link_target fuzz_chm  "$M/fuzz_chm.c"  "-I$E/chmdec"  "$S/chmdec.o"
link_target fuzz_jxl  "$M/fuzz_jxl.c"  "-I$E/jxldec"  "$S/jxldec.o"
link_target fuzz_heic "$M/fuzz_heic.c" "-I$E/heicdec" "$S/heicdec.o" "$S/libdav1d.a" "$S/a_zlib.o" "$S/a_brotli.o"
link_target fuzz_dav1d "$D1/tests/libfuzzer/dav1d_fuzzer.c" "$DAV1D_INC -I$D1/tests/libfuzzer" "$S/libdav1d.a"
for fmt in pdf:application/pdf epub:application/epub+zip xps:application/oxps svg:image/svg+xml cbz:application/x-cbz; do
  link_target "fuzz_${fmt%%:*}" "$M/fuzz_mupdf.c" "-Iext/mupdf/include -DMAGIC=\"${fmt#*:}\"" "$S/libmupdf.a"
done
link_target fuzz_image "$M/fuzz_mupdf.c" "-Iext/mupdf/include -DIMAGE_ONLY" "$S/libmupdf.a"

# ------------------------------------------------------------------ 2) KAT probe: plain flags, no sanitizers
MX_SHIFT=""
compile_libs "$OUT/plain" "-O1 -g0 -w $COVERAGE_FLAGS" ""
P="$OUT/plain"
"$CC" -O1 -w $COVERAGE_FLAGS -Iext/mupdf/include -I"$E/djvudec" -I"$E/chmdec" -I"$E/jxldec" -I"$E/heicdec" -I"$D1/include" \
  -c "$M/kat_probe.c" -o "$P/kat_probe.o"
"$CXX" $COVERAGE_FLAGS "$P/kat_probe.o" "$P/libmupdf.a" "$P/djvudec.o" "$P/chmdec.o" "$P/heicdec.o" "$P/libdav1d.a" \
  -lm -lpthread -ldl -o "$SRC/kat_probe"
file "$SRC/kat_probe" | grep -q 'dynamically linked'
