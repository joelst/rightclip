#!/usr/bin/env bash
# Cross-build static LGPL ffmpeg.exe and ffprobe.exe for RightClip.
# External libraries are zlib, openh264, kvazaar, libvpx, and libaom.
# Native LGPL demuxers, decoders, muxers, and filters stay enabled.
# This script does not change eng/ffmpeg.json.
set -euo pipefail

cache_reset=0
on_exit() {
    local code=$?
    if [[ "$code" -ne 0 ]]; then
        if [[ "$cache_reset" -eq 1 && -n "${WORK:-}" ]]; then
            rm -f "$WORK/cache-key"
        fi
        echo "BUILD_FAILED exit=$code"
    fi
}
trap on_exit EXIT

CROSS=x86_64-w64-mingw32-
recipe_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST=$recipe_dir/sources.json
CACHE=${CACHE:-}
WORK=${WORK:-}
OUTPUT=${OUTPUT:-}
JOBS=${JOBS:-}

usage() {
    echo "usage: build.sh --cache DIR --output DIR [--work DIR] [--jobs N]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache) CACHE=$2; shift 2 ;;
        --output) OUTPUT=$2; shift 2 ;;
        --work) WORK=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$CACHE" && -n "$OUTPUT" ]] || usage
mkdir -p "$CACHE" "$OUTPUT"

if [[ -z "$WORK" ]]; then
    if [[ -n "${HOME:-}" && "$HOME" != / && -w "$HOME" ]]; then
        WORK=$HOME/rightclip-ffbuild
    else
        WORK=/tmp/rightclip-ffbuild
    fi
fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
PREFIX=$WORK/prefix
mkdir -p "$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
unset PKG_CONFIG_PATH || true
CXXLIB=-lstdc++

if [[ -z "$JOBS" ]]; then
    JOBS=$(nproc)
    mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    max_by_mem=$((mem_kb / 1500000))
    if (( max_by_mem < 1 )); then
        max_by_mem=1
    fi
    if (( JOBS > max_by_mem )); then
        JOBS=$max_by_mem
    fi
fi

for tool in "${CROSS}gcc" "${CROSS}g++" "${CROSS}ar" "${CROSS}ranlib" "${CROSS}windres" "${CROSS}strip" "${CROSS}objdump" nasm cmake ninja pkg-config python3 curl make gcc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing required tool: $tool" >&2
        exit 1
    fi
done

compiler_version=$(${CROSS}gcc --version)
echo "STAGE compiler ${compiler_version%%$'\n'*}"
echo "STAGE jobs $JOBS"

recipe_key=$(sha256sum "$MANIFEST" "${BASH_SOURCE[0]}" | awk '{print $1}' | sha256sum | awk '{print $1}')
cache_key="${recipe_key} ${RIGHTCLIP_TOOLCHAIN_ID:-none} ${compiler_version%%$'\n'*}"
recorded_key=
if [[ -f "$WORK/cache-key" ]]; then
    recorded_key=$(cat "$WORK/cache-key")
fi
if [[ "$recorded_key" != "$cache_key" ]]; then
    echo "STAGE reset build cache"
    rm -rf "$WORK/src" "$WORK/prefix" "$WORK/build-zlib" "$WORK/build-aom" \
        "$WORK/mingw-toolchain.cmake" "$WORK/cxx-probe.exe"
    mkdir -p "$PREFIX/lib/pkgconfig"
    printf '%s\n' "$cache_key" > "$WORK/cache-key"
    cache_reset=1
fi

json_get() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d[sys.argv[2]][sys.argv[3]], end="")' \
        "$MANIFEST" "$1" "$2"
}

fetch_source() {
    local name=$1
    local file sha url dest actual
    file=$(json_get "$name" file)
    sha=$(json_get "$name" sha256)
    url=$(json_get "$name" url)
    dest=$CACHE/$file
    if [[ -f "$dest" ]]; then
        actual=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$actual" != "$sha" ]]; then
            echo "STAGE discard $file hash $actual"
            rm -f "$dest"
        fi
    fi
    if [[ ! -f "$dest" ]]; then
        echo "STAGE download $name"
        curl -fsSL --retry 3 --retry-delay 2 -o "$dest.partial" "$url"
        mv "$dest.partial" "$dest"
    fi
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "$actual" != "$sha" ]]; then
        echo "$file sha256 $actual, expected $sha" >&2
        exit 1
    fi
}

