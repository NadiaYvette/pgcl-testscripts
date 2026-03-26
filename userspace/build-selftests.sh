#!/bin/bash
#
# Cross-compile kernel mm selftests for PGCL testing
#
# Usage: ./build-selftests.sh [ARCH...]
#   No args = build for all bootable architectures
#   With args = build only specified architectures
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_SRC=/home/nyc/src/linux
SYSROOT_BASE="$SCRIPT_DIR/sysroot"
BUILD_BASE="$SCRIPT_DIR/build"
MM_DIR="$LINUX_SRC/tools/testing/selftests/mm"
KSFT_DIR="$LINUX_SRC/tools/testing/selftests"

NPROC=$(nproc)

# Architectures that boot with MMUSHIFT=4
# Format: "cross_prefix|musl_arch|elfv2_wrapper"
declare -A ARCH_INFO
ARCH_INFO=(
  [x86_64]="||"
  [aarch64]="aarch64-linux-gnu-|aarch64|"
  [riscv64]="riscv64-linux-gnu-|riscv64|"
  [s390x]="s390x-linux-gnu-|s390x|"
  [powerpc64]="powerpc64-linux-gnu-|powerpc64|$SCRIPT_DIR/build/powerpc64-linux-gnu-gcc-elfv2"
  [sparc64]="sparc64-linux-gnu-|sparc64|"
  [arm]="arm-linux-gnu-|arm|"
  [alpha]="alpha-linux-gnu-|alpha|"
  [hppa]="hppa-linux-gnu-|hppa|"
  [hppa64]="hppa64-linux-gnu-|hppa64|"
  [loongarch64]="loongarch64-linux-gnu-|loongarch64|"
  [riscv32]="riscv32-linux-gnu-|riscv32|"
  [mips64]="mips64-linux-gnu-|mips64|"
  [m68k]="m68k-linux-gnu-|m68k|"
  [microblaze]="microblaze-linux-gnu-|microblaze|"
)

# Extra CFLAGS per arch (ABI, march, etc.)
declare -A ARCH_CFLAGS
ARCH_CFLAGS=(
  [riscv32]="-march=rv32imac -mabi=ilp32"
  [s390x]="-march=z196"
)

# Extra link libraries per arch
declare -A ARCH_EXTRA_LIBS
ARCH_EXTRA_LIBS=()

# Tests to build (no -lnuma, -lcap, no kernel modules needed)
SELFTEST_NAMES=(
  map_fixed_noreplace
  map_populate
  mremap_test
  mremap_dontunmap
  cow
  madv_populate
  compaction_test
  guard-regions
  on-fault-limit
  # merge — skipped: needs both <linux/prctl.h> and <sys/prctl.h> which
  #         conflict on struct prctl_mm_map. Tests KSM merging, not PGCL-critical.
  # droppable — skipped: intentionally OOMs and can crash ppc64/powernv
  droppable
  mseal_test
  mlock2-tests
  mrelease_test
  pfnmap
  mkdirty
)

log() { echo "=== $* ===" >&2; }

# Ensure local_config.h exists (cow.c includes it)
ensure_local_config() {
    if [ ! -f "$MM_DIR/local_config.h" ]; then
        touch "$MM_DIR/local_config.h"
    fi
}

