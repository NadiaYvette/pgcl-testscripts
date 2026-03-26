#!/bin/bash
#
# Build cross-architecture userspace for PGCL testing
#
# Usage: ./build-all.sh [ARCH...]
#   No args = build all supported architectures
#   With args = build only specified architectures
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_SRC=/home/nyc/src/linux
MUSL_SRC=/home/nyc/src/musl
BUSYBOX_SRC=/home/nyc/src/busybox
SYSROOT_BASE="$SCRIPT_DIR/sysroot"
BUILD_BASE="$SCRIPT_DIR/build"
INITRAMFS_DIR="$SCRIPT_DIR/initramfs"
PGCL_TEST_SRC="$SCRIPT_DIR/pgcl-test.c"
PGCL_STRESS_SRC="$SCRIPT_DIR/pgcl-stress.c"

NPROC=$(nproc)

# Architecture table:
#   ARCH_NAME  LINUX_ARCH  MUSL_ARCH  CROSS_PREFIX  MUSL_TARGET  DEFCONFIG  KERNEL_IMAGE
#
# MUSL_ARCH="" means no musl support (use nolibc)
declare -A ARCH_TABLE
# Format: "linux_arch|musl_arch|cross_prefix|musl_target|defconfig|kernel_image"
ARCH_TABLE=(
  [x86_64]="x86|x86_64||x86_64-linux-musl|x86_64_defconfig|arch/x86/boot/bzImage"
  [aarch64]="arm64|aarch64|aarch64-linux-gnu-|aarch64-linux-musl|defconfig|arch/arm64/boot/Image"
  [arm]="arm|arm|arm-linux-gnu-|arm-linux-musleabihf|multi_v7_defconfig|arch/arm/boot/zImage"
  [riscv64]="riscv|riscv64|riscv64-linux-gnu-|riscv64-linux-musl|defconfig|arch/riscv/boot/Image"
  [powerpc64]="powerpc|powerpc64|powerpc64-linux-gnu-|powerpc64-linux-musl|ppc64_defconfig|vmlinux"
  [s390x]="s390|s390x|s390x-linux-gnu-|s390x-linux-musl|defconfig|arch/s390/boot/bzImage"
  [mips64]="mips|mips64|mips64-linux-gnu-|mips64-linux-musl|malta_defconfig|vmlinux"
  [m68k]="m68k|m68k|m68k-linux-gnu-|m68k-linux-musl|multi_defconfig|vmlinux"
  [or1k]="openrisc|or1k|openrisc-linux-gnu-|or1k-linux-musl|simple_smp_defconfig|vmlinux"
  [microblaze]="microblaze|microblaze|microblaze-linux-gnu-|microblaze-linux-musl|defconfig|arch/microblaze/boot/linux.bin"
  [loongarch64]="loongarch|loongarch64|loongarch64-linux-gnu-|loongarch64-linux-musl|defconfig|arch/loongarch/boot/vmlinuz.efi"
  [sh4]="sh|sh|sh4-linux-gnu-|sh-linux-musl|rts7751r2dplus_defconfig|arch/sh/boot/zImage"
  [sparc64]="sparc|sparc64|sparc64-linux-gnu-|sparc64-linux-gnu|sparc64_defconfig|arch/sparc/boot/image"
  [alpha]="alpha|alpha|alpha-linux-gnu-|alpha-linux-gnu|defconfig|vmlinux"
  [hppa]="parisc|hppa|hppa-linux-gnu-|hppa-linux-gnu|generic-64bit_defconfig|vmlinux"
  [xtensa]="xtensa|NONE|xtensa-linux-gnu-||defconfig|arch/xtensa/boot/Image.elf"
)

# Per-architecture extra CFLAGS (e.g., for ISA compatibility with QEMU)
declare -A ARCH_CFLAGS
ARCH_CFLAGS=(
  [s390x]="-march=z196"
)