extract_source() {
    local name=$1
    local root dest
    root=$(json_get "$name" root)
    dest=$WORK/src/$root
    if [[ ! -f "$dest/.extracted" ]]; then
        rm -rf "$dest"
        mkdir -p "$WORK/src"
        tar -xf "$CACHE/$(json_get "$name" file)" -C "$WORK/src"
        touch "$dest/.extracted"
    fi
    printf '%s\n' "$dest"
}

write_toolchain() {
    cat > "$WORK/mingw-toolchain.cmake" << EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_RC_COMPILER ${CROSS}windres)
set(CMAKE_AR ${CROSS}ar CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB ${CROSS}ranlib CACHE FILEPATH "" FORCE)
set(CMAKE_FIND_ROOT_PATH ${PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF
}

build_zlib() {
    if [[ -f "$PREFIX/lib/pkgconfig/zlib.pc" && -f "$PREFIX/lib/libz.a" ]]; then
        echo "STAGE zlib already installed"
        return
    fi
    echo "STAGE zlib"
    local src=$1
    cmake -S "$src" -B "$WORK/build-zlib" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$WORK/mingw-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DZLIB_BUILD_SHARED=OFF \
        -DZLIB_BUILD_STATIC=ON \
        -DZLIB_BUILD_TESTING=OFF
    cmake --build "$WORK/build-zlib" --parallel "$JOBS"
    cmake --install "$WORK/build-zlib"
    if [[ -f "$PREFIX/lib/libzs.a" && ! -f "$PREFIX/lib/libz.a" ]]; then
        cp -a "$PREFIX/lib/libzs.a" "$PREFIX/lib/libz.a"
    fi
    if [[ ! -f "$PREFIX/lib/libz.a" ]]; then
        echo "zlib did not install libz.a" >&2
        find "$PREFIX/lib" -maxdepth 1 -type f -print >&2
        exit 1
    fi
}

build_openh264() {
    if [[ -f "$PREFIX/lib/pkgconfig/openh264.pc" ]]; then
        echo "STAGE openh264 already installed"
        return
    fi
    echo "STAGE openh264"
    local src=$1
    make -C "$src" -j "$JOBS" \
        PREFIX="$PREFIX" \
        INCLUDE_PREFIX="$PREFIX/include/wels" \
        OS=mingw_nt \
        ARCH=x86_64 \
        BUILDTYPE=Release \
        DEBUGSYMBOLS=False \
        LIBDIR_NAME=lib \
        CC="${CROSS}gcc" \
        CXX="${CROSS}g++" \
        AR="${CROSS}ar" \
        RANLIB="${CROSS}ranlib" \
        install-static
    if ! grep -q 'Libs:' "$PREFIX/lib/pkgconfig/openh264.pc"; then
        echo "openh264.pc has no Libs line" >&2
        exit 1
    fi
    if [[ "$CXXLIB" == "-lc++" ]]; then
        sed -i 's/-lstdc++/-lc++/g' "$PREFIX/lib/pkgconfig/openh264.pc"
    fi
}

build_kvazaar() {
    if [[ -f "$PREFIX/lib/pkgconfig/kvazaar.pc" ]]; then
        echo "STAGE kvazaar already installed"
        return
    fi
    echo "STAGE kvazaar"
    local src=$1
    (
        cd "$src"
        ./configure \
            --prefix="$PREFIX" \
            --host=x86_64-w64-mingw32 \
            --disable-shared \
            --enable-static \
            --with-pic
        make -j "$JOBS"
        make install
    )
    local pc=$PREFIX/lib/pkgconfig/kvazaar.pc
    grep -q 'KVZ_STATIC_LIB' "$pc" || echo 'Cflags.private: -DKVZ_STATIC_LIB' >> "$pc"
    grep -q 'Libs.private: -lpthread' "$pc" || echo 'Libs.private: -lpthread' >> "$pc"
}

build_libvpx() {
    if [[ -f "$PREFIX/lib/pkgconfig/vpx.pc" ]]; then
        echo "STAGE libvpx already installed"
        return
    fi
    echo "STAGE libvpx"
    local src=$1
    (
        cd "$src"
        CROSS=$CROSS ./configure \
            --target=x86_64-win64-gcc \
            --prefix="$PREFIX" \
            --disable-shared \
            --enable-static \
            --enable-pic \
            --disable-examples \
            --disable-tools \
            --disable-docs \
            --disable-unit-tests \
            --enable-vp9-highbitdepth
        make -j "$JOBS"
        make install
    )
    "${CROSS}ranlib" "$PREFIX/lib/libvpx.a"
}

build_libaom() {
    if [[ -f "$PREFIX/lib/pkgconfig/aom.pc" ]]; then
        echo "STAGE libaom already installed"
        return
    fi
    echo "STAGE libaom"
    local src=$1
    # ENABLE_APPS defaults on and builds aomenc/aomdec. Those executables call
    # pthread, and llvm-mingw does not add -lpthread on its own. RightClip only
    # needs the static library.
    cmake -S "$src" -B "$WORK/build-aom" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$WORK/mingw-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_APPS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_TOOLS=OFF \
        -DENABLE_DOCS=OFF \
        -DENABLE_TESTDATA=OFF \
        -DENABLE_NASM=ON \
        -DCONFIG_AV1_ENCODER=1 \
        -DCONFIG_AV1_DECODER=1 \
        -DCONFIG_TUNE_VMAF=0 \
        -DAOM_TARGET_CPU=x86_64
    cmake --build "$WORK/build-aom" --parallel "$JOBS"
    cmake --install "$WORK/build-aom"
    local pc=$PREFIX/lib/pkgconfig/aom.pc
    if grep -q 'libvmaf' "$pc"; then
        echo "libaom picked up libvmaf" >&2
        exit 1
    fi
    # CONFIG_MULTITHREAD makes libaom call pthread. FindThreads misses
    # -lpthread when CMake try_compile produces a static library.
    if ! grep -q -- '-lpthread' "$pc"; then
        sed -i 's/^Libs.private:.*/& -lpthread/' "$pc"
    fi
    if ! grep -q -- '-lpthread' "$pc"; then
        echo "aom.pc does not link pthread" >&2
        exit 1
    fi
}

assert_allowed_libraries() {
    local config=$1/config.h
    local line name
    if grep -E '^#define CONFIG_(GPL|NONFREE|GPLV3|VERSION3|LIBX264|LIBX265|LIBZVBI|LIBFDK_AAC|ICONV) 1$' "$config"; then
        echo "FFmpeg configure enabled a prohibited option" >&2
        exit 1
    fi
    while IFS= read -r line; do
        # ${var#define} treats the first # as the pattern operator.
        name=${line#* }
        name=${name%% *}
        case "$name" in
            CONFIG_LIBOPENH264|CONFIG_LIBOPENH264_*|CONFIG_LIBKVAZAAR|CONFIG_LIBKVAZAAR_*|CONFIG_LIBVPX|CONFIG_LIBVPX_*|CONFIG_LIBAOM|CONFIG_LIBAOM_*)
                ;;
            *)
                echo "unexpected external library $name" >&2
                exit 1
                ;;
        esac
    done < <(grep -E '^#define CONFIG_LIB[A-Z0-9_]+ 1$' "$config" || true)
}

