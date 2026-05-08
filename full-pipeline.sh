#!/bin/bash
# Full PGCL pipeline: build all 16 arch kernels + run all QEMU tests
set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
LINUX=/home/nyc/src/linux
KBUILD="$D/kernel-build"
INITRAMFS="$D/userspace/initramfs"
TS=$(date +%Y%m%d-%H%M%S)
BLOGDIR="$D/build-logs-$TS"
TLOGDIR="$D/test-logs-$TS"
mkdir -p "$BLOGDIR" "$TLOGDIR" "$KBUILD"

BPASS=0; BFAIL=0; BSKIP=0

build_one() {
    local name="$1" la="$2" cc="$3" dc="$4"
    local bdir="$KBUILD/$name"
    local log="$BLOGDIR/$name.log"
    echo -n "BUILD [$name] "
    mkdir -p "$bdir"
    (
        cd "$LINUX"
        # Clean source tree to avoid cross-arch O= contamination
        # Must use same ARCH to clean the correct arch/$(SRCARCH)/include/generated
        make ARCH="$la" ${cc:+CROSS_COMPILE=$cc} mrproper 2>&1
        # Also clean stale O= build directory
        rm -rf "$bdir"
        mkdir -p "$bdir"
        make ARCH="$la" ${cc:+CROSS_COMPILE=$cc} O="$bdir" "$dc" 2>&1
        scripts/config --file "$bdir/.config" --set-val PAGE_MMUSHIFT 4
        case "$name" in
            mips64)
                scripts/config --file "$bdir/.config" \
                    --enable 64BIT --enable CPU_MIPS64_R2 \
                    --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-mips64.cpio.gz" \
                    --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL ;;
            loongarch64)
                scripts/config --file "$bdir/.config" \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
                    --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL --enable EFI_STUB ;;
            microblaze)
                scripts/config --file "$bdir/.config" \
                    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-microblaze.cpio.gz" \
                    --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" \
                    --enable CMDLINE_BOOL ;;
            powerpc64)
                scripts/config --file "$bdir/.config" \
                    --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES ;;
            arm-lpae)
                scripts/config --file "$bdir/.config" --enable ARM_LPAE ;;
            m68k)
                scripts/config --file "$bdir/.config" \
                    --enable GOLDFISH --enable GOLDFISH_TTY ;;
        esac
        make ARCH="$la" ${cc:+CROSS_COMPILE=$cc} O="$bdir" olddefconfig 2>&1
        make ARCH="$la" ${cc:+CROSS_COMPILE=$cc} O="$bdir" -j$(nproc) 2>&1
    ) > "$log" 2>&1
    if [ $? -eq 0 ]; then
        echo "OK"
        BPASS=$((BPASS+1))
    else
        echo "FAIL (see $log)"
        tail -5 "$log"
        BFAIL=$((BFAIL+1))
    fi
}

echo "===== PGCL Full Pipeline — $TS ====="
echo ""
echo "=== Phase 1: Cross-compile kernels ==="

build_one x86_64      x86       ""                      x86_64_defconfig
build_one aarch64     arm64     aarch64-linux-gnu-      defconfig
build_one riscv64     riscv     riscv64-linux-gnu-      defconfig
build_one s390x       s390      s390x-linux-gnu-        defconfig
build_one powerpc64   powerpc   powerpc64le-linux-gnu-  ppc64_defconfig
build_one sparc64     sparc     sparc64-linux-gnu-      sparc64_defconfig
build_one alpha       alpha     alpha-linux-gnu-        defconfig
build_one loongarch64 loongarch loongarch64-linux-gnu-  defconfig
build_one riscv32     riscv     riscv32-linux-gnu-      rv32_defconfig
build_one m68k        m68k      m68k-linux-gnu-         multi_defconfig
build_one hppa        parisc    hppa-linux-gnu-         generic-32bit_defconfig
build_one mips64      mips      mips64-linux-gnu-       malta_defconfig
build_one arm         arm       arm-linux-gnu-          multi_v7_defconfig
build_one arm-lpae    arm       arm-linux-gnu-          vexpress_defconfig
build_one hppa64      parisc    hppa64-linux-gnu-       generic-64bit_defconfig
build_one microblaze  microblaze microblaze-linux-gnu-  defconfig

echo ""
echo "Build results: $BPASS passed, $BFAIL failed"
echo ""

echo "=== Phase 2: QEMU boot + LTP tests ==="

run_test() {
    local name="$1" qemu_cmd="$2" kernel="$3" initrd="$4" append="$5" tout="${6:-600}"
    local log="$TLOGDIR/test-$name.log"
    [ -f "$kernel" ] || { echo "TEST [$name] SKIP (no kernel)"; return; }
    echo -n "TEST [$name] "
    timeout "$tout" $qemu_cmd -kernel "$kernel" \
        ${initrd:+-initrd "$initrd"} ${append:+-append "$append"} \
        > "$log" 2>&1 || true
    if grep -q "LTP subtotals:" "$log"; then
        local ltp=$(grep "LTP subtotals:" "$log" | tail -1 | sed 's/.*LTP subtotals: //')
        local warn=""
        if grep -q "WARNING: kernel log contains errors" "$log"; then warn=" *** KERN WARN ***"; fi
        echo "LTP: $ltp$warn"
    elif grep -q "Test Summary:" "$log"; then
        grep "Test Summary:" "$log" | tail -1
    elif grep -q "Boot successful" "$log"; then
        echo "BOOT OK"
    else
        echo "NO RESULT (check $log)"
        tail -3 "$log"
    fi
}