# QEMU commands per arch
declare -A QEMU_CMD
QEMU_CMD=(
  [x86_64]="qemu-system-x86_64 -M pc -m 1G -smp 4 -nographic -no-reboot"
  [aarch64]="qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1G -smp 4 -nographic -no-reboot"
  [arm]="qemu-system-arm -M virt -m 512M -nographic -no-reboot"
  [riscv64]="qemu-system-riscv64 -M virt -m 1G -smp 4 -nographic -no-reboot -bios default"
  [powerpc64]="qemu-system-ppc64 -M powernv -m 1G -smp 4 -nographic -no-reboot"
  [s390x]="qemu-system-s390x -m 1G -smp 1 -nographic -no-reboot -nodefaults -serial stdio"
  [mips64]="qemu-system-mips64 -M malta -m 1G -nographic -no-reboot"
  [m68k]="qemu-system-m68k -M virt -m 512M -nographic -no-reboot"
  [or1k]="qemu-system-or1k -M virt -m 128M -nographic -no-reboot"
  [microblaze]="qemu-system-microblaze -M petalogix-s3adsp1800 -m 64M -nographic -no-reboot"
  [loongarch64]="qemu-system-loongarch64 -M virt -m 1G -nographic -no-reboot"
  [sh4]="qemu-system-sh4 -M r2d -m 256M -serial null -serial mon:stdio -nographic -no-reboot"
  [sparc64]="qemu-system-sparc64 -M sun4u -m 1G -nographic -no-reboot"
  [alpha]="qemu-system-alpha -m 1G -nographic -no-reboot"
  [hppa]="qemu-system-hppa -m 1G -nographic -no-reboot"
  [xtensa]="qemu-system-xtensa -M lx60 -m 256M -nographic -no-reboot"
)

# Kernel cmdline per arch
declare -A QEMU_APPEND
QEMU_APPEND=(
  [x86_64]="console=ttyS0 nokaslr nopti panic=1"
  [aarch64]="console=ttyAMA0 panic=1"
  [arm]="console=ttyAMA0 panic=1"
  [riscv64]="console=ttyS0 panic=1"
  [powerpc64]="console=hvc0 panic=1"
  [s390x]="console=ttyS0 panic=1"
  [mips64]="console=ttyS0 panic=1"
  [m68k]="console=ttyGF0 panic=1"
  [or1k]=""
  [microblaze]="console=ttyUL0 panic=1"
  [loongarch64]="console=ttyS0,115200 panic=1"
  [sh4]="console=ttySC1,115200 noiotrap panic=1"
  [sparc64]="console=ttyS0 panic=1"
  [alpha]="console=ttyS0 panic=1"
  [hppa]="console=ttyS0 panic=1"
  [xtensa]="console=ttyS0,115200 panic=1"
)

log() { echo "=== $* ===" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }

parse_arch_info() {
    local arch="$1"
    IFS='|' read -r LINUX_ARCH MUSL_ARCH CROSS_PREFIX MUSL_TARGET DEFCONFIG KERNEL_IMAGE <<< "${ARCH_TABLE[$arch]}"
}

# ---- Step 1: Build musl sysroot for an architecture ----
build_musl() {
    local arch="$1"
    parse_arch_info "$arch"

    if [ "$MUSL_ARCH" = "NONE" ] || [ -z "$MUSL_ARCH" ]; then
        log "Skipping musl for $arch (no musl support)"
        return 1
    fi

    local sysroot="$SYSROOT_BASE/$MUSL_ARCH"
    if [ -f "$sysroot/lib/libc.a" ]; then
        log "musl sysroot for $arch already exists"
        return 0
    fi

    log "Building musl for $arch (musl_arch=$MUSL_ARCH)"
    mkdir -p "$sysroot"

    # Install kernel headers
    log "Installing kernel headers for $LINUX_ARCH"
    make -C "$LINUX_SRC" ARCH="$LINUX_ARCH" INSTALL_HDR_PATH="$sysroot" headers_install -j$NPROC 2>&1 | tail -3

    # Build musl
    local musl_build="$BUILD_BASE/musl-$MUSL_ARCH"
    rm -rf "$musl_build"
    mkdir -p "$musl_build"
    cd "$musl_build"

    local cc="${CROSS_PREFIX}gcc"
    if [ -z "$CROSS_PREFIX" ]; then cc="gcc"; fi

    "$MUSL_SRC/configure" \
        --prefix="$sysroot" \
        --target="$MUSL_TARGET" \
        CC="$cc" \
        CFLAGS="-O2 -fPIC" \
        --disable-shared 2>&1 | tail -5

    make -j$NPROC 2>&1 | tail -5
    make install 2>&1 | tail -3

    log "musl installed to $sysroot"
    cd "$SCRIPT_DIR"
    return 0
}

