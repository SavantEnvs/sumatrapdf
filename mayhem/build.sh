#!/usr/bin/env bash
# Builds, from the vendored ext/ and src/base sources only (no network):
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
  cc_obj jxldec  "$CC" $DF $JXL_DEF -I"$E/jxldec"  "$E/jxldec/jxl.c"
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
JXL_DEF=""
compile_libs "$OUT/san" "-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -w" \
  "-fno-sanitize=alignment,pointer-overflow,shift-base,nonnull-attribute,function"
S="$OUT/san"

"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.cc" -o "$S/lsan_off.o"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$S/standalone_main.o"

# SumatraPDF's own portable code (src/base: Archive, Exif, TgaReader and what they need) plus the vendored libarchive
# (with bundled bzip2 and the liblzma decoder, configured the way cmd/helper/ng-targets.ts does for a POSIX host) and
# synctex. Sanitized only: the plain-flags KAT probe does not link them.
SB="$OUT/san"; OBJ="$SB"
SBF="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -w"
LAGEN="$OUT/gen_la"; mkdir -p "$LAGEN"
cp "$E/liblzma/config_linux.h" "$LAGEN/config.h"
cp "$M/libarchive_config_posix.h" "$LAGEN/config_posix.h"
LZI="-I$E/liblzma/api -I$E/liblzma/common -I$E/liblzma/check -I$E/liblzma/delta -I$E/liblzma/lz -I$E/liblzma/lzma \
 -I$E/liblzma/rangecoder -I$E/liblzma/simple -I$E/liblzma"
# NULL+0 / memcpy(p, NULL, 0) / unaligned loads / negative shifts in the third-party C libraries are benign on clang/x86
LAF="$SBF -fno-sanitize=alignment,pointer-overflow,shift-base,nonnull-attribute,function"
LAINC="-I$LAGEN -DLIBARCHIVE_STATIC -DPLATFORM_CONFIG_H=\"config_posix.h\" -DBZ_NO_STDIO -DHAVE_CONFIG_H -DLZMA_API_STATIC \
 -I$E/a-libarchive -I$E/a-libarchive/libarchive -I$E/a-zlib -I$E/a-bzip2 $LZI"
cc_obj sb_libarchive "$CC" $LAF $LAINC "$E/a-libarchive/libarchive.c"
cc_obj sb_la_posix   "$CC" $LAF $LAINC src/ng/libarchive/libarchive_posix.c
cc_obj sb_bzip2      "$CC" $LAF $LAINC "$E/a-bzip2/bzip2.c"
# the liblzma decoder half, as listed in cmd/helper/ng-targets.ts (liblzmaSources)
for f in \
  ext/liblzma/common/alone_decoder.c ext/liblzma/common/auto_decoder.c ext/liblzma/common/block_decoder.c \
  ext/liblzma/common/block_header_decoder.c ext/liblzma/common/block_util.c ext/liblzma/common/common.c \
  ext/liblzma/common/filter_common.c ext/liblzma/common/filter_decoder.c \
  ext/liblzma/common/filter_flags_decoder.c ext/liblzma/common/index.c ext/liblzma/common/index_decoder.c \
  ext/liblzma/common/index_hash.c ext/liblzma/common/stream_decoder.c ext/liblzma/common/stream_flags_common.c \
  ext/liblzma/common/stream_flags_decoder.c ext/liblzma/common/vli_decoder.c ext/liblzma/common/vli_size.c \
  ext/liblzma/check/check.c ext/liblzma/check/crc32_fast.c ext/liblzma/check/crc64_fast.c \
  ext/liblzma/lz/lz_decoder.c ext/liblzma/lzma/lzma_decoder.c ext/liblzma/lzma/lzma2_decoder.c \
  ext/liblzma/rangecoder/price_table.c ext/liblzma/delta/delta_common.c ext/liblzma/delta/delta_decoder.c \
  ext/liblzma/simple/simple_coder.c ext/liblzma/simple/simple_decoder.c ext/liblzma/simple/x86.c; do
  cc_obj "sb_lz_$(echo "$f" | tr '/.' '__')" "$CC" $LAF $LAINC "$f"
done
cc_obj sb_lzmadec "$CC" $LAF -I"$E/lzma/C" "$E/lzma/C/LzmaDec.c"
cc_obj sb_bra86   "$CC" $LAF -I"$E/lzma/C" "$E/lzma/C/Bra86.c"
for s in synctex_parser synctex_parser_utils; do
  cc_obj "sb_$s" "$CC" $LAF -I"$E/synctex" -I"$E/a-zlib" "$E/synctex/$s.c"
done
# src/base is SumatraPDF's own code: only nonnull-attribute is relaxed, and only on Base.cpp, where str::Join and friends
# memcpy(dst, empty.s == nullptr, 0) for an empty Str (a zero-length copy, benign on clang/x86; flooded the FB2 target).
# Windows/mac/wasm/crash-handler variants are not part of a POSIX build.
for f in src/base/*.cpp; do
  case "$f" in */CrashHandler*|*_mac.cpp|*_wasm.cpp) continue;; esac
  RELAX=""; [ "$(basename "$f")" = Base.cpp ] && RELAX="-fno-sanitize=nonnull-attribute"
  cc_obj "sb_base_$(basename "$f" .cpp)" "$CXX" $SBF $RELAX -std=c++20 -fno-exceptions -Isrc -I"$E/a-zlib" -I"$E/a-libarchive" \
    -I"$E/lzma/C" -DLIBARCHIVE_STATIC "$f"