build_arch() {
    local arch="$1"
    local info="${ARCH_INFO[$arch]}"
    if [ -z "$info" ]; then
        log "Unknown architecture: $arch"
        return 1
    fi

    IFS='|' read -r CROSS_PREFIX MUSL_ARCH ELFV2_WRAPPER <<< "$info"

    local cc="${CROSS_PREFIX}gcc"
    if [ -z "$CROSS_PREFIX" ]; then cc="gcc"; fi
    # powerpc64 needs ELFv2 wrapper
    if [ -n "$ELFV2_WRAPPER" ] && [ -f "$ELFV2_WRAPPER" ]; then
        cc="$ELFV2_WRAPPER"
    fi

    local musl_arch="$MUSL_ARCH"
    if [ -z "$musl_arch" ]; then musl_arch="x86_64"; fi

    local sysroot="$SYSROOT_BASE/$musl_arch"
    local extra_cflags="${ARCH_CFLAGS[$arch]:-}"
    local extra_libs="${ARCH_EXTRA_LIBS[$arch]:-}"

    if [ ! -f "$sysroot/lib/libc.a" ]; then
        log "No musl sysroot for $arch at $sysroot, skipping selftests"
        return 1
    fi

    local outdir="$BUILD_BASE/selftests-$arch"
    mkdir -p "$outdir"

    log "Building mm selftests for $arch (cc=$cc, sysroot=$sysroot)"

    # Build helper objects
    $cc -Wall -O2 -static -nostartfiles $extra_cflags \
        -I"$LINUX_SRC" -isystem "$LINUX_SRC/usr/include" -isystem "$sysroot/include" \
        -I"$MM_DIR" -I"$KSFT_DIR" -L"$sysroot/lib" \
        -Wno-unused-function -Wno-unused-variable -D_GNU_SOURCE \
        -c -o "$outdir/vm_util.o" "$MM_DIR/vm_util.c" 2>/dev/null || {
        log "WARNING: vm_util.c failed for $arch, creating stub"
        $cc $extra_cflags -x c -c -o "$outdir/vm_util.o" /dev/null 2>/dev/null
    }

    $cc -Wall -O2 -static -nostartfiles $extra_cflags \
        -I"$LINUX_SRC" -isystem "$LINUX_SRC/usr/include" -isystem "$sysroot/include" \
        -I"$MM_DIR" -I"$KSFT_DIR" -L"$sysroot/lib" \
        -Wno-unused-function -Wno-unused-variable -D_GNU_SOURCE \
        -c -o "$outdir/thp_settings.o" "$MM_DIR/thp_settings.c" 2>/dev/null || {
        log "WARNING: thp_settings.c failed for $arch, creating stub"
        $cc $extra_cflags -x c -c -o "$outdir/thp_settings.o" /dev/null 2>/dev/null
    }

    local built=0
    local failed=0

    for name in "${SELFTEST_NAMES[@]}"; do
        local src="$MM_DIR/${name}.c"
        if [ ! -f "$src" ]; then
            log "  SKIP $name (no source)"
            continue
        fi

        # Use -nostartfiles + musl CRT to avoid host CRT / sigsetjmp link issues
        # Put musl headers first (-isystem) so they win over kernel UAPI for
        # types like struct prctl_mm_map that both define
        if $cc -Wall -O2 -static -nostartfiles $extra_cflags \
            -isystem "$sysroot/include" \
            -I"$MM_DIR" -I"$KSFT_DIR" -I"$LINUX_SRC/usr/include" -L"$sysroot/lib" \
            -Wno-unused-function -Wno-unused-variable -D_GNU_SOURCE \
            -Wno-error -Wno-redundant-decls \
            -o "$outdir/$name" \
            "$sysroot/lib/crt1.o" "$sysroot/lib/crti.o" \
            "$src" "$outdir/vm_util.o" "$outdir/thp_settings.o" \
            -lc -lrt -lpthread -lm -lgcc -lc $extra_libs \
            "$sysroot/lib/crtn.o" 2>/tmp/selftest-err-$arch-$name.txt; then
            echo "  OK   $name"
            built=$((built + 1))
        else
            # Retry without helpers, and with -include to suppress struct conflicts
            if $cc -Wall -O2 -static -nostartfiles $extra_cflags \
                -isystem "$sysroot/include" \
                -I"$LINUX_SRC" -I"$LINUX_SRC/usr/include" \
                -I"$MM_DIR" -I"$KSFT_DIR" -L"$sysroot/lib" \
                -Wno-unused-function -Wno-unused-variable -D_GNU_SOURCE \
                -Wno-error -Wno-redundant-decls \
                -o "$outdir/$name" \
                "$sysroot/lib/crt1.o" "$sysroot/lib/crti.o" \
                "$src" \
                -lc -lrt -lpthread -lm -lgcc -lc $extra_libs \
                "$sysroot/lib/crtn.o" 2>/tmp/selftest-err2-$arch-$name.txt; then
                echo "  OK   $name (no helpers)"
                built=$((built + 1))
            else
                echo "  FAIL $name"
                tail -2 /tmp/selftest-err-$arch-$name.txt 2>/dev/null
                failed=$((failed + 1))
            fi
        fi
    done

    log "$arch: $built built, $failed failed"
    return 0
}

# ---- Main ----
main() {
    mkdir -p "$BUILD_BASE"
    ensure_local_config

    # Install kernel headers for selftests if not present
    if [ ! -f "$LINUX_SRC/usr/include/linux/mman.h" ]; then
        log "Installing kernel UAPI headers"
        make -C "$LINUX_SRC" headers_install -j$NPROC 2>&1 | tail -3
    fi

    local arches=("$@")
    if [ ${#arches[@]} -eq 0 ]; then
        arches=(x86_64 aarch64 riscv64 s390x powerpc64 sparc64 arm alpha hppa hppa64 loongarch64 riscv32 mips64 m68k microblaze)
    fi

    echo "Building mm selftests for: ${arches[*]}"
    echo ""

    for arch in "${arches[@]}"; do
        build_arch "$arch" || true
        echo ""
    done

    echo "========================================"
    echo "  Selftest Build Summary"
    echo "========================================"
    for arch in "${arches[@]}"; do
        local outdir="$BUILD_BASE/selftests-$arch"
        if [ -d "$outdir" ]; then
            local count
            count=$(find "$outdir" -maxdepth 1 -type f -executable 2>/dev/null | wc -l)
            echo "  $arch: $count binaries in $outdir"
        else
            echo "  $arch: NOT BUILT"
        fi
    done
}

main "$@"
