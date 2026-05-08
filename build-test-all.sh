#!/bin/bash
#
# Build kernels + run LTP for all 16 PGCL architectures
# Usage: ./build-test-all.sh [build|test|all] [ARCH...]
#
set -u

LINUX=/home/nyc/src/linux
PGCL=/home/nyc/src/pgcl
LOGDIR="$PGCL/test-logs-$(date +%Y%m%d-%H%M%S)"
INITRAMFS_DIR="$PGCL/userspace/initramfs"
mkdir -p "$LOGDIR"

# Per-arch configuration:
#   ARCH  LINUX_ARCH  CROSS_COMPILE  DEFCONFIG  EXTRA_CONFIG  QEMU_CMD  KERNEL_IMAGE  QEMU_APPEND  TIMEOUT
declare -A BUILDS

# x86_64 — already built in-tree
BUILDS[x86_64]="x86|x86_64_defconfig||qemu-system-x86_64 -M pc -m 8G -smp 4 -nographic -no-reboot|arch/x86/boot/bzImage|console=ttyS0 nokaslr nopti panic=1 autotest=1|600"

# arm64
BUILDS[aarch64]="arm64|defconfig|aarch64-linux-gnu-|qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot|arch/arm64/boot/Image|console=ttyAMA0 panic=1 autotest=1|600"

# riscv64
BUILDS[riscv64]="riscv|defconfig|riscv64-linux-gnu-|qemu-system-riscv64 -M virt -m 8G -smp 4 -nographic -no-reboot -bios default|arch/riscv/boot/Image|console=ttyS0 panic=1 autotest=1|600"

# s390x
BUILDS[s390x]="s390|defconfig|s390x-linux-gnu-|qemu-system-s390x -m 8G -smp 1 -nographic -no-reboot -nodefaults -serial stdio|arch/s390/boot/bzImage|console=ttyS0 panic=1 autotest=1|600"

# ppc64
BUILDS[powerpc64]="powerpc|ppc64_defconfig|powerpc64le-linux-gnu-|qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot|vmlinux|console=hvc0 panic=1 autotest=1|600"

# sparc64
BUILDS[sparc64]="sparc|sparc64_defconfig|sparc64-linux-gnu-|qemu-system-sparc64 -M sun4u -m 4G -nographic -no-reboot|arch/sparc/boot/image|console=ttyS0 panic=1 autotest=1|900"

# alpha
BUILDS[alpha]="alpha|defconfig|alpha-linux-gnu-|qemu-system-alpha -m 2G -nographic -no-reboot -serial stdio|vmlinux|console=ttyS0 panic=1 autotest=1|900"

# loongarch64 — needs ESP disk boot
BUILDS[loongarch64]="loongarch|defconfig|loongarch64-linux-gnu-|ESP_BOOT|arch/loongarch/boot/vmlinuz.efi|console=ttyS0,115200 panic=1 autotest=1|900"

# riscv32
BUILDS[riscv32]="riscv|rv32_defconfig|riscv32-linux-gnu-|qemu-system-riscv32 -M virt -m 2G -smp 4 -nographic -no-reboot -bios default|arch/riscv/boot/Image|console=ttyS0 panic=1 autotest=1|600"

# m68k
BUILDS[m68k]="m68k|multi_defconfig|m68k-linux-gnu-|qemu-system-m68k -M virt -m 512M -nographic -no-reboot|vmlinux|console=ttyGF0 panic=1 autotest=1|900"

# hppa32
BUILDS[hppa]="parisc|generic-32bit_defconfig|hppa-linux-gnu-|qemu-system-hppa -m 3G -nographic -no-reboot|vmlinux|console=ttyS0 panic=1 autotest=1|1200"

# mips64
BUILDS[mips64]="mips|malta_defconfig|mips64-linux-gnu-|qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot|vmlinux|console=ttyS0 panic=1 autotest=1|1200"

# arm32
BUILDS[arm]="arm|multi_v7_defconfig|arm-linux-gnueabihf-|qemu-system-arm -M virt -cpu cortex-a15 -m 768M -nographic -no-reboot|arch/arm/boot/zImage|console=ttyAMA0 panic=1 autotest=1|600"

# arm32-lpae (uses same arm cross compiler)
BUILDS[arm-lpae]="arm|vexpress_defconfig|arm-linux-gnueabihf-|qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 2G -nographic -no-reboot -dtb DTBDIR/vexpress-v2p-ca15-tc1.dtb|arch/arm/boot/zImage|console=ttyAMA0 panic=1 autotest=1|600"

