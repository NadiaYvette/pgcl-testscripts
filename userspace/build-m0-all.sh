#!/bin/bash
# Build all MMUSHIFT=0 baseline kernels sequentially, compacting after each
set -o pipefail

LINUX_SRC=/home/nyc/src/linux
TMP_BASE=/home/nyc/src/pgcl/tmp
BUILD_JOBS=$(($(nproc) / 2))
[ "$BUILD_JOBS" -lt 4 ] && BUILD_JOBS=4

# Architecture → linux_arch|cross_prefix|defconfig
declare -A ARCH_INFO=(
    [x86_64]="x86||x86_64_defconfig"
    [aarch64]="arm64|aarch64-linux-gnu-|defconfig"
    [riscv64]="riscv|riscv64-linux-gnu-|defconfig"
    [s390x]="s390|s390x-linux-gnu-|defconfig"
    [powerpc64]="powerpc|powerpc64-linux-gnu-|ppc64_defconfig"
    [sparc64]="sparc|sparc64-linux-gnu-|sparc64_defconfig"
    [alpha]="alpha|alpha-linux-gnu-|defconfig"
    [loongarch64]="loongarch|loongarch64-linux-gnu-|defconfig"
    [riscv32]="riscv|riscv32-linux-gnu-|rv32_defconfig"
    [m68k]="m68k|m68k-linux-gnu-|multi_defconfig"
    [hppa]="parisc|hppa-linux-gnu-|generic-32bit_defconfig"
    [hppa64]="parisc|hppa64-linux-gnu-|generic-64bit_defconfig"
    [mips64]="mips|mips64-linux-gnu-|malta_defconfig"
    [arm]="arm|arm-linux-gnu-|multi_v7_defconfig"
    [arm32-lpae]="arm|arm-linux-gnu-|vexpress_defconfig"
    [microblaze]="microblaze|microblaze-linux-gnu-|mmu_defconfig"
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ts() { date '+%H:%M:%S'; }

ARCHES=(x86_64 aarch64 riscv64 s390x powerpc64 sparc64 alpha loongarch64 riscv32 m68k hppa hppa64 mips64 arm arm32-lpae microblaze)

for arch in "${ARCHES[@]}"; do
    kbuild="$TMP_BASE/kbuild-${arch}-m0"

    # Skip if already built
    if [ -f "$kbuild/.config" ]; then
        cur_shift=$(grep "^CONFIG_PAGE_MMUSHIFT=" "$kbuild/.config" 2>/dev/null | cut -d= -f2)
        if [ "$cur_shift" = "0" ] && [ -f "$kbuild/vmlinux" -o -d "$kbuild/arch" ]; then
            echo "[$(ts)] SKIP $arch-m0: already built"
            continue
        fi
    fi

    IFS='|' read -r linux_arch cross defconfig <<< "${ARCH_INFO[$arch]}"
    echo "[$(ts)] Building $arch-m0..."
    mkdir -p "$kbuild"

    make_args="ARCH=$linux_arch"
    [ -n "$cross" ] && make_args="$make_args CROSS_COMPILE=$cross"
    make_args="$make_args O=$kbuild"

    make -C "$LINUX_SRC" $make_args "$defconfig" -j$BUILD_JOBS 2>&1 | tail -2
    kconfig="$kbuild/.config"

    "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_PAGE_MMUSHIFT 0

    # Arch-specific config
    case "$arch" in
        arm32-lpae)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_ARM_LPAE
            ;;
        powerpc64)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --disable CONFIG_PPC_64K_PAGES
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_PPC_4K_PAGES
            ;;
        m68k)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_GOLDFISH
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_GOLDFISH_TTY
            ;;
        mips64)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_64BIT
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_MIPS64_R2
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_BIG_ENDIAN
            ;;
        microblaze)
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CPU_BIG_ENDIAN
            "$LINUX_SRC/scripts/config" --file "$kconfig" --disable CONFIG_CPU_LITTLE_ENDIAN
            mb_initramfs="$SCRIPT_DIR/initramfs/initramfs-microblaze.cpio.gz"
            [ -f "$mb_initramfs" ] && "$LINUX_SRC/scripts/config" --file "$kconfig" --set-str CONFIG_INITRAMFS_SOURCE "$mb_initramfs"
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-val CONFIG_KERNEL_BASE_ADDR 0x90000000
            ;;
        loongarch64)
            la_initramfs="$SCRIPT_DIR/initramfs/initramfs-loongarch64.cpio.gz"
            [ -f "$la_initramfs" ] && "$LINUX_SRC/scripts/config" --file "$kconfig" --set-str CONFIG_INITRAMFS_SOURCE "$la_initramfs"
            "$LINUX_SRC/scripts/config" --file "$kconfig" --set-str CONFIG_CMDLINE "console=ttyS0,115200 autotest=1"
            "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_CMDLINE_BOOL
            ;;
    esac

    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_PRINTK
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_SERIAL_8250
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_SERIAL_8250_CONSOLE
    "$LINUX_SRC/scripts/config" --file "$kconfig" --enable CONFIG_BLK_DEV_INITRD

    make -C "$LINUX_SRC" $make_args olddefconfig -j$BUILD_JOBS 2>&1 | tail -2

    # Verify MMUSHIFT
    actual=$(grep "^CONFIG_PAGE_MMUSHIFT=" "$kconfig" | cut -d= -f2)
    if [ "$actual" != "0" ]; then
        echo "[$(ts)] WARNING: $arch MMUSHIFT=$actual (wanted 0)"
    fi

    # Build target
    target=""
    [ "$arch" = "microblaze" ] && target="simpleImage.system"

    if ! make -C "$LINUX_SRC" $make_args $target -j$BUILD_JOBS 2>&1 | tail -5; then
        echo "[$(ts)] BUILD FAILED: $arch-m0"
        continue
    fi

    # Compact: remove .o files, keep kernel image + .config
    find "$kbuild" -name "*.o" -o -name "*.a" -o -name "*.ko" -o -name "*.cmd" -o -name ".tmp*" 2>/dev/null | xargs rm -f 2>/dev/null || true
    size=$(du -sh "$kbuild" 2>/dev/null | cut -f1)
    echo "[$(ts)] DONE $arch-m0 ($size after compact)"

    sync
done

echo ""
echo "=== All m0 builds complete ==="
for arch in "${ARCHES[@]}"; do
    d="$TMP_BASE/kbuild-${arch}-m0"
    if [ -f "$d/vmlinux" ] || [ -d "$d/arch" ]; then
        echo "  $arch: $(du -sh "$d" 2>/dev/null | cut -f1)"
    else
        echo "  $arch: MISSING"
    fi
done
