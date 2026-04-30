#!/bin/bash
# PGCL matrix run: build and test each arch under multiple configurations.
# CONFIG values: "mainline" (origin/master, no PGCL), "0", "2", "4", "6" (PGCL with PAGE_MMUSHIFT=N).
#
# Usage: matrix-run.sh ARCH CONFIG  [outdir]
#
# Architecture entries match those in full-pipeline.sh.  Build dirs go under
# kernel-build-matrix/$CONFIG/$ARCH and test logs under matrix-logs-TS/$CONFIG/$ARCH.log
# Returns parsable summary on stdout: "ARCH CONFIG STATUS pgcl-test=X/Y stress=A/B selftest=Pp/Ff/Ss ltp=Pp/Ff/Ss"

set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
LINUX=/home/nyc/src/linux
INITRAMFS="$D/userspace/initramfs"
TS=$(date +%Y%m%d-%H%M%S)

ARCH=${1:?usage: $0 ARCH CONFIG [outdir]}
CONFIG=${2:?usage: $0 ARCH CONFIG [outdir]}
OUTDIR=${3:-$D/matrix-$TS}

mkdir -p "$OUTDIR/$CONFIG"
LOG="$OUTDIR/$CONFIG/$ARCH.log"
exec > "$LOG" 2>&1

KBUILD="$D/kernel-build-matrix/$CONFIG/$ARCH"

case "$ARCH" in
  x86_64)      LA=x86;        CC="";                       DC=x86_64_defconfig;       QEMU="qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot";       KIMG=arch/x86/boot/bzImage;            CONSOLE=ttyS0 ;;
  aarch64)     LA=arm64;      CC=aarch64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot";    KIMG=arch/arm64/boot/Image;            CONSOLE=ttyAMA0 ;;
  riscv64)     LA=riscv;      CC=riscv64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-riscv64 -M virt -cpu rv64 -m 8G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  s390x)       LA=s390;       CC=s390x-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-s390x -M s390-ccw-virtio -cpu max -m 8G -nographic -no-reboot";         KIMG=arch/s390/boot/bzImage;           CONSOLE=sclp0 ;;
  powerpc64)   LA=powerpc;    CC=powerpc64le-linux-gnu-;   DC=ppc64_defconfig;        QEMU="qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot";                   KIMG=vmlinux;                          CONSOLE=hvc0 ;;
  sparc64)     LA=sparc;      CC=sparc64-linux-gnu-;       DC=sparc64_defconfig;      QEMU="qemu-system-sparc64 -M sun4u -cpu TI-UltraSparc-IIi -m 4G -nographic -no-reboot";   KIMG=arch/sparc/boot/image;            CONSOLE=ttyS0 ;;
  alpha)       LA=alpha;      CC=alpha-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-alpha -M clipper -m 2G -display none -serial stdio -no-reboot";        KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  loongarch64) LA=loongarch;  CC=loongarch64-linux-gnu-;   DC=defconfig;              QEMU="qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd -drive file=$D/loongarch-disk.img,format=raw,if=virtio -nographic -no-reboot"; KIMG=arch/loongarch/boot/vmlinuz.efi; CONSOLE=ttyS0,115200 ;;
  riscv32)     LA=riscv;      CC=riscv32-linux-gnu-;       DC=rv32_defconfig;         QEMU="qemu-system-riscv32 -M virt -cpu rv32 -m 2G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  m68k)        LA=m68k;       CC=m68k-linux-gnu-;          DC=multi_defconfig;        QEMU="qemu-system-m68k -M virt -cpu m68040 -m 512M -nographic -no-reboot";                KIMG=vmlinux;                          CONSOLE=ttyGF0 ;;
  hppa)        LA=parisc;     CC=hppa-linux-gnu-;          DC=generic-32bit_defconfig;QEMU="qemu-system-hppa -M C3700 -m 3G -nographic -no-reboot";                            KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  mips64)      LA=mips;       CC=mips64-linux-gnu-;        DC=malta_defconfig;        QEMU="qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot";     KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  arm)         LA=arm;        CC=arm-linux-gnu-;           DC=multi_v7_defconfig;     QEMU="qemu-system-arm -M virt -cpu cortex-a15 -m 768M -nographic -no-reboot";             KIMG=arch/arm/boot/zImage;             CONSOLE=ttyAMA0 ;;
  arm-lpae)    LA=arm;        CC=arm-linux-gnu-;           DC=vexpress_defconfig;     QEMU="qemu-system-arm -M vexpress-a15 -cpu cortex-a15 -m 2G -nographic -no-reboot";       KIMG=arch/arm/boot/zImage;             CONSOLE=ttyAMA0 ;;
  hppa64)      LA=parisc;     CC=hppa64-linux-gnu-;        DC=generic-64bit_defconfig;QEMU="qemu-system-hppa64 -M C3700 -m 8G -nographic -no-reboot";                          KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  microblaze)  LA=microblaze; CC=microblaze-linux-gnu-;    DC=defconfig;              QEMU="qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot";              KIMG=arch/microblaze/boot/linux.bin;   CONSOLE=ttyUL0 ;;
  *) echo "ERROR: unknown arch $ARCH"; exit 2 ;;