probe_one_cxx() {
    local lib=$1
    echo 'int main(){return 0;}' | "${CROSS}gcc" -x c++ - -static "$lib" -o "$WORK/cxx-probe.exe" || return 1
    if "${CROSS}objdump" -p "$WORK/cxx-probe.exe" | grep -Eiq 'DLL Name:.*(libstdc|libc\+\+|libgcc|libunwind|libwinpthread)'; then
        return 1
    fi
}

probe_static_cxx() {
    if probe_one_cxx -lstdc++; then
        CXXLIB=-lstdc++
    elif probe_one_cxx -lc++; then
        CXXLIB=-lc++
    else
        echo "static C++ link failed" >&2
        "${CROSS}objdump" -p "$WORK/cxx-probe.exe" | grep 'DLL Name' >&2 || true
        exit 1
    fi
    echo "STAGE c++ runtime $CXXLIB"
}

build_ffmpeg() {
    echo "STAGE ffmpeg"
    local src=$1
    (
        cd "$src"
        export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
        unset PKG_CONFIG_PATH || true
        ./configure \
            --arch=x86_64 \
            --target-os=mingw32 \
            --cross-prefix="$CROSS" \
            --pkg-config=pkg-config \
            --pkg-config-flags=--static \
            --prefix="$PREFIX" \
            --enable-cross-compile \
            --enable-static \
            --disable-shared \
            --disable-debug \
            --disable-doc \
            --disable-ffplay \
            --disable-gpl \
            --disable-nonfree \
            --disable-autodetect \
            --enable-w32threads \
            --disable-pthreads \
            --disable-iconv \
            --enable-zlib \
            --enable-libopenh264 \
            --enable-libkvazaar \
            --enable-libvpx \
            --enable-libaom \
            --extra-version=rightclip \
            --extra-cflags="-Os -I$PREFIX/include" \
            --extra-cxxflags="-Os" \
            --extra-ldflags="-static -L$PREFIX/lib" \
            --extra-libs="-lpthread ${CXXLIB} -lws2_32 -lsecur32 -lbcrypt -lcrypt32"
        assert_allowed_libraries "$src"
        make -j "$JOBS"
        make install
    )
}

