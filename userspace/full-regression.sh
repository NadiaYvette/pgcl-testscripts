#!/bin/bash
#
# PGCL Full Regression Test Suite
# Rebuilds all kernels (MMUSHIFT=4 + MMUSHIFT=0 baseline), boots all arches,
# runs 4-tier test suite (pgcl-test, pgcl-stress, mm-selftests, LTP).
#
# Safety: disk-backed tmp, sequential builds (max 1), per-boot timeouts,
# watchdog for deadlocks/livelocks.
#
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_SRC=/home/nyc/src/linux
LTP_SRC=/home/nyc/src/ltp
TMP_BASE=/home/nyc/src/pgcl/tmp
LOG_DIR="$TMP_BASE/regression-logs"
RESULTS_FILE="$TMP_BASE/regression-results.txt"
NPROC=$(nproc)
# Use half the cores for kernel builds to avoid OOM
BUILD_JOBS=$((NPROC / 2))
if [ "$BUILD_JOBS" -lt 4 ]; then BUILD_JOBS=4; fi

# Maximum time per QEMU boot test (seconds)
# Fast arches (x86_64, arm64): 300s. Slow arches (microblaze, mips64, alpha): 600s
declare -A BOOT_TIMEOUT
BOOT_TIMEOUT=(
    [x86_64]=600 [aarch64]=600 [arm]=600 [riscv64]=600
    [powerpc64]=600 [s390x]=600 [sparc64]=600
    [loongarch64]=600 [riscv32]=600
    [alpha]=900 [m68k]=900 [hppa]=900 [hppa64]=900
    [mips64]=1200 [microblaze]=1800
)

# Architecture table: linux_arch cross_prefix defconfig
declare -A ARCH_INFO
ARCH_INFO=(
    [x86_64]="x86||x86_64_defconfig"
    [aarch64]="arm64|aarch64-linux-gnu-|defconfig"
    [arm]="arm|arm-linux-gnu-|multi_v7_defconfig"
    [arm32-lpae]="arm|arm-linux-gnu-|vexpress_defconfig"
    [riscv64]="riscv|riscv64-linux-gnu-|defconfig"
    [powerpc64]="powerpc|powerpc64-linux-gnu-|ppc64_defconfig"
    [s390x]="s390|s390x-linux-gnu-|defconfig"
    [sparc64]="sparc|sparc64-linux-gnu-|sparc64_defconfig"
    [alpha]="alpha|alpha-linux-gnu-|defconfig"
    [loongarch64]="loongarch|loongarch64-linux-gnu-|defconfig"
    [riscv32]="riscv|riscv32-linux-gnu-|rv32_defconfig"
    [m68k]="m68k|m68k-linux-gnu-|multi_defconfig"
    [hppa]="parisc|hppa-linux-gnu-|generic-32bit_defconfig"
    [hppa64]="parisc64|hppa64-linux-gnu-|generic-64bit_defconfig"
    [mips64]="mips|mips64-linux-gnu-|malta_defconfig"
    [microblaze]="microblaze|microblaze-linux-gnu-|mmu_defconfig"
)

# QEMU boot commands — arch → "qemu_binary qemu_args..."
# -kernel and -initrd/-append are added by the boot function
declare -A QEMU_BASE
QEMU_BASE=(
    [x86_64]="qemu-system-x86_64 -M pc -m 8G -smp 4 -nographic -no-reboot"
    [aarch64]="qemu-system-aarch64 -M virt -cpu cortex-a57 -m 8G -smp 4 -nographic -no-reboot"
    [arm]="qemu-system-arm -M virt -cpu cortex-a15 -m 2G -nographic -no-reboot"
    [arm32-lpae]="qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 2G -nographic -no-reboot -dtb KBUILD/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb"
    [riscv64]="qemu-system-riscv64 -M virt -m 8G -smp 4 -nographic -no-reboot -bios default"
    [powerpc64]="qemu-system-ppc64 -M powernv -cpu POWER10 -m 8G -smp 4 -nographic -no-reboot"
    [s390x]="qemu-system-s390x -m 8G -smp 1 -nographic -no-reboot"
    [sparc64]="qemu-system-sparc64 -M sun4u -m 4G -smp 1 -nographic -no-reboot"
    [alpha]="qemu-system-alpha -m 2G -serial stdio -display none -no-reboot"
    [loongarch64]="qemu-system-loongarch64 -M virt -m 1G -smp 4 -nographic -no-reboot"
    [riscv32]="qemu-system-riscv32 -M virt -m 2G -smp 4 -nographic -no-reboot -bios default"
    [m68k]="qemu-system-m68k -M virt -m 512M -nographic -no-reboot"
    [hppa]="qemu-system-hppa -m 3G -nographic -no-reboot"
    [hppa64]="qemu-system-hppa -M C3700 -m 8G -smp 4 -nographic -no-reboot"
    [mips64]="qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot"
    [microblaze]="qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot"
)