# ---- Step 2: Build busybox for an architecture ----
build_busybox() {
    local arch="$1"
    parse_arch_info "$arch"

    local sysroot="$SYSROOT_BASE/$MUSL_ARCH"
    local bb_build="$BUILD_BASE/busybox-$arch"
    local bb_bin="$bb_build/busybox"

    if [ -f "$bb_bin" ]; then
        log "busybox for $arch already exists"
        return 0
    fi

    if [ ! -f "$sysroot/lib/libc.a" ]; then
        log "No musl sysroot for $arch, skipping busybox"
        return 1
    fi

    log "Building busybox for $arch"
    rm -rf "$bb_build"

    local cc="${CROSS_PREFIX}gcc"
    if [ -z "$CROSS_PREFIX" ]; then cc="gcc"; fi

    make -C "$BUSYBOX_SRC" O="$bb_build" defconfig 2>&1 | tail -3
    cd "$bb_build"

    # Configure for static linking against musl
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i "s|CONFIG_CROSS_COMPILER_PREFIX=\"\"|CONFIG_CROSS_COMPILER_PREFIX=\"${CROSS_PREFIX}\"|" .config
    sed -i "s|CONFIG_SYSROOT=\"\"|CONFIG_SYSROOT=\"$sysroot\"|" .config
    sed -i "s|CONFIG_EXTRA_CFLAGS=\"\"|CONFIG_EXTRA_CFLAGS=\"-I$sysroot/include\"|" .config
    sed -i "s|CONFIG_EXTRA_LDFLAGS=\"\"|CONFIG_EXTRA_LDFLAGS=\"-L$sysroot/lib\"|" .config
    # Disable features that may cause build issues with musl
    "$BUSYBOX_SRC/scripts/config" --disable FEATURE_HAVE_RPC
    "$BUSYBOX_SRC/scripts/config" --disable FEATURE_INETD_RPC
    "$BUSYBOX_SRC/scripts/config" --disable FEATURE_MOUNT_NFS
    "$BUSYBOX_SRC/scripts/config" --disable NSENTER
    "$BUSYBOX_SRC/scripts/config" --disable FEATURE_UTMP
    "$BUSYBOX_SRC/scripts/config" --disable FEATURE_WTMP
    make oldconfig </dev/null 2>&1 | tail -3

    if ! make -j$NPROC 2>&1 | tail -10; then
        log "WARNING: busybox build failed for $arch, retrying with fewer features"
        "$BUSYBOX_SRC/scripts/config" --disable FEATURE_SH_STANDALONE
        "$BUSYBOX_SRC/scripts/config" --disable HUSH
        make oldconfig </dev/null 2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -10
    fi

    cd "$SCRIPT_DIR"

    if [ -f "$bb_bin" ]; then
        log "busybox built: $bb_bin ($(du -h "$bb_bin" | cut -f1))"
        return 0
    else
        log "WARNING: busybox binary not found at $bb_bin"
        return 1
    fi
}

# ---- Step 3: Build pgcl-test for an architecture ----
build_pgcl_test() {
    local arch="$1"
    parse_arch_info "$arch"

    local outbin="$BUILD_BASE/pgcl-test-$arch"

    if [ -f "$outbin" ]; then
        log "pgcl-test for $arch already exists"
        return 0
    fi

    local cc="${CROSS_PREFIX}gcc"
    if [ -z "$CROSS_PREFIX" ]; then cc="gcc"; fi

    local sysroot="$SYSROOT_BASE/$MUSL_ARCH"

    local extra_cflags="${ARCH_CFLAGS[$arch]:-}"

    if [ -f "$sysroot/lib/libc.a" ]; then
        log "Building pgcl-test for $arch"
        $cc -static -O2 $extra_cflags \
            -I"$sysroot/include" \
            -L"$sysroot/lib" \
            --sysroot="$sysroot" \
            -o "$outbin" "$PGCL_TEST_SRC" 2>&1
    else
        log "Building pgcl-test for $arch (nolibc)"
        # Use kernel nolibc — limited but works without musl
        $cc -static -O2 -nostdlib -nostdinc \
            -isystem "$LINUX_SRC/tools/include/nolibc" \
            -isystem "$LINUX_SRC/usr/include" \
            -include nolibc.h \
            -o "$outbin" "$SCRIPT_DIR/pgcl-test-nolibc.c" \
            -lgcc 2>&1 || {
            log "WARNING: pgcl-test build failed for $arch"
            return 1
        }
    fi

    if [ -f "$outbin" ]; then
        log "pgcl-test built: $outbin ($(du -h "$outbin" | cut -f1))"
        return 0
    else
        return 1
    fi
}