check_imports() {
    local exe=$1
    local report=$2
    "${CROSS}objdump" -p "$exe" | grep 'DLL Name' | tee "$report"
    if grep -Ei 'libgcc|libstdc|libc\+\+|libwinpthread|pthread|openh264|kvazaar|libvpx|libaom|zlib1' "$report"; then
        echo "$exe still imports a bundled library" >&2
        exit 1
    fi
}

copy_license() {
    local src=$1
    local dest_name=$2
    shift 2
    local candidate
    for candidate in "$@"; do
        if [[ -f "$src/$candidate" ]]; then
            cp -a "$src/$candidate" "$OUTPUT/licenses/$dest_name"
            return
        fi
    done
    echo "missing license in $src" >&2
    exit 1
}

for name in ffmpeg zlib openh264 kvazaar libvpx libaom; do
    fetch_source "$name"
done

ffmpeg_src=$(extract_source ffmpeg)
zlib_src=$(extract_source zlib)
openh264_src=$(extract_source openh264)
kvazaar_src=$(extract_source kvazaar)
libvpx_src=$(extract_source libvpx)
libaom_src=$(extract_source libaom)

write_toolchain
probe_static_cxx
build_zlib "$zlib_src"
build_openh264 "$openh264_src"
build_kvazaar "$kvazaar_src"
build_libvpx "$libvpx_src"
build_libaom "$libaom_src"
build_ffmpeg "$ffmpeg_src"

echo "STAGE package"
"${CROSS}strip" "$PREFIX/bin/ffmpeg.exe" "$PREFIX/bin/ffprobe.exe"
mkdir -p "$OUTPUT/licenses"
winpthreads_notice="$recipe_dir/licenses/winpthreads-COPYING"
if [[ ! -f "$winpthreads_notice" ]]; then
    echo "missing winpthreads license notice: $winpthreads_notice" >&2
    exit 1
fi
cp -a "$winpthreads_notice" "$OUTPUT/licenses/winpthreads-LICENSE"
cp -a "$PREFIX/bin/ffmpeg.exe" "$PREFIX/bin/ffprobe.exe" "$OUTPUT/"
check_imports "$OUTPUT/ffmpeg.exe" "$OUTPUT/ffmpeg-imports.txt"
check_imports "$OUTPUT/ffprobe.exe" "$OUTPUT/ffprobe-imports.txt"
copy_license "$ffmpeg_src" "ffmpeg-COPYING.LGPLv2.1" COPYING.LGPLv2.1
copy_license "$ffmpeg_src" "ffmpeg-COPYING.LGPLv3" COPYING.LGPLv3
copy_license "$ffmpeg_src" "ffmpeg-COPYING.GPLv3" COPYING.GPLv3
copy_license "$zlib_src" "zlib-LICENSE" LICENSE COPYING
copy_license "$openh264_src" "openh264-LICENSE" LICENSE COPYING
copy_license "$kvazaar_src" "kvazaar-LICENSE" LICENSE COPYING
copy_license "$libvpx_src" "libvpx-LICENSE" LICENSE COPYING
copy_license "$libaom_src" "libaom-LICENSE" LICENSE COPYING
if [[ -f "$libvpx_src/PATENTS" ]]; then
    cp -a "$libvpx_src/PATENTS" "$OUTPUT/licenses/libvpx-PATENTS"
fi
if [[ -f "$libaom_src/PATENTS" ]]; then
    cp -a "$libaom_src/PATENTS" "$OUTPUT/licenses/libaom-PATENTS"
fi

{
    compiler_version=$(${CROSS}gcc --version)
    echo "compiler: ${compiler_version%%$'\n'*}"
    echo "jobs: $JOBS"
    echo "prefix: $PREFIX"
    grep -m1 'FFMPEG_CONFIGURATION' "$ffmpeg_src/config.h" || true
    echo "sources:"
    for name in ffmpeg zlib openh264 kvazaar libvpx libaom; do
        printf '  %s %s %s\n' "$name" "$(json_get "$name" version)" "$(json_get "$name" sha256)"
    done
} > "$OUTPUT/BUILD.txt"

echo COMPILE_OK