# hppa64
BUILDS[hppa64]="parisc|generic-64bit_defconfig|hppa64-linux-gnu-|qemu-system-hppa64 -m 8G -smp 1 -nographic -no-reboot|vmlinux|console=ttyS0 panic=1 autotest=1|1200"

# microblaze
BUILDS[microblaze]="microblaze|defconfig|microblaze-linux-gnu-|qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot|arch/microblaze/boot/linux.bin|console=ttyUL0 panic=1 autotest=1|600"

build_kernel() {
    local arch_name="$1"
    local info="${BUILDS[$arch_name]}"
    IFS='|' read -r linux_arch defconfig cross_compile qemu_cmd kernel_image append timeout <<< "$info"

    local builddir="$PGCL/kernel-build/$arch_name"
    local log="$LOGDIR/build-$arch_name.log"

    echo "[$arch_name] Building kernel..."

    # x86_64 is built in-tree
    if [ "$arch_name" = "x86_64" ]; then
        echo "[$arch_name] Already built in-tree, skipping"
        return 0
    fi

    # Check cross compiler
    if [ -n "$cross_compile" ] && ! command -v "${cross_compile}gcc" &>/dev/null; then
        echo "[$arch_name] SKIP: no ${cross_compile}gcc"
        return 1
    fi

    mkdir -p "$builddir"

    (
        cd "$LINUX"
        make ARCH="$linux_arch" ${cross_compile:+CROSS_COMPILE=$cross_compile} O="$builddir" "$defconfig" 2>&1
        # Set PAGE_MMUSHIFT=4
        "$LINUX/scripts/config" --file "$builddir/.config" --set-val PAGE_MMUSHIFT 4
        # Architecture-specific config tweaks
        case "$arch_name" in
            mips64)
                # Use embedded initramfs for MIPS (external initrd placement issues)
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-mips64.cpio.gz" \
                    --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL
                ;;
            loongarch64)
                # LoongArch needs embedded initramfs + cmdline for ESP boot
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-loongarch64.cpio.gz" \
                    --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL
                ;;
            microblaze)
                # Microblaze needs embedded initramfs
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-microblaze.cpio.gz" \
                    --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL
                ;;
            powerpc64)
                # Use PPC_4K_PAGES, not PPC_64K_PAGES
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES
                ;;
            riscv32)
                # 32-bit RISC-V
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --enable ARCH_RV32I --disable ARCH_RV64I 2>/dev/null || true
                ;;
            arm-lpae)
                # Enable LPAE
                "$LINUX/scripts/config" --file "$builddir/.config" \
                    --enable ARM_LPAE
                ;;
        esac
        make ARCH="$linux_arch" ${cross_compile:+CROSS_COMPILE=$cross_compile} O="$builddir" olddefconfig 2>&1
        make ARCH="$linux_arch" ${cross_compile:+CROSS_COMPILE=$cross_compile} O="$builddir" -j$(nproc) 2>&1
    ) > "$log" 2>&1

    if [ $? -eq 0 ]; then
        echo "[$arch_name] Build OK"
        return 0
    else
        echo "[$arch_name] Build FAILED — see $log"
        tail -20 "$log"
        return 1
    fi
}