# ---- Step 3b: Build pgcl-stress for an architecture ----
build_pgcl_stress() {
    local arch="$1"
    parse_arch_info "$arch"

    local outbin="$BUILD_BASE/pgcl-stress-$arch"

    if [ -f "$outbin" ]; then
        log "pgcl-stress for $arch already exists"
        return 0
    fi

    if [ ! -f "$PGCL_STRESS_SRC" ]; then
        log "pgcl-stress.c not found, skipping"
        return 1
    fi

    local cc="${CROSS_PREFIX}gcc"
    if [ -z "$CROSS_PREFIX" ]; then cc="gcc"; fi

    local sysroot="$SYSROOT_BASE/$MUSL_ARCH"

    if [ -f "$sysroot/lib/libc.a" ]; then
        local pthread_flags="-lpthread"
        local extra_cflags="${ARCH_CFLAGS[$arch]:-}"
        log "Building pgcl-stress for $arch"
        $cc -static -O2 $extra_cflags \
            -I"$sysroot/include" \
            -L"$sysroot/lib" \
            --sysroot="$sysroot" \
            -o "$outbin" "$PGCL_STRESS_SRC" \
            $pthread_flags 2>&1
    else
        log "Skipping pgcl-stress for $arch (needs musl)"
        return 1
    fi

    if [ -f "$outbin" ]; then
        log "pgcl-stress built: $outbin ($(du -h "$outbin" | cut -f1))"
        return 0
    else
        return 1
    fi
}

# ---- Step 4: Create initramfs ----
create_initramfs() {
    local arch="$1"
    parse_arch_info "$arch"

    local outfile="$INITRAMFS_DIR/initramfs-$arch.cpio.gz"
    local bb_bin="$BUILD_BASE/busybox-$arch/busybox"
    local test_bin="$BUILD_BASE/pgcl-test-$arch"
    local initdir
    initdir=$(mktemp -d)

    log "Creating initramfs for $arch"
    mkdir -p "$initdir"/{bin,sbin,proc,sys,dev,tmp,etc,root}

    # Install busybox if available
    if [ -f "$bb_bin" ]; then
        cp "$bb_bin" "$initdir/bin/busybox"
        chmod +x "$initdir/bin/busybox"
        # Create symlinks for common commands
        for cmd in sh ash ls cat echo mount mkdir mknod grep sleep \
                   dmesg free ps top wc head tail stty getconf \
                   basename timeout uname \
                   poweroff reboot sysctl vi; do
            ln -sf busybox "$initdir/bin/$cmd"
        done
    fi

    # Install test binary if available
    if [ -f "$test_bin" ]; then
        cp "$test_bin" "$initdir/bin/pgcl-test"
        chmod +x "$initdir/bin/pgcl-test"
    fi

    # Install stress test binary if available
    local stress_bin="$BUILD_BASE/pgcl-stress-$arch"
    if [ -f "$stress_bin" ]; then
        cp "$stress_bin" "$initdir/bin/pgcl-stress"
        chmod +x "$initdir/bin/pgcl-stress"
    fi

    # Install mm selftests if available
    local selftest_dir="$BUILD_BASE/selftests-$arch"
    if [ -d "$selftest_dir" ]; then
        mkdir -p "$initdir/bin/mm-selftests"
        for t in "$selftest_dir"/*; do
            if [ -f "$t" ] && [ -x "$t" ]; then
                cp "$t" "$initdir/bin/mm-selftests/"
            fi
        done
    fi

    # Create device nodes (static fallback if devtmpfs unavailable)
    mknod "$initdir/dev/console" c 5 1 2>/dev/null || true
    mknod "$initdir/dev/null" c 1 3 2>/dev/null || true
    mknod "$initdir/dev/zero" c 1 5 2>/dev/null || true
    mknod "$initdir/dev/urandom" c 1 9 2>/dev/null || true
    mknod "$initdir/dev/ttyS0" c 4 64 2>/dev/null || true

    # Create init script
    cat > "$initdir/init" << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

echo "========================================"
echo " PGCL Boot Test - $(uname -m)"
echo "========================================"
echo "Kernel: $(uname -r)"

if command -v getconf >/dev/null 2>&1; then
    echo "Page size (AT_PAGESZ): $(getconf PAGESIZE)"
fi

if [ -f /proc/meminfo ]; then
    head -3 /proc/meminfo
fi

if [ -f /proc/cpuinfo ]; then
    echo "CPUs: $(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo unknown)"
fi

TOTAL_PASS=0
TOTAL_FAIL=0

echo ""
if [ -x /bin/pgcl-test ]; then
    echo "--- Running PGCL basic tests ---"
    /bin/pgcl-test
    [ $? -eq 0 ] && TOTAL_PASS=$((TOTAL_PASS+1)) || TOTAL_FAIL=$((TOTAL_FAIL+1))
    echo ""
fi

if [ -x /bin/pgcl-stress ]; then
    echo "--- Running PGCL stress tests ---"
    /bin/pgcl-stress
    [ $? -eq 0 ] && TOTAL_PASS=$((TOTAL_PASS+1)) || TOTAL_FAIL=$((TOTAL_FAIL+1))
    echo ""
fi

if [ -d /bin/mm-selftests ]; then
    echo "--- Running kernel mm selftests ---"
    # Check available RAM in MB for skipping memory-hungry tests
    AVAIL_MB=0
    if [ -f /proc/meminfo ]; then
        AVAIL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    fi
    for t in /bin/mm-selftests/*; do
        [ -x "$t" ] || continue
        name="${t##*/}"
        # Skip tests that are known-problematic in minimal initramfs
        case "$name" in
            droppable) echo "  $name: SKIP (OOM test)"; continue ;;
            mseal_test) echo "  $name: SKIP (requires root)"; continue ;;
            *.o) continue ;;  # skip .o helper files
        esac
        echo "  [$name]"
        "$t" 2>&1
        ret=$?
        if [ $ret -eq 0 ]; then
            echo "  $name: PASS"
            TOTAL_PASS=$((TOTAL_PASS+1))
        elif [ $ret -eq 4 ]; then
            echo "  $name: SKIP"
        else
            echo "  $name: FAIL (exit=$ret)"
            TOTAL_FAIL=$((TOTAL_FAIL+1))
        fi
        echo ""
    done
