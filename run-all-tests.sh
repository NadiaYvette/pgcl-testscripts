#!/bin/bash
# Run QEMU boot + LTP for all built architectures
# Usage: ./run-all-tests.sh [ARCH...]
set -u

PGCL=/home/nyc/src/pgcl
KBUILD="$PGCL/kernel-build"
INITRAMFS="$PGCL/userspace/initramfs"
LOGDIR="$PGCL/test-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

run_test() {
    local name="$1"
    local qemu_cmd="$2"
    local kernel="$3"
    local initramfs_file="$4"
    local append="$5"
    local timeout="${6:-600}"
    local log="$LOGDIR/test-$name.log"

    if [ ! -f "$kernel" ]; then
        echo "[$name] SKIP — no kernel at $kernel"
        return 1
    fi

    echo -n "[$name] Testing (timeout=${timeout}s)... "

    timeout "$timeout" $qemu_cmd \
        -kernel "$kernel" \
        ${initramfs_file:+-initrd "$initramfs_file"} \
        ${append:+-append "$append"} \
        > "$log" 2>&1 || true

    # Parse results
    if grep -q "Test Summary:" "$log"; then
        local pass=$(grep "Test Summary:" "$log" | tail -1 | grep -oP '\d+ passed' | grep -oP '\d+')
        local fail=$(grep "Test Summary:" "$log" | tail -1 | grep -oP '\d+ failed' | grep -oP '\d+')
        local ltp_line=""
        if grep -q "LTP subtotals:" "$log"; then
            ltp_line=" | $(grep 'LTP subtotals:' "$log" | tail -1 | sed 's/.*LTP subtotals: /LTP: /')"
        fi
        local warn=""
        if grep -q "WARNING: kernel log contains errors" "$log"; then
            warn=" *** KERNEL WARNINGS ***"
        fi
        echo "${pass}p/${fail}f${ltp_line}${warn}"
    elif grep -q "Boot successful" "$log"; then
        echo "BOOT OK (no test results)"
    else
        echo "NO OUTPUT — check $log"
        tail -5 "$log" | head -5
    fi
}

echo "=== PGCL QEMU Test Run — $(date) ==="
echo "Logs: $LOGDIR"
echo ""

# x86_64
run_test x86_64 \
    "qemu-system-x86_64 -M pc -m 8G -smp 4 -nographic -no-reboot" \
    "$KBUILD/x86_64/arch/x86/boot/bzImage" \
    "$INITRAMFS/initramfs-x86_64.cpio.gz" \
    "console=ttyS0 nokaslr nopti panic=1 autotest=1" 600

# aarch64
run_test aarch64 \
    "qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot" \
    "$KBUILD/aarch64/arch/arm64/boot/Image" \
    "$INITRAMFS/initramfs-aarch64.cpio.gz" \
    "console=ttyAMA0 panic=1 autotest=1" 600

# riscv64
run_test riscv64 \
    "qemu-system-riscv64 -M virt -m 8G -smp 4 -nographic -no-reboot -bios default" \
    "$KBUILD/riscv64/arch/riscv/boot/Image" \
    "$INITRAMFS/initramfs-riscv64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

# s390x
run_test s390x \
    "qemu-system-s390x -m 8G -smp 1 -nographic -no-reboot -nodefaults -serial stdio" \
    "$KBUILD/s390x/arch/s390/boot/bzImage" \
    "$INITRAMFS/initramfs-s390x.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

# ppc64 (powernv, vmlinux directly)
run_test powerpc64 \
    "qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot" \
    "$KBUILD/powerpc64/vmlinux" \
    "$INITRAMFS/initramfs-powerpc64.cpio.gz" \
    "console=hvc0 panic=1 autotest=1" 600

# sparc64
run_test sparc64 \
    "qemu-system-sparc64 -M sun4u -m 4G -nographic -no-reboot" \
    "$KBUILD/sparc64/arch/sparc/boot/image" \
    "$INITRAMFS/initramfs-sparc64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 900

