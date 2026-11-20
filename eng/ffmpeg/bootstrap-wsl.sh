#!/usr/bin/env bash
# Prepare a no-root WSL toolchain, then run build.sh.
# Ubuntu packages for gcc-mingw need root. This machine cannot overlay /usr
# inside a user namespace, so the local compiler is the relocatable llvm-mingw
# tarball. Docker builds use eng/ffmpeg/Dockerfile and do not call this script.
set -euo pipefail

TOOLCHAIN_SHA=919380403de87dca3c581c2053230cd298af5e891286628ba0613b7fed370926
ARCHIVE=
PASS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --toolchain)
            ARCHIVE=$2
            shift 2
            ;;
        *)
            PASS+=("$1")
            shift
            ;;
    esac
done

if [[ -n "${BUILD_LOG:-}" ]]; then
    mkdir -p "$(dirname "$BUILD_LOG")"
    exec > >(tee -a "$BUILD_LOG") 2>&1
fi

DEST=$HOME/rightclip-toolchains/llvm-mingw
if [[ ! -x "$DEST/bin/x86_64-w64-mingw32-gcc" ]]; then
    if [[ -z "$ARCHIVE" ]]; then
        echo "llvm-mingw is not installed and --toolchain was not set" >&2
        exit 1
    fi
    actual=$(sha256sum "$ARCHIVE" | awk '{print $1}')
    if [[ "$actual" != "$TOOLCHAIN_SHA" ]]; then
        echo "toolchain sha256 $actual, expected $TOOLCHAIN_SHA" >&2
        exit 1
    fi
    root=$HOME/rightclip-toolchains
    rm -rf "$root/llvm-extract"
    mkdir -p "$root/llvm-extract"
    echo "STAGE extract llvm-mingw"
    tar -xf "$ARCHIVE" -C "$root/llvm-extract"
    top=
    for dir in "$root/llvm-extract"/*; do
        if [[ -d "$dir" ]]; then
            top=$dir
            break
        fi
    done
    if [[ -z "$top" ]]; then
        echo "llvm-mingw archive has no top directory" >&2
        exit 1
    fi
    rm -rf "$DEST"
    mv "$top" "$DEST"
    rm -rf "$root/llvm-extract"
fi

HOST=$HOME/rightclip-hosttools
if ! command -v nasm >/dev/null 2>&1 && [[ ! -x "$HOST/usr/bin/nasm" ]]; then
    echo "STAGE download nasm"
    mkdir -p "$HOST/debs"
    (cd "$HOST/debs" && apt-get download nasm)
    dpkg-deb -x "$HOST"/debs/nasm_*.deb "$HOST"
fi

export PATH="$DEST/bin:$HOST/usr/bin:$PATH"
hash -r
echo "STAGE toolchain $(x86_64-w64-mingw32-gcc --version | head -n 1)"
echo "STAGE nasm $(nasm -v)"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$script_dir/build.sh" "${PASS[@]}"