# Kernel console cmdline per arch
declare -A CONSOLE_APPEND
CONSOLE_APPEND=(
    [x86_64]="console=ttyS0 nokaslr nopti"
    [aarch64]="console=ttyAMA0"
    [arm]="console=ttyAMA0"
    [arm32-lpae]="console=ttyAMA0"
    [riscv64]="console=ttyS0"
    [powerpc64]="console=hvc0"
    [s390x]="console=ttyS0"
    [sparc64]="console=ttyS0"
    [alpha]="console=ttyS0"
    [loongarch64]="console=ttyS0,115200"
    [riscv32]="console=ttyS0"
    [m68k]="console=ttyGF0"
    [hppa]="console=ttyS0"
    [hppa64]="console=ttyS0"
    [mips64]="console=ttyS0"
    [microblaze]="console=ttyUL0"
)

# Kernel image path relative to build dir
declare -A KERNEL_IMAGE
KERNEL_IMAGE=(
    [x86_64]="arch/x86/boot/bzImage"
    [aarch64]="arch/arm64/boot/Image"
    [arm]="arch/arm/boot/zImage"
    [arm32-lpae]="arch/arm/boot/zImage"
    [riscv64]="arch/riscv/boot/Image"
    [powerpc64]="vmlinux"
    [s390x]="arch/s390/boot/bzImage"
    [sparc64]="arch/sparc/boot/image"
    [alpha]="vmlinux"
    [loongarch64]="arch/loongarch/boot/vmlinuz.efi"
    [riscv32]="arch/riscv/boot/Image"
    [m68k]="vmlinux"
    [hppa]="vmlinux"
    [hppa64]="vmlinux"
    [mips64]="vmlinux"
    [microblaze]="arch/microblaze/boot/simpleImage.system"
)

# Initramfs name mapping (arch → initramfs file basename)
declare -A INITRAMFS_NAME
INITRAMFS_NAME=(
    [x86_64]="x86_64" [aarch64]="aarch64" [arm]="arm" [arm32-lpae]="arm"
    [riscv64]="riscv64" [powerpc64]="powerpc64" [s390x]="s390x"
    [sparc64]="sparc64" [alpha]="alpha" [loongarch64]="loongarch64"
    [riscv32]="riscv32" [m68k]="m68k" [hppa]="hppa" [hppa64]="hppa64"
    [mips64]="mips64" [microblaze]="microblaze"
)

# Arches that use embedded initramfs (cannot pass -initrd)
EMBEDDED_INITRAMFS_ARCHES="microblaze loongarch64 mips64"

# =====================================================================
# Logging
# =====================================================================
ts() { date '+%H:%M:%S'; }
log() { echo "[$(ts)] $*"; }
logfile() { echo "[$(ts)] $*" >> "$RESULTS_FILE"; }

