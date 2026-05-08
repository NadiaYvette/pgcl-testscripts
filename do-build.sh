#!/bin/bash
# Build one architecture. Usage: do-build.sh ARCH_NAME LINUX_ARCH CROSS_COMPILE DEFCONFIG [EXTRA_CONFIG_CMDS]
set -e
ARCH_NAME="$1"
LINUX_ARCH="$2"
CROSS_COMPILE="$3"
DEFCONFIG="$4"
shift 4
EXTRA="$*"

LINUX=/home/nyc/src/linux
BDIR=/home/nyc/src/pgcl/kernel-build/$ARCH_NAME
INITRAMFS_DIR=/home/nyc/src/pgcl/userspace/initramfs

mkdir -p "$BDIR"
cd "$LINUX"

echo "[$ARCH_NAME] defconfig..."
make ARCH="$LINUX_ARCH" ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} O="$BDIR" "$DEFCONFIG" 2>&1 | tail -2

echo "[$ARCH_NAME] Setting PAGE_MMUSHIFT=4..."
scripts/config --file "$BDIR/.config" --set-val PAGE_MMUSHIFT 4

# Architecture-specific config tweaks
case "$ARCH_NAME" in
    mips64)
        scripts/config --file "$BDIR/.config" \
            --enable 64BIT --enable CPU_MIPS64_R2 \
            --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-mips64.cpio.gz" \
            --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" \
            --enable CMDLINE_BOOL
        ;;
    loongarch64)
        scripts/config --file "$BDIR/.config" \
            --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-loongarch64.cpio.gz" \
            --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
            --enable CMDLINE_BOOL \
            --enable EFI_STUB
        ;;
    microblaze)
        scripts/config --file "$BDIR/.config" \
            --set-str INITRAMFS_SOURCE "$INITRAMFS_DIR/initramfs-microblaze.cpio.gz" \
            --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" \
            --enable CMDLINE_BOOL
        ;;
    powerpc64)
        scripts/config --file "$BDIR/.config" \
            --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES
        ;;
    arm-lpae)
        scripts/config --file "$BDIR/.config" \
            --enable ARM_LPAE
        ;;
esac

# Apply any extra config commands
if [ -n "$EXTRA" ]; then
    eval "$EXTRA"
fi

make ARCH="$LINUX_ARCH" ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} O="$BDIR" olddefconfig 2>&1 | tail -2

echo "[$ARCH_NAME] Building..."
make ARCH="$LINUX_ARCH" ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} O="$BDIR" -j$(nproc) 2>&1

echo "[$ARCH_NAME] Build complete"