K="$KBUILD"
I="$INITRAMFS"

run_test x86_64 \
    "qemu-system-x86_64 -M pc -m 8G -smp 4 -nographic -no-reboot" \
    "$K/x86_64/arch/x86/boot/bzImage" "$I/initramfs-x86_64.cpio.gz" \
    "console=ttyS0 nokaslr nopti panic=1 autotest=1" 600

run_test aarch64 \
    "qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot" \
    "$K/aarch64/arch/arm64/boot/Image" "$I/initramfs-aarch64.cpio.gz" \
    "console=ttyAMA0 panic=1 autotest=1" 600

run_test riscv64 \
    "qemu-system-riscv64 -M virt -m 8G -smp 4 -nographic -no-reboot -bios default" \
    "$K/riscv64/arch/riscv/boot/Image" "$I/initramfs-riscv64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

run_test s390x \
    "qemu-system-s390x -m 8G -smp 1 -nographic -no-reboot -nodefaults -serial stdio" \
    "$K/s390x/arch/s390/boot/bzImage" "$I/initramfs-s390x.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

run_test powerpc64 \
    "qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot" \
    "$K/powerpc64/vmlinux" "$I/initramfs-powerpc64.cpio.gz" \
    "console=hvc0 panic=1 autotest=1" 600

run_test sparc64 \
    "qemu-system-sparc64 -M sun4u -m 4G -nographic -no-reboot" \
    "$K/sparc64/arch/sparc/boot/image" "$I/initramfs-sparc64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 900

run_test alpha \
    "qemu-system-alpha -m 2G -display none -serial stdio -no-reboot" \
    "$K/alpha/vmlinux" "$I/initramfs-alpha.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 900

run_test riscv32 \
    "qemu-system-riscv32 -M virt -m 2G -smp 4 -nographic -no-reboot -bios default" \
    "$K/riscv32/arch/riscv/boot/Image" "$I/initramfs-riscv32.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 600

run_test m68k \
    "qemu-system-m68k -M virt -m 512M -nographic -no-reboot" \
    "$K/m68k/vmlinux" "$I/initramfs-m68k.cpio.gz" \
    "console=ttyGF0 panic=1 autotest=1" 900

run_test hppa \
    "qemu-system-hppa -m 3G -nographic -no-reboot" \
    "$K/hppa/vmlinux" "$I/initramfs-hppa.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 1200

# mips64: embedded initramfs
run_test mips64 \
    "qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot" \
    "$K/mips64/vmlinux" "" "" 1200

run_test arm \
    "qemu-system-arm -M virt -cpu cortex-a15 -m 768M -nographic -no-reboot" \
    "$K/arm/arch/arm/boot/zImage" "$I/initramfs-arm.cpio.gz" \
    "console=ttyAMA0 panic=1 autotest=1" 600

# arm-lpae needs DTB
if [ -f "$K/arm-lpae/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb" ]; then
    run_test arm-lpae \
        "qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 2G -nographic -no-reboot -dtb $K/arm-lpae/arch/arm/boot/dts/arm/vexpress-v2p-ca15-tc1.dtb" \
        "$K/arm-lpae/arch/arm/boot/zImage" "$I/initramfs-arm.cpio.gz" \
        "console=ttyAMA0 panic=1 autotest=1" 600
else
    echo "TEST [arm-lpae] SKIP (no DTB)"
fi

# hppa64 (use qemu-system-hppa for 64-bit)
run_test hppa64 \
    "qemu-system-hppa -m 8G -nographic -no-reboot" \
    "$K/hppa64/vmlinux" "$I/initramfs-hppa64.cpio.gz" \
    "console=ttyS0 panic=1 autotest=1" 1200

# loongarch64: ESP disk boot
if [ -f "$K/loongarch64/arch/loongarch/boot/vmlinuz.efi" ]; then
    echo -n "TEST [loongarch64] "
    ESPDIR=$(mktemp -d)
    DISKIMG=$(mktemp --suffix=.img)
    mkdir -p "$ESPDIR/EFI/BOOT"
    cp "$K/loongarch64/arch/loongarch/boot/vmlinuz.efi" "$ESPDIR/EFI/BOOT/BOOTLOONGARCH64.EFI"
    dd if=/dev/zero of="$DISKIMG" bs=1M count=256 2>/dev/null
    mkfs.vfat -F 32 "$DISKIMG" 2>/dev/null
    mcopy -i "$DISKIMG" -s "$ESPDIR/EFI" ::/ 2>/dev/null
    timeout 900 qemu-system-loongarch64 -M virt -m 8G -nographic -no-reboot \
        -drive file="$DISKIMG",format=raw,if=virtio \
        -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd \
        > "$TLOGDIR/test-loongarch64.log" 2>&1 || true
    rm -f "$DISKIMG"; rm -rf "$ESPDIR"
    if grep -q "LTP subtotals:" "$TLOGDIR/test-loongarch64.log"; then
        ltp=$(grep "LTP subtotals:" "$TLOGDIR/test-loongarch64.log" | tail -1 | sed 's/.*LTP subtotals: //')
        echo "LTP: $ltp"
    else
        echo "check log"
    fi
else
    echo "TEST [loongarch64] SKIP (no kernel)"
fi

# microblaze: embedded initramfs
run_test microblaze \
    "qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot" \
    "$K/microblaze/arch/microblaze/boot/linux.bin" "" "" 600

echo ""
echo "===== Pipeline complete — $(date) ====="
echo "Build logs: $BLOGDIR"
echo "Test logs:  $TLOGDIR"
