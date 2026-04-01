#!/bin/bash
# Cross-compile LTP mm tests for all architectures
# Usage: ./build-ltp-cross.sh [arch...]
# If no arch specified, builds for all arches with sysroots

set -e

LTP_SRC="${LTP_SRC:-$HOME/src/ltp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# Architecture → cross-compiler mapping
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
    [powerpc64]="powerpc64"
    [mips64]="mips64"
    [sparc64]="sparc64"
    [alpha]="alpha"
    [m68k]="m68k"
    [loongarch64]="loongarch64"
    [arm]="arm"
    [microblaze]="microblaze"
    [hppa]="hppa"
    [hppa64]="hppa64"
    [riscv32]="riscv32"
)

# MM-relevant test directories
MM_SYSCALL_TESTS=(
    mmap mremap mprotect madvise mincore msync
    mlock mlock2 mlockall munlock munlockall
    munmap brk sbrk fork
)
MM_MEM_TESTS=(
    mmapstress mtest06 vma
)

build_arch() {
    local arch="$1"
    local cross="${CROSS_TABLE[$arch]}"
    local sysroot_name="${SYSROOT_TABLE[$arch]}"
    local sysroot="$SCRIPT_DIR/sysroot/$sysroot_name"
    local outdir="$BUILD_DIR/ltp-$arch"
    local cc="${cross}gcc"

    if [ -z "$sysroot_name" ]; then
        echo "  SKIP: no sysroot mapping for $arch"
        return 0
    fi

    if [ ! -d "$sysroot" ]; then
        echo "  SKIP: sysroot not found: $sysroot"
        return 0
    fi

    if ! command -v "$cc" >/dev/null 2>&1; then
        echo "  SKIP: compiler not found: $cc"
        return 0
    fi

    local cflags="-static -O2 -w -D_GNU_SOURCE -Wno-error=incompatible-pointer-types -Wno-error=int-conversion"
    local ldextra=""
    # ppc64 musl sysroot uses ELFv2 ABI; gcc ships ELFv1 CRT
    if [ "$arch" = "powerpc64" ]; then
        cflags="$cflags -mabi=elfv2"
        ldextra="-nostartfiles $sysroot/lib/crt1.o $sysroot/lib/crti.o"
    fi
    if [ "$arch" = "riscv32" ]; then
        cflags="$cflags -march=rv32imac -mabi=ilp32"
    fi
    cflags="$cflags -isystem $sysroot/include"
    cflags="$cflags --sysroot=$sysroot"
    cflags="$cflags -I$LTP_SRC/include -I$LTP_SRC/include/old"

    echo "=== Building LTP for $arch ==="
    mkdir -p "$outdir"

    local built=0 failed=0

    link_test() {
        local out="$1"; shift
        local src="$1"; shift
        if [ -n "$ldextra" ]; then
            $cc $cflags $ldextra "$src" "$LTP_SRC/lib/libltp.a" -lpthread -lc -lgcc "$sysroot/lib/crtn.o" -o "$out" 2>/dev/null
        else
            $cc $cflags -o "$out" "$src" "$LTP_SRC/lib/libltp.a" -lpthread 2>/dev/null
        fi
    }

    # Build syscall tests
    for dir in "${MM_SYSCALL_TESTS[@]}"; do
        local srcdir="$LTP_SRC/testcases/kernel/syscalls/$dir"
        [ -d "$srcdir" ] || continue
        for src in "$srcdir"/*.c; do
            [ -f "$src" ] || continue
            local name
            name="$(basename "${src%.c}")"
            if link_test "$outdir/$name" "$src"; then
                built=$((built+1))
            else
                failed=$((failed+1))
            fi
        done
    done

    # Build mem tests
    for dir in "${MM_MEM_TESTS[@]}"; do
        local srcdir="$LTP_SRC/testcases/kernel/mem/$dir"
        [ -d "$srcdir" ] || continue
        for src in "$srcdir"/*.c; do
            [ -f "$src" ] || continue
            local name
            name="$(basename "${src%.c}")"
            if link_test "$outdir/$name" "$src"; then
                built=$((built+1))
            else
                failed=$((failed+1))
            fi
        done
    done

    ${cross}strip "$outdir"/* 2>/dev/null || true
    local count
    count=$(ls "$outdir" 2>/dev/null | wc -l)
    local size
    size=$(du -sh "$outdir" 2>/dev/null | cut -f1)
    echo "  Built $built/$((built+failed)) binaries ($size) → $outdir"
}

# Build a minimal libltp.a directly (bypasses LTP's fragile Makefile)
# Only compiles files needed by mm tests
LTP_LIB_SOURCES=(
    cloner.c get_path.c parse_opts.c random_range.c
    safe_file_ops.c safe_macros.c safe_stdio.c safe_pthread.c
    tst_ansi_color.c tst_assert.c tst_buffers.c tst_capability.c
    tst_cgroup.c tst_checkpoint.c tst_checksum.c tst_clocks.c
    tst_clone.c tst_cmd.c tst_coredump.c tst_cpu.c tst_device.c
    tst_dir_is_empty.c tst_epoll.c tst_fd.c tst_fill_file.c
    tst_fips.c tst_fs_type.c tst_hugepage.c tst_ioctl.c
    tst_kconfig.c tst_kernel.c tst_kvercmp.c tst_lockdown.c
    tst_memutils.c tst_mkfs.c tst_module.c tst_net.c tst_netdevice.c
    tst_parse_filesize.c tst_path_has_mnt_flags.c tst_pid.c
    tst_process_state.c tst_rand_data.c tst_res.c tst_resource.c
    tst_safe_file_at.c tst_safe_macros.c tst_safe_timerfd.c
    tst_security.c tst_sig_op.c tst_status.c tst_supported_fs_types.c
    tst_sys_conf.c tst_taint.c tst_test.c tst_timer.c tst_timer_test.c
    tst_tmpdir.c tst_uid.c tst_wallclock.c tst_rtctime.c tst_crypto.c
    tst_arch.c tst_bool_expr.c tst_af_alg.c
    tst_fs_setup.c tst_virt.c safe_net.c
    tst_sig.c tst_parse_opts.c tst_test_macros.c
    tst_get_bad_addr.c tst_sig_proc.c tst_thread_state.c
    tst_path_exists.c tst_fill_fs.c tst_fs_has_free.c
    tst_fs_link_count.c tst_netlink.c tst_safe_file_ops.c
    tst_safe_io_uring.c tst_safe_sysv_ipc.c tlibio.c
)

reconfigure_ltp() {
    local arch="$1"
    local cross="${CROSS_TABLE[$arch]}"
    local sysroot_name="${SYSROOT_TABLE[$arch]}"
    local sysroot="$SCRIPT_DIR/sysroot/$sysroot_name"
    local cc="${cross}gcc"
    local ar="${cross}ar"
    local ranlib="${cross}ranlib"

    local cflags="-static -O2 -w -D_GNU_SOURCE -DLTPLIB -Wno-error -fpermissive -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-implicit-function-declaration"
    [ "$arch" = "powerpc64" ] && cflags="$cflags -mabi=elfv2"
    [ "$arch" = "riscv32" ] && cflags="$cflags -march=rv32imac -mabi=ilp32"
    cflags="$cflags -isystem $sysroot/include --sysroot=$sysroot"
    cflags="$cflags -I$LTP_SRC/include -I$LTP_SRC/include/old"

    local tmpdir="/tmp/ltp-lib-$arch"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"

    local built=0 failed=0
    for src in "${LTP_LIB_SOURCES[@]}"; do
        local srcpath="$LTP_SRC/lib/$src"
        [ -f "$srcpath" ] || continue
        local obj="$tmpdir/${src%.c}.o"
        if $cc $cflags -c "$srcpath" -o "$obj" 2>/dev/null; then
            built=$((built+1))
        else
            failed=$((failed+1))
        fi
    done

    # Create archive from whatever compiled
    rm -f "$LTP_SRC/lib/libltp.a"
    $ar rcs "$LTP_SRC/lib/libltp.a" "$tmpdir"/*.o 2>/dev/null
    $ranlib "$LTP_SRC/lib/libltp.a" 2>/dev/null
    rm -rf "$tmpdir"

    if [ -f "$LTP_SRC/lib/libltp.a" ]; then
        echo "  libltp.a: $built/$((built+failed)) objects for $arch"
        return 0
    else
        echo "  ERROR: libltp.a build failed for $arch"
        return 1
    fi
}

# Parse arguments
if [ $# -gt 0 ]; then
    ARCHES=("$@")
else
    # All arches with sysroots
    ARCHES=(x86_64 aarch64 riscv64 s390x powerpc64 mips64 sparc64 alpha m68k loongarch64 arm microblaze)
fi

for arch in "${ARCHES[@]}"; do
    if [ -z "${CROSS_TABLE[$arch]+x}" ]; then
        echo "Unknown arch: $arch"
        continue
    fi

    echo ""
    echo ">>> Configuring LTP for $arch..."
    if reconfigure_ltp "$arch"; then
        build_arch "$arch"
    fi
done

echo ""
echo "=== LTP cross-compile complete ==="
for arch in "${ARCHES[@]}"; do
    local_count=$(ls "$BUILD_DIR/ltp-$arch" 2>/dev/null | wc -l)
    echo "  $arch: $local_count binaries"
done