esac

cd "$LINUX"

# Switch branch based on CONFIG
case "$CONFIG" in
  mainline) BRANCH=origin/master ;;
  0|2|4|6)  BRANCH=nadia.chambers/page-clustering-001 ;;
  *) echo "ERROR: unknown config $CONFIG (use mainline|0|2|4|6)"; exit 2 ;;
esac

CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CONFIG" = "mainline" ] && [ "$CURRENT" != "(detached)" ]; then
  echo "ERROR: matrix-run.sh requires the worker to manage branch state externally"
  exit 3
fi

echo "=== matrix-run ARCH=$ARCH CONFIG=$CONFIG branch=$BRANCH ==="

rm -rf "$KBUILD"; mkdir -p "$KBUILD"
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" "$DC" >/dev/null 2>&1 || { echo "DEFCONFIG FAIL"; exit 4; }

# Apply CONFIG-specific tweaks
if [ "$CONFIG" != "mainline" ]; then
  scripts/config --file "$KBUILD/.config" --set-val PAGE_MMUSHIFT "$CONFIG"
fi

# Per-arch hacks (BE for microblaze, etc.)
case "$ARCH" in
  microblaze)
    scripts/config --file "$KBUILD/.config" --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
        --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-microblaze.cpio.gz" \
        --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" --enable CMDLINE_BOOL ;;
  mips64)
    scripts/config --file "$KBUILD/.config" --enable 64BIT --enable CPU_MIPS64_R2 \
        --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
        --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-mips64.cpio.gz" \
        --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" --enable CMDLINE_BOOL ;;
  loongarch64)
    scripts/config --file "$KBUILD/.config" \
        --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
        --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" --enable CMDLINE_BOOL --enable EFI_STUB ;;
  powerpc64)
    scripts/config --file "$KBUILD/.config" --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES ;;
  arm-lpae)
    scripts/config --file "$KBUILD/.config" --enable ARM_LPAE ;;
  m68k)
    scripts/config --file "$KBUILD/.config" --enable GOLDFISH --enable GOLDFISH_TTY ;;
esac

make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" olddefconfig >/dev/null 2>&1
echo "=== building ==="
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" -j"$(nproc)" 2>&1 | tail -3 || { echo "BUILD FAIL"; exit 5; }
[ -f "$KBUILD/$KIMG" ] || { echo "BUILD FAIL: missing $KIMG"; exit 6; }

echo "=== running QEMU ==="
INITRD_ARG=""
case "$ARCH" in
  microblaze) ;;  # initrd is embedded
  loongarch64) ;; # disk-based
  *) INITRD_ARG="-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz" ;;
esac

# QEMU timeout — use larger value for slow arches
case "$ARCH" in
  microblaze) TIMEOUT=1500 ;;
  hppa64)     TIMEOUT=600 ;;
  *)          TIMEOUT=300 ;;
esac

timeout "$TIMEOUT" $QEMU \
  -kernel "$KBUILD/$KIMG" \
  $INITRD_ARG \
  -append "console=$CONSOLE panic=1 autotest=1" 2>&1 | tail -200
RC=${PIPESTATUS[0]}
pkill -9 -f "qemu-system-$LA" 2>/dev/null
echo "=== QEMU exited rc=$RC ==="