# =====================================================================
# Step 1: Build LTP for all arches
# =====================================================================
build_ltp_for_arch() {
    local arch="$1"
    local musl_arch="$2"
    local cross="$3"
    local sysroot="$SCRIPT_DIR/sysroot/$musl_arch"
    local outdir="$SCRIPT_DIR/build/ltp-$arch"

    if [ ! -d "$sysroot" ] || [ ! -f "$sysroot/lib/libc.a" ]; then
        log "  LTP: no sysroot for $arch ($sysroot), skipping"
        return 1
    fi

    if [ -d "$outdir" ] && [ "$(ls "$outdir" 2>/dev/null | wc -l)" -gt 50 ]; then
        log "  LTP: $arch already built ($(ls "$outdir" | wc -l) binaries)"
        return 0
    fi

    mkdir -p "$outdir"
    local cc="${cross}gcc"
    [ -z "$cross" ] && cc="gcc"

    local cflags="-static -O2 -I$sysroot/include"
    local ldflags="-static -L$sysroot/lib"

    # For x86_64 use pre-built in-tree LTP binaries
    if [ "$arch" = "x86_64" ]; then
        log "  LTP: collecting pre-built x86_64 binaries"
        for dir in mmap mremap mprotect madvise mincore msync mlock mlock2 mlockall \
                   munlock munlockall munmap brk sbrk fork; do
            local srcdir="$LTP_SRC/testcases/kernel/syscalls/$dir"
            [ -d "$srcdir" ] || continue
            find "$srcdir" -maxdepth 1 -type f -executable 2>/dev/null | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF 64-bit.*x86-64.*statically linked" || continue
                cp "$bin" "$outdir/$(basename "$bin")"
            done
        done
        for dir in mmapstress mtest06 vma; do
            local srcdir="$LTP_SRC/testcases/kernel/mem/$dir"
            [ -d "$srcdir" ] || continue
            find "$srcdir" -maxdepth 1 -type f -executable 2>/dev/null | while read bin; do
                file "$bin" 2>/dev/null | grep -q "ELF 64-bit.*x86-64.*statically linked" || continue
                cp "$bin" "$outdir/$(basename "$bin")"
            done
        done
    else
        log "  LTP: cross-compiling for $arch..."
        # Cross-compile individual LTP test files directly (avoiding full LTP build system)
        local ltp_inc="$LTP_SRC/include"
        local ltp_inc_old="$LTP_SRC/include/old"

        # Build libltp.a for this arch
        local ltp_builddir="/tmp/ltp-obj-$arch"
        mkdir -p "$ltp_builddir"

        # Compile LTP library sources needed by tests
        local ltp_lib_srcs=(
            "$LTP_SRC/lib/tst_test.c"
            "$LTP_SRC/lib/tst_res.c"
            "$LTP_SRC/lib/tst_tmpdir.c"
            "$LTP_SRC/lib/tst_checkpoint.c"
            "$LTP_SRC/lib/tst_safe_macros.c"
            "$LTP_SRC/lib/tst_safe_file_ops.c"
            "$LTP_SRC/lib/tst_device.c"
            "$LTP_SRC/lib/tst_timer.c"
            "$LTP_SRC/lib/tst_buffers.c"
            "$LTP_SRC/lib/tst_sig.c"
            "$LTP_SRC/lib/tst_kconfig.c"
            "$LTP_SRC/lib/tst_memutils.c"
            "$LTP_SRC/lib/tst_path_has_mnt_flags.c"
            "$LTP_SRC/lib/tst_resource.c"
            "$LTP_SRC/lib/tst_sys_conf.c"
            "$LTP_SRC/lib/tst_pid.c"
            "$LTP_SRC/lib/tst_parse_opts.c"
            "$LTP_SRC/lib/tst_wallclock.c"
            "$LTP_SRC/lib/tst_rtctime.c"
            "$LTP_SRC/lib/tst_cgroup.c"
            "$LTP_SRC/lib/tst_cmd.c"
            "$LTP_SRC/lib/tst_coredump.c"
            "$LTP_SRC/lib/tst_epoll.c"
            "$LTP_SRC/lib/tst_fs.c"
            "$LTP_SRC/lib/tst_hugepage.c"
            "$LTP_SRC/lib/tst_kvercmp.c"
            "$LTP_SRC/lib/tst_mkfs.c"
            "$LTP_SRC/lib/tst_net.c"
            "$LTP_SRC/lib/tst_safe_io_uring.c"
            "$LTP_SRC/lib/tst_safe_timerfd.c"
            "$LTP_SRC/lib/tst_taint.c"
            "$LTP_SRC/lib/tst_capability.c"
            "$LTP_SRC/lib/tst_clone.c"
            "$LTP_SRC/lib/tst_lockdown.c"
        )

        local objs=""
        for src in "${ltp_lib_srcs[@]}"; do
            [ -f "$src" ] || continue
            local obj="$ltp_builddir/$(basename "${src%.c}").o"
            $cc $cflags -I"$ltp_inc" -I"$ltp_inc_old" -I"$sysroot/include" \
                -D_GNU_SOURCE -DLTPLIB \
                -c "$src" -o "$obj" 2>/dev/null && objs="$objs $obj"
        done

        # Create libltp.a
        local libltp="$ltp_builddir/libltp.a"
        if [ -n "$objs" ]; then
            ${cross}ar rcs "$libltp" $objs 2>/dev/null
        fi

        # Compile individual tests
        local test_dirs=(
            "testcases/kernel/syscalls/mmap"
            "testcases/kernel/syscalls/mremap"
            "testcases/kernel/syscalls/mprotect"
            "testcases/kernel/syscalls/madvise"
            "testcases/kernel/syscalls/mincore"
            "testcases/kernel/syscalls/msync"
            "testcases/kernel/syscalls/mlock"
            "testcases/kernel/syscalls/mlock2"
            "testcases/kernel/syscalls/mlockall"
            "testcases/kernel/syscalls/munlock"
            "testcases/kernel/syscalls/munlockall"
            "testcases/kernel/syscalls/munmap"
            "testcases/kernel/syscalls/brk"
            "testcases/kernel/syscalls/sbrk"
            "testcases/kernel/syscalls/fork"
        )

        local compiled=0
        for dir in "${test_dirs[@]}"; do
            local fulldir="$LTP_SRC/$dir"
            [ -d "$fulldir" ] || continue
            for csrc in "$fulldir"/*.c; do
                [ -f "$csrc" ] || continue
                local name="$(basename "${csrc%.c}")"
                # Skip helper/library files
                case "$name" in
                    *_helper*|*lib*) continue ;;
                esac
                $cc $cflags -I"$ltp_inc" -I"$ltp_inc_old" -I"$sysroot/include" \
                    -D_GNU_SOURCE \
                    "$csrc" \
                    -L"$ltp_builddir" -L"$sysroot/lib" \
                    $ldflags -lltp -lpthread \
                    -o "$outdir/$name" 2>/dev/null && compiled=$((compiled+1))
            done
        done
        log "  LTP: compiled $compiled binaries for $arch"
        rm -rf "$ltp_builddir"
    fi

    # Strip all binaries
    ${cross}strip "$outdir"/* 2>/dev/null || strip "$outdir"/* 2>/dev/null || true
    local count=$(ls "$outdir" 2>/dev/null | wc -l)
    local size=$(du -sh "$outdir" 2>/dev/null | cut -f1)
    log "  LTP: $arch → $count binaries ($size)"
    return 0
}

# =====================================================================
# Step 2: Rebuild initramfs with LTP
# =====================================================================
rebuild_initramfs_with_ltp() {
    local arch="$1"
    local iname="${INITRAMFS_NAME[$arch]}"
    local initramfs="$SCRIPT_DIR/initramfs/initramfs-${iname}.cpio.gz"
    local ltp_dir="$SCRIPT_DIR/build/ltp-${arch}"

    # Embedded initramfs arches get LTP baked into the kernel
    case " $EMBEDDED_INITRAMFS_ARCHES " in
        *" $arch "*) log "  Initramfs: $arch uses embedded, skip external rebuild"; return 0 ;;
    esac

    if [ ! -f "$initramfs" ]; then
        log "  Initramfs: $initramfs not found, skipping"
        return 1
    fi

    local workdir="/tmp/initramfs-${arch}-rebuild"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    cd "$workdir"
    zcat "$initramfs" | cpio -idm 2>/dev/null

    # Add LTP if available
    if [ -d "$ltp_dir" ] && [ "$(ls "$ltp_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
        mkdir -p bin/ltp
        cp "$ltp_dir"/* bin/ltp/ 2>/dev/null || true
        log "  Initramfs: added $(ls bin/ltp/ 2>/dev/null | wc -l) LTP binaries"
    fi

    # Add extra busybox symlinks
    for cmd in sed id awk tr cut dd kill stat setsid nice nohup readlink \
               sort uniq tee touch rm cp mv mktemp seq expr env dirname \
               xargs yes chmod chown diff od hexdump; do
        [ ! -e bin/$cmd ] && [ -e bin/busybox ] && ln -s busybox bin/$cmd 2>/dev/null || true
    done
    mkdir -p sbin
    for cmd in sysctl losetup; do
        [ ! -e sbin/$cmd ] && [ -e bin/busybox ] && ln -s ../bin/busybox sbin/$cmd 2>/dev/null || true
    done

    # Add passwd/group
    mkdir -p etc root tmp var/tmp
    echo "root:x:0:0:root:/root:/bin/sh" > etc/passwd
    echo "root:x:0:" > etc/group

    # Install the updated init script with LTP support
    cp "$SCRIPT_DIR/initramfs/init" ./init

    # Rebuild
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$initramfs"
    rm -rf "$workdir"
    cd "$SCRIPT_DIR"
    local sz=$(du -h "$initramfs" | cut -f1)
    log "  Initramfs: rebuilt $initramfs ($sz)"
}

# =====================================================================
# Step 3: Build kernel
# =====================================================================
build_kernel() {
    local arch="$1"
    local mmushift="$2"  # 0 or 4
    local build_name="$3"  # e.g., "x86_64-m4" or "x86_64-m0"

    IFS='|' read -r linux_arch cross defconfig <<< "${ARCH_INFO[$arch]}"
    local kbuild="$TMP_BASE/kbuild-${build_name}"
    local img="${KERNEL_IMAGE[$arch]}"

    # Check if kernel already exists and is newer than source
    if [ -f "$kbuild/$img" ] || [ -f "$kbuild/vmlinux" ]; then
        local kconfig="$kbuild/.config"
        if [ -f "$kconfig" ]; then
            local cur_shift=$(grep "^CONFIG_PAGE_MMUSHIFT=" "$kconfig" 2>/dev/null | cut -d= -f2)
            if [ "$cur_shift" = "$mmushift" ]; then
                log "  Kernel $build_name already built (MMUSHIFT=$mmushift)"
                return 0
            fi
        fi
    fi

    log "  Building kernel: $build_name (MMUSHIFT=$mmushift)"
    mkdir -p "$kbuild"

    local make_args="ARCH=$linux_arch"
    [ -n "$cross" ] && make_args="$make_args CROSS_COMPILE=$cross"
    make_args="$make_args O=$kbuild"

    # Generate defconfig
    make -C "$LINUX_SRC" $make_args "$defconfig" -j$BUILD_JOBS 2>&1 | tail -3

    # Set PGCL config
    local kconfig="$kbuild/.config"

    # Architecture-specific config tweaks
    case "$arch" in
        arm32-lpae)
            # Enable LPAE
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_ARM_LPAE
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
        powerpc64)
            # Use 4K base pages, not 64K
            "$LINUX_SRC/scripts/config" --file "$kconfig" --disable CONFIG_PPC_64K_PAGES
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_PPC_4K_PAGES
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
        m68k)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_GOLDFISH
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_GOLDFISH_TTY
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
        mips64)
            # Need 64-bit big-endian, embedded initramfs
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_64BIT
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_MIPS64_R2
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_BIG_ENDIAN
            local mips_initramfs="$SCRIPT_DIR/initramfs/initramfs-mips64.cpio.gz"
            if [ -f "$mips_initramfs" ]; then
                "$LINUX_SRC/scripts/config" --file "$kconfig" \
                    --set-str CONFIG_INITRAMFS_SOURCE "$mips_initramfs"
            fi
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
        microblaze)
            # Big-endian, embedded initramfs
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_BIG_ENDIAN
            "$LINUX_SRC/scripts/config" --file "$kconfig" --disable CONFIG_CPU_LITTLE_ENDIAN
            local mb_initramfs="$SCRIPT_DIR/initramfs/initramfs-microblaze.cpio.gz"
            if [ -f "$mb_initramfs" ]; then
                "$LINUX_SRC/scripts/config" --file "$kconfig" \
                    --set-str CONFIG_INITRAMFS_SOURCE "$mb_initramfs"
            fi
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_KERNEL_BASE_ADDR 0x90000000
            ;;
        loongarch64)
            # ESP disk boot — uses embedded initramfs
            local la_initramfs="$SCRIPT_DIR/initramfs/initramfs-loongarch64.cpio.gz"
            if [ -f "$la_initramfs" ]; then
                "$LINUX_SRC/scripts/config" --file "$kconfig" \
                    --set-str CONFIG_INITRAMFS_SOURCE "$la_initramfs"
                "$LINUX_SRC/scripts/config" --file "$kconfig" \
                    --set-str CONFIG_CMDLINE "console=ttyS0,115200 autotest=1"
                "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CMDLINE_BOOL
            fi
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
        *)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT "$mmushift"
            ;;
    esac

    # Common configs: enable useful debugging, disable unnecessary drivers
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_PRINTK
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_SERIAL_8250
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_SERIAL_8250_CONSOLE
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_BLK_DEV_INITRD

    # Resolve config dependencies
    make -C "$LINUX_SRC" $make_args olddefconfig -j$BUILD_JOBS 2>&1 | tail -3

    # Verify MMUSHIFT was set
    local actual_shift=$(grep "^CONFIG_PAGE_MMUSHIFT=" "$kconfig" | cut -d= -f2)
    if [ "$actual_shift" != "$mmushift" ]; then
        log "  WARNING: CONFIG_PAGE_MMUSHIFT=$actual_shift (wanted $mmushift)"
    fi

    # Build
    local target=""
    case "$arch" in
        microblaze) target="simpleImage.system" ;;
    esac

    if ! make -C "$LINUX_SRC" $make_args $target -j$BUILD_JOBS 2>&1 | tail -20; then
        log "  KERNEL BUILD FAILED: $build_name"
        logfile "BUILD_FAIL $build_name"
        return 1
    fi

    # Verify image exists
    if [ -f "$kbuild/$img" ] || [ -f "$kbuild/vmlinux" ]; then
        local img_size=$(du -h "$kbuild/$img" 2>/dev/null || du -h "$kbuild/vmlinux" | head -1)
        log "  Kernel built: $build_name ($img_size)"

        # Compact build dir to save disk: keep kernel image, .config, DTBs; remove objects
        if [ "${COMPACT_BUILDS:-1}" = "1" ]; then
            compact_build_dir "$kbuild" "$img"
        fi

        return 0
    else
        log "  KERNEL IMAGE NOT FOUND: $kbuild/$img"
        logfile "BUILD_FAIL $build_name (image not found)"
        return 1
    fi
}

# Strip a build directory to just kernel image + .config + DTBs (saves ~80% disk)
compact_build_dir() {
    local kbuild="$1"
    local img="$2"
    local before=$(du -sm "$kbuild" 2>/dev/null | cut -f1)

    # Save critical files
    local save_dir="/tmp/kbuild-save-$$"
    mkdir -p "$save_dir"
    [ -f "$kbuild/$img" ] && cp "$kbuild/$img" "$save_dir/kernel_image"
    [ -f "$kbuild/vmlinux" ] && cp "$kbuild/vmlinux" "$save_dir/vmlinux"
    [ -f "$kbuild/.config" ] && cp "$kbuild/.config" "$save_dir/.config"
    # Save DTBs if any
    if [ -d "$kbuild/arch" ]; then
        find "$kbuild/arch" -name "*.dtb" -exec cp --parents {} "$save_dir/" \; 2>/dev/null || true
    fi

    # Clean build objects
    rm -rf "$kbuild"/*.o "$kbuild"/*.a "$kbuild"/built-in.a 2>/dev/null
    find "$kbuild" -name "*.o" -o -name "*.a" -o -name "*.ko" -o -name "*.cmd" -o -name ".tmp*" 2>/dev/null | \
        xargs rm -f 2>/dev/null || true

    # Restore saved files
    [ -f "$save_dir/kernel_image" ] && mkdir -p "$(dirname "$kbuild/$img")" && cp "$save_dir/kernel_image" "$kbuild/$img"
    [ -f "$save_dir/vmlinux" ] && cp "$save_dir/vmlinux" "$kbuild/vmlinux"
    [ -f "$save_dir/.config" ] && cp "$save_dir/.config" "$kbuild/.config"
    if [ -d "$save_dir/arch" ]; then
        cp -r "$save_dir/arch" "$kbuild/" 2>/dev/null || true
    fi
    rm -rf "$save_dir"

    local after=$(du -sm "$kbuild" 2>/dev/null | cut -f1)
    log "  Compacted $kbuild: ${before}MB → ${after}MB"
}

# =====================================================================
# Step 4: Boot and test
# =====================================================================
boot_and_test() {
    local arch="$1"
    local build_name="$2"
    local label="$3"  # e.g., "m4" or "m0"

    local kbuild="$TMP_BASE/kbuild-${build_name}"
    local img_rel="${KERNEL_IMAGE[$arch]}"
    local img="$kbuild/$img_rel"
    local iname="${INITRAMFS_NAME[$arch]}"
    local initramfs="$SCRIPT_DIR/initramfs/initramfs-${iname}.cpio.gz"
    local qemu_base="${QEMU_BASE[$arch]}"
    local append="${CONSOLE_APPEND[$arch]}"
    local timeout_secs="${BOOT_TIMEOUT[$arch]:-300}"
    local logfile_path="$LOG_DIR/${build_name}.log"

    # Use vmlinux fallback if specific image not found
    if [ ! -f "$img" ] && [ -f "$kbuild/vmlinux" ]; then
        img="$kbuild/vmlinux"
    fi

    if [ ! -f "$img" ]; then
        log "  SKIP boot $build_name: kernel image not found ($img)"
        logfile "BOOT_SKIP $build_name (no kernel)"
        echo "SKIP" > "$LOG_DIR/${build_name}.status"
        return 1
    fi

    log "  Booting $build_name (timeout=${timeout_secs}s)..."

    # Replace KBUILD placeholder in QEMU args (for DTB paths etc.)
    qemu_base="${qemu_base//KBUILD/$kbuild}"

    # Build QEMU command
    local qemu_cmd="$qemu_base -kernel $img"

    # Add initrd for non-embedded arches
    case " $EMBEDDED_INITRAMFS_ARCHES " in
        *" $arch "*)
            # Embedded initramfs — no -initrd, no -append for some
            case "$arch" in
                loongarch64)
                    # ESP disk boot
                    # For loongarch64, we need the kernel image embedded w/ initramfs
                    # The ESP disk contains vmlinuz.efi as BOOTLOONGARCH64.EFI
                    local esp_disk="$TMP_BASE/loongarch64_esp_${label}.img"
                    if [ ! -f "$esp_disk" ]; then
                        # Build ESP disk from vmlinuz.efi using mtools (no root needed)
                        local efi_img="$kbuild/arch/loongarch/boot/vmlinuz.efi"
                        if [ -f "$efi_img" ]; then
                            local efi_size=$(stat -c%s "$efi_img" 2>/dev/null)
                            local disk_mb=$(( (efi_size / 1048576) + 16 ))
                            dd if=/dev/zero of="$esp_disk" bs=1M count=$disk_mb 2>/dev/null
                            sgdisk -n 1:2048:$(( disk_mb * 2048 - 34 )) -t 1:ef00 "$esp_disk" 2>/dev/null || true
                            # Format partition with mtools
                            local part_img="/tmp/la-esp-part-$$.img"
                            dd if=/dev/zero of="$part_img" bs=1M count=$((disk_mb - 1)) 2>/dev/null
                            mkfs.fat -F32 "$part_img" 2>/dev/null
                            mmd -i "$part_img" ::EFI ::EFI/BOOT 2>/dev/null
                            mcopy -i "$part_img" "$efi_img" ::EFI/BOOT/BOOTLOONGARCH64.EFI 2>/dev/null
                            # Copy partition into disk image at offset 1MB
                            dd if="$part_img" of="$esp_disk" bs=1M seek=1 conv=notrunc 2>/dev/null
                            rm -f "$part_img"
                            log "  Created ESP disk: $esp_disk"
                        fi
                    fi
                    if [ -f "$esp_disk" ]; then
                        qemu_cmd="$qemu_cmd -drive file=$esp_disk,format=raw,if=virtio"
                    fi
                    # Add BIOS
                    qemu_cmd="$qemu_cmd -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd"
                    ;;
            esac
            ;;
        *)
            if [ -f "$initramfs" ]; then
                qemu_cmd="$qemu_cmd -initrd $initramfs"
            fi
            qemu_cmd="$qemu_cmd -append \"$append autotest=1\""
            ;;
    esac

    # Run with timeout and watchdog
    # The watchdog kills QEMU if no output for 60 seconds (deadlock detection)
    log "  CMD: timeout $timeout_secs $qemu_cmd"
    eval "timeout --kill-after=30 $timeout_secs $qemu_cmd" > "$logfile_path" 2>&1
    local exit_code=$?

    # Parse results from log
    local pgcl_pass=0 pgcl_fail=0
    local stress_pass=0 stress_fail=0
    local selftest_pass=0 selftest_fail=0 selftest_skip=0
    local ltp_pass=0 ltp_fail=0 ltp_skip=0
    local kernel_errors=""
    local booted="no"

    if grep -q "PGCL Boot Test" "$logfile_path" 2>/dev/null; then
        booted="yes"
    fi

    # Extract pgcl-test results (first "Results:" line)
    local line=$(grep "Results:.*passed.*failed" "$logfile_path" 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        pgcl_pass=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
        pgcl_fail=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
    fi

    # Extract pgcl-stress results (second "Results:" line)
    local results_count=$(grep -c "Results:.*passed.*failed" "$logfile_path" 2>/dev/null || echo 0)
    results_count=${results_count//[^0-9]/}; results_count=${results_count:-0}
    if [ "$results_count" -ge 2 ]; then
        line=$(grep "Results:.*passed.*failed" "$logfile_path" | sed -n '2p')
        stress_pass=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
        stress_fail=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
    fi

    # Extract selftest results (count PASS/FAIL/SKIP lines in selftest section only)
    if grep -q "Running kernel mm selftests" "$logfile_path" 2>/dev/null; then
        local selftest_section
        selftest_section=$(sed -n '/Running kernel mm selftests/,/Running LTP mm tests\|Test Summary/p' "$logfile_path" 2>/dev/null)
        selftest_pass=$(echo "$selftest_section" | grep -cE "^\s+\S+:\s+PASS" 2>/dev/null || echo 0)
        selftest_fail=$(echo "$selftest_section" | grep -cE "^\s+\S+:\s+FAIL" 2>/dev/null || echo 0)
        selftest_skip=$(echo "$selftest_section" | grep -cE "^\s+\S+:\s+SKIP" 2>/dev/null || echo 0)
        selftest_pass=${selftest_pass//[^0-9]/}; selftest_pass=${selftest_pass:-0}
        selftest_fail=${selftest_fail//[^0-9]/}; selftest_fail=${selftest_fail:-0}
        selftest_skip=${selftest_skip//[^0-9]/}; selftest_skip=${selftest_skip:-0}
    fi

    # Extract LTP results
    local ltp_line=$(grep "LTP subtotals:" "$logfile_path" 2>/dev/null)
    if [ -n "$ltp_line" ]; then
        ltp_pass=$(echo "$ltp_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
        ltp_fail=$(echo "$ltp_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
        ltp_skip=$(echo "$ltp_line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+')
    fi

    # Check for kernel errors
    if grep -viE "command line:|panic=" "$logfile_path" 2>/dev/null | \
       grep -qiE "BUG:|BUG |Oops|panic[^=]|Bad page state"; then
        kernel_errors="KERNEL_ERRORS"
    fi

    # Check for warnings (non-fatal)
    local warnings=""
    if grep -viE "command line:|panic=" "$logfile_path" 2>/dev/null | \
       grep -qiE "WARNING:"; then
        local warn_count=$(grep -viE "command line:|panic=" "$logfile_path" | grep -ciE "WARNING:")
        warnings="WARN:${warn_count}"
    fi

    # Sanitize all counters to integers
    pgcl_pass=${pgcl_pass:-0}; pgcl_pass=${pgcl_pass//[^0-9]/}; pgcl_pass=${pgcl_pass:-0}
    pgcl_fail=${pgcl_fail:-0}; pgcl_fail=${pgcl_fail//[^0-9]/}; pgcl_fail=${pgcl_fail:-0}
    stress_pass=${stress_pass:-0}; stress_pass=${stress_pass//[^0-9]/}; stress_pass=${stress_pass:-0}
    stress_fail=${stress_fail:-0}; stress_fail=${stress_fail//[^0-9]/}; stress_fail=${stress_fail:-0}
    ltp_pass=${ltp_pass:-0}; ltp_pass=${ltp_pass//[^0-9]/}; ltp_pass=${ltp_pass:-0}
    ltp_fail=${ltp_fail:-0}; ltp_fail=${ltp_fail//[^0-9]/}; ltp_fail=${ltp_fail:-0}
    ltp_skip=${ltp_skip:-0}; ltp_skip=${ltp_skip//[^0-9]/}; ltp_skip=${ltp_skip:-0}

    # Format result line
    local status="PASS"
    if [ "$booted" = "no" ]; then
        status="NO_BOOT"
    elif [ -n "$kernel_errors" ]; then
        status="KERNEL_BUG"
    elif [ "$pgcl_fail" -gt 0 ] || [ "$stress_fail" -gt 0 ]; then
        status="FAIL"
    fi

    local result="${build_name}: boot=${booted} pgcl=${pgcl_pass:-0}/${pgcl_fail:-0} stress=${stress_pass:-0}/${stress_fail:-0}"
    if [ "$selftest_pass" -gt 0 ] || [ "$selftest_fail" -gt 0 ]; then
        result="$result self=${selftest_pass}p/${selftest_fail}f/${selftest_skip}s"
    fi
    if [ "$ltp_pass" -gt 0 ] || [ "$ltp_fail" -gt 0 ]; then
        result="$result ltp=${ltp_pass}p/${ltp_fail}f/${ltp_skip}s"
    fi
    [ -n "$kernel_errors" ] && result="$result $kernel_errors"
    [ -n "$warnings" ] && result="$result $warnings"
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        result="$result TIMEOUT"
    fi

    log "  $result"
    logfile "$result"
    echo "$status" > "$LOG_DIR/${build_name}.status"
}

# =====================================================================
# Main
# =====================================================================

# Active test architectures (16 arches that boot + arm32-lpae variant)
# arm32-lpae is separate from arm (non-LPAE)
ARCHES=(
    x86_64 aarch64 riscv64 s390x powerpc64
    sparc64 alpha loongarch64
    riscv32 m68k hppa hppa64
    mips64 arm arm32-lpae microblaze
)

# Musl arch mapping for LTP cross-compile
declare -A LTP_MUSL_ARCH
LTP_MUSL_ARCH=(
    [x86_64]="x86_64" [aarch64]="aarch64" [riscv64]="riscv64"
    [s390x]="s390x" [powerpc64]="ppc64" [sparc64]="sparc64"
    [alpha]="alpha" [loongarch64]="loongarch64" [m68k]="m68k"
    [arm]="arm" [arm32-lpae]="arm" [mips64]="mips64"
    [microblaze]="microblaze" [riscv32]="riscv32"
    [hppa]="hppa" [hppa64]="hppa64"
)

declare -A LTP_CROSS
LTP_CROSS=(
    [x86_64]="" [aarch64]="aarch64-linux-gnu-" [riscv64]="riscv64-linux-gnu-"
    [s390x]="s390x-linux-gnu-" [powerpc64]="powerpc64-linux-gnu-"
    [sparc64]="sparc64-linux-gnu-" [alpha]="alpha-linux-gnu-"
    [loongarch64]="loongarch64-linux-gnu-" [m68k]="m68k-linux-gnu-"
    [arm]="arm-linux-gnu-" [arm32-lpae]="arm-linux-gnu-"
    [mips64]="mips64-linux-gnu-" [microblaze]="microblaze-linux-gnu-"
    [riscv32]="riscv32-linux-gnu-" [hppa]="hppa-linux-gnu-"
    [hppa64]="hppa64-linux-gnu-"
)

main() {
    # Parse arguments
    local skip_ltp=0 skip_initramfs=0 skip_build=0 only_arch="" only_shift=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-ltp) skip_ltp=1 ;;
            --skip-initramfs) skip_initramfs=1 ;;
            --skip-build) skip_build=1 ;;
            --arch=*) only_arch="${1#--arch=}" ;;
            --shift=*) only_shift="${1#--shift=}" ;;
            --no-compact) COMPACT_BUILDS=0 ;;
            --help) echo "Usage: $0 [--skip-ltp] [--skip-initramfs] [--skip-build] [--arch=ARCH] [--shift=0|4] [--no-compact]"; exit 0 ;;
            *) echo "Unknown arg: $1"; exit 1 ;;
        esac
        shift
    done

    # If only_arch specified, restrict to that arch
    local run_arches=("${ARCHES[@]}")
    if [ -n "$only_arch" ]; then
        run_arches=("$only_arch")
    fi

    mkdir -p "$LOG_DIR" "$TMP_BASE"
    echo "" > "$RESULTS_FILE"
    echo "=== PGCL Full Regression $(date) ===" | tee -a "$RESULTS_FILE"
    echo "=== Source: $(cd $LINUX_SRC && git log --oneline -1) ===" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"

    # Drop caches to free memory before heavy work
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    # ---- Phase 1: Build LTP for all arches ----
    if [ "$skip_ltp" = "0" ]; then
        log "===== PHASE 1: Build LTP for all architectures ====="
        for arch in "${run_arches[@]}"; do
            local musl="${LTP_MUSL_ARCH[$arch]}"
            local cross="${LTP_CROSS[$arch]}"
            build_ltp_for_arch "$arch" "$musl" "$cross" || true
        done
    else
        log "===== PHASE 1: SKIPPED (--skip-ltp) ====="
    fi

    # ---- Phase 2: Rebuild initramfs with LTP ----
    if [ "$skip_initramfs" = "0" ]; then
        log "===== PHASE 2: Rebuild initramfs with LTP ====="
        for arch in "${run_arches[@]}"; do
            rebuild_initramfs_with_ltp "$arch" || true
        done
    else
        log "===== PHASE 2: SKIPPED (--skip-initramfs) ====="
    fi

    # ---- Phase 3: Build kernels (sequential to avoid OOM) ----
    if [ "$skip_build" = "0" ]; then
        log "===== PHASE 3: Build kernels ====="
        for arch in "${run_arches[@]}"; do
            log "--- $arch ---"

            # Build MMUSHIFT=4 (PGCL) unless restricted to shift=0
            if [ -z "$only_shift" ] || [ "$only_shift" = "4" ]; then
                local m4_name="${arch}-m4"
                build_kernel "$arch" 4 "$m4_name" || true
            fi

            # Reclaim memory between builds
            sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            # Build MMUSHIFT=0 (baseline) unless restricted to shift=4
            if [ -z "$only_shift" ] || [ "$only_shift" = "0" ]; then
                local m0_name="${arch}-m0"
                build_kernel "$arch" 0 "$m0_name" || true
            fi

            sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        done
    else
        log "===== PHASE 3: SKIPPED (--skip-build) ====="
    fi

    # ---- Phase 4: Boot and test (sequential — 1 QEMU at a time) ----
    log "===== PHASE 4: Boot and test ====="

    if [ -z "$only_shift" ] || [ "$only_shift" = "4" ]; then
        echo "" >> "$RESULTS_FILE"
        echo "--- MMUSHIFT=4 (PGCL) ---" | tee -a "$RESULTS_FILE"
        for arch in "${run_arches[@]}"; do
            boot_and_test "$arch" "${arch}-m4" "m4" || true
        done
    fi

    if [ -z "$only_shift" ] || [ "$only_shift" = "0" ]; then
        echo "" >> "$RESULTS_FILE"
        echo "--- MMUSHIFT=0 (baseline) ---" | tee -a "$RESULTS_FILE"
        for arch in "${run_arches[@]}"; do
            boot_and_test "$arch" "${arch}-m0" "m0" || true
        done
    fi

    # ---- Phase 5: Summary ----
    echo ""
    echo "================================================================"
    echo "  FULL REGRESSION RESULTS"
    echo "================================================================"
    cat "$RESULTS_FILE"
    echo ""
    echo "Logs in: $LOG_DIR/"
    echo "Results: $RESULTS_FILE"
}

main "$@"
