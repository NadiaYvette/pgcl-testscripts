#!/bin/bash
# Build LTP mm-relevant tests for PGCL testing
# Usage: ./build-ltp.sh [arch...]
# If no arch specified, builds for x86_64
#
# Prerequisites:
#   - LTP source tree at ~/src/ltp/ (git clone https://github.com/linux-test-project/ltp.git)
#   - musl sysroots in ./sysroot/<musl-arch>/
#   - Cross compilers installed

set -e

LTP_SRC="${LTP_SRC:-$HOME/src/ltp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# Architecture → cross-compiler mapping (matches build-all.sh)
declare -A CROSS_TABLE=(
    [x86_64]=""
    [aarch64]="aarch64-linux-gnu-"
    [riscv64]="riscv64-linux-gnu-"
    [s390x]="s390x-linux-gnu-"
    [powerpc64]="powerpc64-linux-gnu-"
    [mips64]="mips64-linux-gnu-"
    [sparc64]="sparc64-linux-gnu-"
    [alpha]="alpha-linux-gnu-"
    [m68k]="m68k-linux-gnu-"
    [loongarch64]="loongarch64-linux-gnu-"
    [arm]="arm-linux-gnu-"
    [microblaze]="microblaze-linux-gnu-"
    [hppa]="hppa-linux-gnu-"
    [hppa64]="hppa64-linux-gnu-"
    [riscv32]="riscv32-linux-gnu-"
)

# Architecture → musl sysroot name mapping
declare -A SYSROOT_TABLE=(
    [x86_64]="x86_64"
    [aarch64]="aarch64"
    [riscv64]="riscv64"
    [s390x]="s390x"
    [powerpc64]="ppc64"
    [mips64]="mips64"
    [sparc64]="sparc64"
    [alpha]="alpha"
    [m68k]="m68k"
    [loongarch64]="loongarch64"
    [arm]="arm"
    [microblaze]="microblaze"
)

# MM-relevant test directories to build
MM_SYSCALL_TESTS=(
    mmap mremap mprotect madvise mincore msync
    mlock mlock2 mlockall munlock munlockall
    munmap brk sbrk fork
)
MM_MEM_TESTS=(
    mmapstress mtest06 vma
)

# LTP kselftest framework header
KSFT_HEADER="$LTP_SRC/include"