# alpha (needs -serial stdio)
run_test alpha \
    "qemu-system-alpha -m 2G -nographic -no-reboot -serial stdio" \
    "$KBUILD/alpha/vmlinux" \
    "$INITRAMFS/initramfs-alpha.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 900

# riscv32
run_test riscv32 \
    "qemu-system-riscv32 -M virt -m 2G -smp 4 -nographic -no-reboot -bios default" \
    "$KBUILD/riscv32/arch/riscv/boot/Image" \
    "$INITRAMFS/initramfs-riscv32.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

# m68k
run_test m68k \
    "qemu-system-m68k -M virt -m 512M -nographic -no-reboot" \
    "$KBUILD/m68k/vmlinux" \
    "$INITRAMFS/initramfs-m68k.cpio.gz" \
    "console=ttyGF0 panic=1 autotest=1" 900

# hppa32
run_test hppa \
    "qemu-system-hppa -m 3G -nographic -no-reboot" \
    "$KBUILD/hppa/vmlinux" \
    "$INITRAMFS/initramfs-hppa.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 1200

# mips64 (embedded initramfs, no -initrd)
run_test mips64 \
    "qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot" \
    "$KBUILD/mips64/vmlinux" \
    "" \
    "" 1200

# arm32
run_test arm \
    "qemu-system-arm -M virt -cpu cortex-a15 -m 768M -nographic -no-reboot" \
    "$KBUILD/arm/arch/arm/boot/zImage" \
    "$INITRAMFS/initramfs-arm.cpio.gz" \
    "console=ttyAMA0 panic=1 autotest=1" 600

# arm32-lpae
run_test arm-lpae \
    "qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 2G -nographic -no-reboot -dtb $KBUILD/arm-lpae/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb" \
    "$KBUILD/arm-lpae/arch/arm/boot/zImage" \
    "$INITRAMFS/initramfs-arm.cpio.gz" \
    "console=ttyAMA0 panic=1 autotest=1" 600

# hppa64 (use qemu-system-hppa with 64-bit kernel)
run_test hppa64 \
    "qemu-system-hppa -m 8G -nographic -no-reboot" \
    "$KBUILD/hppa64/vmlinux" \
    "$INITRAMFS/initramfs-hppa64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 1200

# loongarch64 (ESP disk boot)
if [ -f "$KBUILD/loongarch64/arch/loongarch/boot/vmlinuz.efi" ]; then
    echo -n "[loongarch64] Testing (ESP boot, timeout=900s)... "
    ESPDIR=$(mktemp -d)
    DISKIMG=$(mktemp --suffix=.img)
    mkdir -p "$ESPDIR/EFI/BOOT"
    cp "$KBUILD/loongarch64/arch/loongarch/boot/vmlinuz.efi" "$ESPDIR/EFI/BOOT/BOOTLOONGARCH64.EFI"
    dd if=/dev/zero of="$DISKIMG" bs=1M count=256 2>/dev/null
    mkfs.vfat -F 32 "$DISKIMG" 2>/dev/null
    mcopy -i "$DISKIMG" -s "$ESPDIR/EFI" ::/ 2>/dev/null
    timeout 900 qemu-system-loongarch64 -M virt -m 8G -nographic -no-reboot \
        -drive file="$DISKIMG",format=raw,if=virtio \
        -bios /usr/share/edk2/loongarch64/OVMF_CODE.fd \
        > "$LOGDIR/test-loongarch64.log" 2>&1 || true
    rm -f "$DISKIMG"; rm -rf "$ESPDIR"
    if grep -q "Test Summary:" "$LOGDIR/test-loongarch64.log"; then
        grep "Test Summary:" "$LOGDIR/test-loongarch64.log" | tail -1
        grep "LTP subtotals:" "$LOGDIR/test-loongarch64.log" | tail -1 2>/dev/null
    else
        echo "check log"
    fi
else
    echo "[loongarch64] SKIP — no kernel"
fi

# microblaze (embedded initramfs, no -initrd)
run_test microblaze \
    "qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot" \
    "$KBUILD/microblaze/arch/microblaze/boot/linux.bin" \
    "" \
    "" 600

echo ""
echo "=== Test run complete — logs in $LOGDIR ==="