run_qemu_test() {
    local arch_name="$1"
    local info="${BUILDS[$arch_name]}"
    IFS='|' read -r linux_arch defconfig cross_compile qemu_cmd kernel_image append timeout <<< "$info"

    local builddir="$PGCL/kernel-build/$arch_name"
    local log="$LOGDIR/test-$arch_name.log"
    local initramfs="$INITRAMFS_DIR/initramfs-${arch_name}.cpio.gz"

    # Map arch_name to initramfs name
    case "$arch_name" in
        arm-lpae) initramfs="$INITRAMFS_DIR/initramfs-arm.cpio.gz" ;;
    esac

    # Determine kernel path
    local kernel
    if [ "$arch_name" = "x86_64" ]; then
        kernel="$LINUX/$kernel_image"
    else
        kernel="$builddir/$kernel_image"
    fi

    if [ ! -f "$kernel" ]; then
        echo "[$arch_name] No kernel image at $kernel, skipping test"
        return 1
    fi

    echo "[$arch_name] Running QEMU tests (timeout=${timeout}s)..."

    case "$arch_name" in
        loongarch64)
            # ESP disk boot — create disk image with EFI binary
            local espdir=$(mktemp -d)
            local diskimg=$(mktemp --suffix=.img)
            mkdir -p "$espdir/EFI/BOOT"
            cp "$kernel" "$espdir/EFI/BOOT/BOOTLOONGARCH64.EFI"
            # Create FAT32 ESP image
            dd if=/dev/zero of="$diskimg" bs=1M count=256 2>/dev/null
            mkfs.vfat -F 32 "$diskimg" 2>/dev/null
            mcopy -i "$diskimg" -s "$espdir/EFI" ::/ 2>/dev/null
            timeout "$timeout" qemu-system-loongarch64 -M virt -m 8G -nographic -no-reboot \
                -drive file="$diskimg",format=raw,if=virtio \
                -bios /usr/share/edk2/loongarch64/OVMF_CODE.fd \
                > "$log" 2>&1 || true
            rm -f "$diskimg"
            rm -rf "$espdir"
            ;;
        powerpc64)
            # ppc64 uses vmlinux directly (not zImage)
            timeout "$timeout" $qemu_cmd \
                -kernel "$kernel" \
                -initrd "$initramfs" \
                -append "$append" \
                > "$log" 2>&1 || true
            ;;
        s390x)
            timeout "$timeout" $qemu_cmd \
                -kernel "$kernel" \
                -initrd "$initramfs" \
                -append "$append" \
                > "$log" 2>&1 || true
            ;;
        alpha)
            timeout "$timeout" $qemu_cmd \
                -kernel "$kernel" \
                -initrd "$initramfs" \
                -append "$append" \
                > "$log" 2>&1 || true
            ;;
        arm-lpae)
            local dtbdir="$builddir/arch/arm/boot/dts"
            local real_qemu="${qemu_cmd//DTBDIR/$dtbdir}"
            timeout "$timeout" $real_qemu \
                -kernel "$kernel" \
                -initrd "$initramfs" \
                -append "$append" \
                > "$log" 2>&1 || true
            ;;
        mips64|microblaze)
            # Embedded initramfs — no -initrd needed
            timeout "$timeout" $qemu_cmd \
                -kernel "$kernel" \
                > "$log" 2>&1 || true
            ;;
        *)
            timeout "$timeout" $qemu_cmd \
                -kernel "$kernel" \
                -initrd "$initramfs" \
                -append "$append" \
                > "$log" 2>&1 || true
            ;;
    esac

    # Extract results
    if grep -q "Test Summary:" "$log"; then
        local summary=$(grep "Test Summary:" "$log" | tail -1)
        echo "[$arch_name] $summary"
        # Extract LTP details
        if grep -q "LTP subtotals:" "$log"; then
            local ltp=$(grep "LTP subtotals:" "$log" | tail -1)
            echo "[$arch_name] $ltp"
        fi
        # Check for kernel warnings
        if grep -q "WARNING: kernel log contains errors" "$log"; then
            echo "[$arch_name] *** KERNEL WARNINGS DETECTED ***"
        fi
    else
        echo "[$arch_name] No test summary found — check $log"
        # Show last 20 lines for debugging
        tail -20 "$log"
    fi
}

# ---- Main ----
MODE="${1:-all}"
shift 2>/dev/null || true
ARCHES=("$@")

# If no arches specified, do all
if [ ${#ARCHES[@]} -eq 0 ]; then
    ARCHES=(x86_64 aarch64 riscv64 s390x powerpc64 sparc64 alpha loongarch64 riscv32 m68k hppa mips64 arm arm-lpae hppa64 microblaze)
fi

echo "=== PGCL Build & Test — $(date) ==="
echo "Mode: $MODE"
echo "Architectures: ${ARCHES[*]}"
echo "Log directory: $LOGDIR"
echo ""

if [ "$MODE" = "build" ] || [ "$MODE" = "all" ]; then
    echo "=== Phase 1: Cross-compile kernels ==="
    BUILD_PASS=0
    BUILD_FAIL=0
    for arch in "${ARCHES[@]}"; do
        if build_kernel "$arch"; then
            BUILD_PASS=$((BUILD_PASS+1))
        else
            BUILD_FAIL=$((BUILD_FAIL+1))
        fi
    done
    echo ""
    echo "Build results: $BUILD_PASS passed, $BUILD_FAIL failed"
    echo ""
fi

if [ "$MODE" = "test" ] || [ "$MODE" = "all" ]; then
    echo "=== Phase 2: QEMU boot + LTP ==="
    for arch in "${ARCHES[@]}"; do
        run_qemu_test "$arch"
        echo ""
    done
fi

echo "=== Done — logs in $LOGDIR ==="