fi

echo "========================================"
echo " Test Summary: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "========================================"

# Check kernel log for problems
if [ -f /proc/kmsg ] || true; then
    if dmesg 2>/dev/null | grep -vE "command line:|panic=" | grep -qE "BUG:|BUG |Oops|panic|Bad page state|WARNING:"; then
        echo "WARNING: kernel log contains errors!"
        dmesg | grep -vE "command line:|panic=" | grep -E "BUG:|BUG |Oops|panic|Bad page state|WARNING:" | head -10
    fi
fi

echo ""
# In autotest mode, power off after tests
if grep -q "autotest=1" /proc/cmdline 2>/dev/null; then
    echo "Autotest mode: powering off."
    echo o > /proc/sysrq-trigger 2>/dev/null || true
    sleep 5
fi

# Drop to shell if available, else halt
if [ -x /bin/sh ]; then
    echo "Type 'poweroff -f' to exit QEMU."
    exec /bin/sh
else
    echo "No shell available. Powering off."
    sleep 2
    echo o > /proc/sysrq-trigger 2>/dev/null || true
fi
INITEOF
    chmod +x "$initdir/init"

    # Create cpio archive
    (cd "$initdir" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip) > "$outfile"
    rm -rf "$initdir"

    log "Created $outfile ($(du -h "$outfile" | cut -f1))"
}

# ---- Main ----
main() {
    mkdir -p "$SYSROOT_BASE" "$BUILD_BASE" "$INITRAMFS_DIR"

    # Determine which arches to build
    local arches=("$@")
    if [ ${#arches[@]} -eq 0 ]; then
        arches=(${!ARCH_TABLE[@]})
    fi

    # Sort for consistent ordering
    IFS=$'\n' arches=($(sort <<<"${arches[*]}")); unset IFS

    echo "Building userspace for: ${arches[*]}"
    echo ""

    local results=()

    for arch in "${arches[@]}"; do
        if [ -z "${ARCH_TABLE[$arch]}" ]; then
            echo "WARNING: unknown architecture '$arch', skipping"
            continue
        fi

        echo ""
        log "===== Processing $arch ====="

        local status="OK"

        # Build musl
        if build_musl "$arch"; then
            # Build busybox
            build_busybox "$arch" || status="no-busybox"

            # Build pgcl-test
            build_pgcl_test "$arch" || status="no-pgcl-test"

            # Build pgcl-stress
            build_pgcl_stress "$arch" || true
        else
            status="no-musl"
            # Try nolibc pgcl-test
            build_pgcl_test "$arch" || status="no-userspace"
        fi

        # Create initramfs (even with partial results)
        create_initramfs "$arch"

        results+=("$arch: $status")
    done

    echo ""
    echo "========================================"
    echo "  Build Summary"
    echo "========================================"
    for r in "${results[@]}"; do
        echo "  $r"
    done
}

main "$@"