done
cc_obj sb_report "$CXX" $SBF -std=c++20 -fno-exceptions -Isrc "$M/sumatra_report.cpp"
# The e-book / document parsers in src/shared that take bytes in and need no Windows API: MOBI (+ PDB reader), FB2 (EbookDoc),
# RTF and what they share (GumboHtmlParser over the vendored gumbo, EngineBase). LitDoc is not built:
# LitParseSectionNames (LitDoc.cpp) reads UTF-16LE names through a 4-byte WCHAR* on Linux, so every .lit aborts there. Also SumatraPDF's own code.
SSI="-Isrc -Isrc/shared -I$E/a-zlib -I$E/a-libarchive -I$E/a-gumbo -I$E/msdes -I$E/lzma/C -DLIBARCHIVE_STATIC"
for f in MobiDoc PalmDbReader EbookDoc RtfDoc DocProperties DocController GumboHtmlParser EngineBase ChapterTable gui/UIModels; do
  cc_obj "ss_$(echo "$f" | tr '/' '_')" "$CXX" $SBF -std=c++20 -fno-exceptions $SSI "src/shared/$f.cpp"
done
cc_obj ss_engine_glue "$CXX" $SBF -std=c++20 -fno-exceptions $SSI "$M/engine_glue.cpp"
cc_obj sb_gumbo "$CC" $LAF -I"$E/a-gumbo" "$E/a-gumbo/gumbo.c"
cc_obj sb_msdes "$CC" $LAF -I"$E/msdes" "$E/msdes/des.c"
wait_all
ar rcs "$SB/libsbase.a" "$SB"/sb_base_*.o "$SB"/sb_report.o
ar rcs "$SB/libsshared.a" "$SB"/ss_*.o "$SB"/sb_gumbo.o "$SB"/sb_msdes.o
ar rcs "$SB/libsarchive.a" "$SB"/sb_libarchive.o "$SB"/sb_la_posix.o "$SB"/sb_bzip2.o "$SB"/sb_lz_*.o \
  "$SB"/sb_lzmadec.o "$SB"/sb_bra86.o
ar rcs "$SB/libsynctex.a" "$SB"/sb_synctex_*.o

# link_target <name> <harness-src> <compile flags> <objs/libs...> → /mayhem/<name>, /mayhem/<name>-standalone
link_target() {
  local name="$1" harness="$2" cflags="$3"; shift 3
  local comp="$CC" std=""
  case "$harness" in *.cpp) comp="$CXX"; std="-std=c++20 -fno-exceptions";; esac
  "$comp" -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $std $cflags -c "$harness" -o "$S/h_$name.o"
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
# libsbase.a's GuessFileType pulls the archive sniffer, so every src/base target links libarchive (+ libcrypto, as upstream does on Linux).
SBLIBS=("$S/libsbase.a" "$S/libsarchive.a" "$S/a_zlib.o" -lcrypto)
SBINC="-Isrc -I$E/a-zlib -I$E/a-libarchive -DLIBARCHIVE_STATIC"
link_target fuzz_archive "$M/fuzz_archive.cpp" "$SBINC" "${SBLIBS[@]}"
link_target fuzz_tga     "$M/fuzz_tga.cpp"     "$SBINC" "${SBLIBS[@]}"
link_target fuzz_exif    "$M/fuzz_exif.cpp"    "$SBINC" "${SBLIBS[@]}"
link_target fuzz_json      "$M/fuzz_json.cpp"      "$SBINC" "${SBLIBS[@]}"
link_target fuzz_guesstype "$M/fuzz_guesstype.cpp" "$SBINC" "${SBLIBS[@]}"
SSLIBS=("$S/libsshared.a" "${SBLIBS[@]}")
SSHINC="$SBINC -Isrc/shared -I$E/a-gumbo"
for t in mobi fb2 rtf; do
  link_target "fuzz_$t" "$M/fuzz_$t.cpp" "$SSHINC" "${SSLIBS[@]}"
done
link_target fuzz_synctex  "$M/fuzz_synctex.c"   "-I$E/synctex" "$S/libsynctex.a" "$S/a_zlib.o"

# ------------------------------------------------------------------ 2) KAT probe: plain flags, no sanitizers
MX_SHIFT=""
# The oracle's jxl decode is pinned to jxldec's portable scalar path (its own JXL_NO_AVX2 switch). The AVX2
# path, picked at run time by CPUID, divides with _mm256_rcp_ps, an approximate reciprocal whose low bits
# differ by CPU vendor, so its pixels (and test.sh's jxl.hash) changed with the CI runner's CPU. The fuzz
# targets above keep the run-time dispatch.
JXL_DEF="-DJXL_NO_AVX2"
compile_libs "$OUT/plain" "-O1 -g0 -w $COVERAGE_FLAGS" ""
P="$OUT/plain"
"$CC" -O1 -w $COVERAGE_FLAGS -Iext/mupdf/include -I"$E/djvudec" -I"$E/chmdec" -I"$E/jxldec" -I"$E/heicdec" -I"$D1/include" \
  -c "$M/kat_probe.c" -o "$P/kat_probe.o"
"$CXX" $COVERAGE_FLAGS "$P/kat_probe.o" "$P/libmupdf.a" "$P/djvudec.o" "$P/chmdec.o" "$P/heicdec.o" "$P/libdav1d.a" \
  -lm -lpthread -ldl -o "$SRC/kat_probe"
file "$SRC/kat_probe" | grep -q 'dynamically linked'
