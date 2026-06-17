#!/bin/bash
# matrix-driver.sh: run a (LINUX_DIR, ARCH, CONFIG) cell.
# Builds kernel and runs QEMU.  Writes one log per cell.

set -u
export PATH="/usr/bin:$HOME/x-tools/gcc-16.1.0-nolibc/sh4-linux/bin:$HOME/x-tools/gcc-16.1.0-nolibc/csky-linux/bin:$HOME/src/csky-qemu-build/bin:$PATH"

D=/home/nyc/src/pgcl
INITRAMFS="$D/userspace/initramfs"

LINUX_DIR=${1:?usage: matrix-driver.sh LINUX_DIR ARCH CONFIG OUTDIR}
ARCH=${2:?}
CONFIG=${3:?}
OUTDIR=${4:?}

mkdir -p "$OUTDIR"
LOG="$OUTDIR/${ARCH}_${CONFIG}.log"
exec > "$LOG" 2>&1
echo "=== matrix cell: ARCH=$ARCH CONFIG=$CONFIG LINUX_DIR=$LINUX_DIR ==="
date

XAPP=""   # optional extra kernel cmdline tokens (per-arch)
case "$ARCH" in
  x86_64)      LA=x86;        CC="";                       DC=x86_64_defconfig;       QEMU="qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot";       KIMG=arch/x86/boot/bzImage;            CONSOLE=ttyS0 ;;
  aarch64)     LA=arm64;      CC=aarch64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot";    KIMG=arch/arm64/boot/Image;            CONSOLE=ttyAMA0 ;;
  riscv64)     LA=riscv;      CC=riscv64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-riscv64 -M virt -cpu rv64 -m 8G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  ppc64)       LA=powerpc;    CC=powerpc64le-linux-gnu-;   DC=ppc64_defconfig;        QEMU="qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot";                   KIMG=vmlinux;                          CONSOLE=hvc0 ;;
  s390x)       LA=s390;       CC=s390x-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-s390x -M s390-ccw-virtio -cpu max -m 8G -nographic -no-reboot";         KIMG=arch/s390/boot/bzImage;           CONSOLE=sclp0 ;;
  sparc64)     LA=sparc;      CC=sparc64-linux-gnu-;       DC=sparc64_defconfig;      QEMU="qemu-system-sparc64 -M sun4u -cpu TI-UltraSparc-IIi -m 4G -nographic -no-reboot";   KIMG=arch/sparc/boot/image;            CONSOLE=ttyS0 ;;
  loongarch64) LA=loongarch;  CC=loongarch64-linux-gnu-;   DC=defconfig;              QEMU="qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -nographic -no-reboot";     KIMG=arch/loongarch/boot/vmlinuz.efi;  CONSOLE=ttyS0,115200 ;;
  sh4)         LA=sh;         CC=sh4-linux-;               DC=rts7751r2dplus_defconfig; QEMU="qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot";                       KIMG=arch/sh/boot/zImage;              CONSOLE=ttySC1,115200; XAPP=noiotrap ;;
  xtensa)      LA=xtensa;     CC=xtensa-linux-gnu-;        DC=defconfig;              QEMU="qemu-system-xtensa -M sim -m 128 -display none -serial stdio -no-reboot";            KIMG=vmlinux;                          CONSOLE=ttyS0,38400 ;;
  csky)        LA=csky;       CC=csky-linux-;              DC=defconfig;              QEMU="qemu-system-cskyv2 -M virt -cpu c807 -nographic -no-reboot";                        KIMG=vmlinux;                          CONSOLE=ttyS0,115200 ;;
  *) echo "ERROR: unknown arch $ARCH"; exit 2 ;;
esac

KBUILD="$D/kernel-build-matrix/$CONFIG/$ARCH"
rm -rf "$KBUILD"; mkdir -p "$KBUILD"

cd "$LINUX_DIR" || exit 3
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" "$DC" >/dev/null 2>&1 || { echo "DEFCONFIG FAIL"; exit 4; }

if [ "$CONFIG" != "mainline" ]; then
  scripts/config --file "$KBUILD/.config" --set-val PAGE_MMUSHIFT "$CONFIG"
fi

case "$ARCH" in
  ppc64)
    scripts/config --file "$KBUILD/.config" --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES ;;
  loongarch64)
    scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
        --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
        --enable CMDLINE_BOOL --enable EFI_STUB ;;
  sh4)
    # r2d board: embed the (nolibc) initramfs + force the cmdline (board has no -initrd path)
    scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-sh4.cpio.gz" \
        --enable CMDLINE_OVERWRITE \
        --set-str CMDLINE "console=ttySC1,115200 noiotrap panic=1 autotest=1" ;;
  xtensa)
    # sim/ISS: built-in cmdline + embedded initramfs (boot bring-up still in progress)
    scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-xtensa.cpio.gz" \
        --enable CMDLINE_BOOL --enable CMDLINE_FORCE \
        --set-str CMDLINE "console=ttyS0,38400 panic=1 autotest=1" ;;
  csky)
    # virt: embed initramfs; csky qemu hardcodes DTB bootargs rdinit=/sbin/init (cpio has it)
    scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-csky.cpio.gz" ;;
esac

make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" olddefconfig >/dev/null 2>&1
echo "=== building ==="
date
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" -j8 2>&1 | tail -3
[ -f "$KBUILD/$KIMG" ] || { echo "BUILD FAIL: missing $KIMG"; exit 5; }
echo "=== build OK ==="
date

INITRD_ARG="-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz"
[ "$ARCH" = "ppc64" ] && INITRD_ARG="-initrd $INITRAMFS/initramfs-powerpc64.cpio.gz"
# sh4 (r2d) and xtensa (sim) embed the initramfs via CONFIG_INITRAMFS_SOURCE; no external -initrd
case "$ARCH" in sh4|xtensa|csky) INITRD_ARG="" ;; esac

# Per-config timeout — mainline tests should be fast; first run on new arch may need more
TIMEOUT=300
case "$ARCH" in
  ppc64|sparc64) TIMEOUT=400 ;;
  sh4|xtensa|csky) TIMEOUT=400 ;;
esac

echo "=== running QEMU (timeout=$TIMEOUT) ==="
date
timeout "$TIMEOUT" $QEMU \
  -kernel "$KBUILD/$KIMG" \
  $INITRD_ARG \
  -append "console=$CONSOLE${XAPP:+ $XAPP} panic=1 autotest=1" 2>&1 | tail -300
RC=${PIPESTATUS[0]}
# Do NOT pkill -f "qemu-system-$LA" — that would kill sibling cells running the same arch in parallel.
# `timeout` already sends SIGTERM/SIGKILL to its direct child (qemu) on expiry.
echo "=== QEMU exited rc=$RC ==="
date