build_arch() {
    local arch="$1"
    local cross="${CROSS_TABLE[$arch]}"
    local sysroot_name="${SYSROOT_TABLE[$arch]}"
    local sysroot="$SCRIPT_DIR/sysroot/$sysroot_name"
    local outdir="$BUILD_DIR/ltp-$arch"
    local cc="${cross}gcc"

    if [ -n "$sysroot_name" ] && [ ! -d "$sysroot" ]; then
        echo "ERROR: sysroot not found: $sysroot"
        return 1
    fi

    # For x86_64 native, we can use the musl sysroot directly
    local cflags="-static -O2"
    local ldflags="-static"
    if [ -d "$sysroot" ]; then
        cflags="$cflags -I$sysroot/include"
        ldflags="$ldflags -L$sysroot/lib"
    fi

    # LTP include paths
    cflags="$cflags -I$LTP_SRC/include -I$LTP_SRC/include/old"

    echo "=== Building LTP for $arch ==="
    echo "  CC=$cc CFLAGS=$cflags"
    mkdir -p "$outdir"

    local built=0 failed=0

    # Build LTP library objects we need
    local ltp_objs=""
    for src in "$LTP_SRC/lib/tst_test.c" "$LTP_SRC/lib/tst_res.c"; do
        # LTP tests link against libltp — but for static cross-compile we
        # build tests that are already compiled in-tree. Just copy the binaries.
        true
    done

    # Strategy: LTP's Makefiles already built the binaries for x86_64.
    # For cross-arch, we'd need to re-run make with cross settings.
    # For now, if the binaries already exist and match the arch, just copy them.

    # For x86_64 (native build already done):
    if [ "$arch" = "x86_64" ]; then
        echo "  Collecting pre-built x86_64 binaries..."
        for dir in "${MM_SYSCALL_TESTS[@]}"; do
            local srcdir="$LTP_SRC/testcases/kernel/syscalls/$dir"
            [ -d "$srcdir" ] || continue
            find "$srcdir" -maxdepth 1 -type f -executable | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF 64-bit.*x86-64.*statically linked" || continue
                local name="$(basename "$bin")"
                cp "$bin" "$outdir/$name"
                built=$((built + 1))
            done
        done
        for dir in "${MM_MEM_TESTS[@]}"; do
            local srcdir="$LTP_SRC/testcases/kernel/mem/$dir"
            [ -d "$srcdir" ] || continue
            find "$srcdir" -maxdepth 1 -type f -executable | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF 64-bit.*x86-64.*statically linked" || continue
                local name="$(basename "$bin")"
                cp "$bin" "$outdir/$name"
                built=$((built + 1))
            done
        done
        strip "$outdir"/* 2>/dev/null || true
    else
        # Cross-compile: reconfigure and rebuild LTP for target arch
        echo "  Cross-compiling LTP for $arch..."
        local ltp_builddir="/tmp/ltp-build-$arch"
        mkdir -p "$ltp_builddir"

        # Configure LTP for cross-compile
        (cd "$LTP_SRC" && \
         make autotools 2>/dev/null; \
         CC="$cc" \
         AR="${cross}ar" \
         RANLIB="${cross}ranlib" \
         CFLAGS="-static -O2 -I$sysroot/include" \
         LDFLAGS="-static -L$sysroot/lib" \
         CPPFLAGS="-I$sysroot/include" \
         ./configure \
             --prefix=/opt/ltp \
             --host="${cross%-}" \
             --build="$(uname -m)-linux-gnu" \
             --without-numa --without-tirpc \
             2>&1 | tail -5
        ) || { echo "  Configure failed for $arch"; return 1; }

        # Build just the mm tests
        for dir in "${MM_SYSCALL_TESTS[@]}"; do
            local srcdir="$LTP_SRC/testcases/kernel/syscalls/$dir"
            [ -d "$srcdir" ] || continue
            (cd "$srcdir" && make -j$(nproc) \
                CC="$cc" \
                AR="${cross}ar" \
                CFLAGS="-static -O2 -I$sysroot/include -I$LTP_SRC/include -I$LTP_SRC/include/old" \
                LDFLAGS="-static -L$sysroot/lib" \
                2>/dev/null) || true
            find "$srcdir" -maxdepth 1 -type f -executable | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF.*statically linked" || continue
                local name="$(basename "$bin")"
                cp "$bin" "$outdir/$name"
            done
        done
        for dir in "${MM_MEM_TESTS[@]}"; do
            local srcdir="$LTP_SRC/testcases/kernel/mem/$dir"
            [ -d "$srcdir" ] || continue
            (cd "$srcdir" && make -j$(nproc) \
                CC="$cc" \
                AR="${cross}ar" \
                CFLAGS="-static -O2 -I$sysroot/include -I$LTP_SRC/include -I$LTP_SRC/include/old" \
                LDFLAGS="-static -L$sysroot/lib" \
                2>/dev/null) || true
            find "$srcdir" -maxdepth 1 -type f -executable | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF.*statically linked" || continue
                local name="$(basename "$bin")"
                cp "$bin" "$outdir/$name"
            done
        done
        strip "$outdir"/* 2>/dev/null || true
    fi

    local count=$(ls "$outdir" 2>/dev/null | wc -l)
    local size=$(du -sh "$outdir" 2>/dev/null | cut -f1)
    echo "  Built $count binaries ($size) → $outdir"
}

# Parse arguments
ARCHES=("${@:-x86_64}")

for arch in "${ARCHES[@]}"; do
    if [ -z "${CROSS_TABLE[$arch]+x}" ]; then
        echo "Unknown arch: $arch"
        echo "Available: ${!CROSS_TABLE[@]}"
        exit 1
    fi
    build_arch "$arch"
done

echo ""
echo "=== LTP build complete ==="
