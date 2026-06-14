#!/bin/bash
# matrix-driver-all.sh: 16-arch × 5-config cell driver for the full 80-cell matrix.
#
# Differences vs matrix-driver.sh / matrix-driver-slow.sh:
#   - Knows all 16 arches (adds alpha, riscv32, m68k, hppa, mips64, arm, arm-lpae,
#     hppa64, microblaze on top of the 7 fast arches)
#   - Cleans up the per-cell build dir after QEMU exits (rm -rf $KBUILD), keeping
#     only the test log under $OUTDIR.  Peak per-cell footprint ~2GB; final
#     footprint just the log (KB).  Required because the full 80-cell run
#     would otherwise need ~170GB.
#   - Uses TMPDIR=/home/nyc/src/pgcl/tmp for compiler temp files (avoids
#     /tmp swap pressure per user note).
#
# Usage: matrix-driver-all.sh LINUX_DIR ARCH CONFIG OUTDIR

set -u
export PATH="/usr/bin:$PATH"
export TMPDIR="${TMPDIR:-/home/nyc/src/pgcl/tmp}"
mkdir -p "$TMPDIR"

D=/home/nyc/src/pgcl
INITRAMFS="$D/userspace/initramfs"

LINUX_DIR=${1:?usage: matrix-driver-all.sh LINUX_DIR ARCH CONFIG OUTDIR}
ARCH=${2:?}
CONFIG=${3:?}
OUTDIR=${4:?}

mkdir -p "$OUTDIR"
LOG="$OUTDIR/${ARCH}_${CONFIG}.log"
exec > "$LOG" 2>&1
echo "=== matrix cell: ARCH=$ARCH CONFIG=$CONFIG LINUX_DIR=$LINUX_DIR ==="
date

case "$ARCH" in
  x86_64)      LA=x86;        CC="";                       DC=x86_64_defconfig;       QEMU="qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot";       KIMG=arch/x86/boot/bzImage;            CONSOLE=ttyS0 ;;
  aarch64)     LA=arm64;      CC=aarch64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot";    KIMG=arch/arm64/boot/Image;            CONSOLE=ttyAMA0 ;;
  riscv64)     LA=riscv;      CC=riscv64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-riscv64 -M virt -cpu rv64 -m 8G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  ppc64)       LA=powerpc;    CC=powerpc64le-linux-gnu-;   DC=ppc64_defconfig;        QEMU="qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot";                   KIMG=vmlinux;                          CONSOLE=hvc0 ;;
  s390x)       LA=s390;       CC=s390x-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-s390x -M s390-ccw-virtio -cpu max -m 8G -nographic -no-reboot";         KIMG=arch/s390/boot/bzImage;           CONSOLE=sclp0 ;;
  sparc64)     LA=sparc;      CC=sparc64-linux-gnu-;       DC=sparc64_defconfig;      QEMU="qemu-system-sparc64 -M sun4u -cpu TI-UltraSparc-IIi -m 4G -nographic -no-reboot";   KIMG=arch/sparc/boot/image;            CONSOLE=ttyS0 ;;
  loongarch64) LA=loongarch;  CC=loongarch64-linux-gnu-;   DC=defconfig;              QEMU="qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -nographic -no-reboot";     KIMG=arch/loongarch/boot/vmlinuz.efi;  CONSOLE=ttyS0,115200 ;;
  alpha)       LA=alpha;      CC=alpha-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-alpha -M clipper -m 2G -display none -serial stdio -no-reboot";        KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  riscv32)     LA=riscv;      CC=riscv32-linux-gnu-;       DC=rv32_defconfig;         QEMU="qemu-system-riscv32 -M virt -cpu rv32 -m 2G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  m68k)        LA=m68k;       CC=m68k-linux-gnu-;          DC=multi_defconfig;        QEMU="qemu-system-m68k -M virt -m 512M -nographic -no-reboot";                            KIMG=vmlinux;                          CONSOLE=ttyGF0 ;;
  hppa)        LA=parisc;     CC=hppa-linux-gnu-;          DC=generic-32bit_defconfig;QEMU="qemu-system-hppa -M C3700 -m 3G -nographic -no-reboot";                            KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  mips64)      LA=mips;       CC=mips64-linux-gnu-;        DC=malta_defconfig;        QEMU="qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G -nographic -no-reboot";     KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  arm)         LA=arm;        CC=arm-linux-gnu-;           DC=multi_v7_defconfig;     QEMU="qemu-system-arm -M virt -cpu cortex-a15 -m 768M -nographic -no-reboot";             KIMG=arch/arm/boot/zImage;             CONSOLE=ttyAMA0 ;;
  arm-lpae)    LA=arm;        CC=arm-linux-gnu-;           DC=vexpress_defconfig;     QEMU="qemu-system-arm -M virt -cpu cortex-a15 -m 2G -nographic -no-reboot";              KIMG=arch/arm/boot/zImage;             CONSOLE=ttyAMA0 ;;
  hppa64)      LA=parisc64;   CC=hppa64-linux-gnu-;        DC=generic-64bit_defconfig;QEMU="qemu-system-hppa -M C3700 -m 8G -nographic -no-reboot";                            KIMG=vmlinux;                          CONSOLE=ttyS0 ;;
  microblaze)  LA=microblaze; CC=microblaze-linux-gnu-;    DC=defconfig;              QEMU="qemu-system-microblaze -M petalogix-s3adsp1800 -nographic -no-reboot";              KIMG=arch/microblaze/boot/linux.bin;   CONSOLE=ttyUL0 ;;
  *) echo "ERROR: unknown arch $ARCH"; exit 2 ;;
esac

KBUILD="$D/kernel-build-matrix/$CONFIG/$ARCH"
rm -rf "$KBUILD"; mkdir -p "$KBUILD"

cd "$LINUX_DIR" || exit 3
# DC may be a single target (e.g. defconfig) or a space-separated list
# (e.g. "defconfig 32-bit.config" for riscv32) — keep unquoted on purpose.
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" $DC >/dev/null 2>&1 || { echo "DEFCONFIG FAIL"; exit 4; }

if [ "$CONFIG" != "mainline" ]; then
  scripts/config --file "$KBUILD/.config" --set-val PAGE_MMUSHIFT "$CONFIG"
fi

# Generic: ensure external -initrd works.  Some defconfigs (notably alpha)
# don't enable BLK_DEV_INITRD by default; force it so our QEMU -initrd path
# is honored on every arch.  Idempotent on arches that already have it.
scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD

# BIGRAM_DEBUG=1: un-silence page/mm corruption detectors so a bad free is
# caught + the culprit named (pair with EXTRA_APPEND="page_owner=on").
if [ "${BIGRAM_DEBUG:-0}" = 1 ]; then
  scripts/config --file "$KBUILD/.config" \
      --enable DEBUG_VM --enable DEBUG_VM_PGFLAGS --enable PAGE_OWNER
fi

# Per-arch config tweaks (mirror full-pipeline.sh / matrix-run.sh)
case "$ARCH" in
  ppc64)
    scripts/config --file "$KBUILD/.config" --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES ;;
  loongarch64)
    scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
        --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
        --enable CMDLINE_BOOL --enable EFI_STUB ;;
  microblaze)
    scripts/config --file "$KBUILD/.config" \
        --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
        --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-microblaze.cpio.gz" \
        --set-str CMDLINE "console=ttyUL0 panic=1 autotest=1" --enable CMDLINE_BOOL ;;
  mips64)
    scripts/config --file "$KBUILD/.config" \
        --enable 64BIT --enable CPU_MIPS64_R2 \
        --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
        --enable BLK_DEV_INITRD \
        --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-mips64.cpio.gz" \
        --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" --enable CMDLINE_BOOL ;;
  arm-lpae)
    scripts/config --file "$KBUILD/.config" --enable ARM_LPAE ;;
  m68k)
    # m68k -M virt requires CONFIG_VIRT (Mac/Atari/Amiga multi_defconfig
    # doesn't enable it).  Without it, the kernel never inits goldfish UART
    # and produces zero console output.  Also disable NE2000 — it crashes
    # in ne_drv_probe during do_one_initcall on m68k-virt, which kills
    # init-thread (pid 1) and panics the kernel before userspace runs.
    scripts/config --file "$KBUILD/.config" \
        --enable VIRT --enable VIRTIO_MMIO --enable VIRTIO_MENU \
        --enable RTC_DRV_GOLDFISH \
        --enable GOLDFISH --enable GOLDFISH_TTY \
        --disable NE2000 ;;
esac

make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" olddefconfig >/dev/null 2>&1
echo "=== building ==="
date
make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" -j"${MATRIX_J:-2}" 2>&1 | tail -3
[ -f "$KBUILD/$KIMG" ] || { echo "BUILD FAIL: missing $KIMG"; rm -rf "$KBUILD"; exit 5; }

# arm-lpae also needs the vexpress DTB to be built — default `make` may not include it.
if [ "$ARCH" = "arm-lpae" ]; then
    make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" -j"${MATRIX_J:-2}" dtbs 2>&1 | tail -3
fi

echo "=== build OK ==="
date

# Per-arch initrd strategy
INITRD_ARG=""
case "$ARCH" in
  microblaze) ;;  # initrd is embedded
  loongarch64) ;; # disk-based ESP boot (handled below)
  ppc64) INITRD_ARG="-initrd $INITRAMFS/initramfs-powerpc64.cpio.gz" ;;
  arm-lpae) INITRD_ARG="-initrd $INITRAMFS/initramfs-arm.cpio.gz" ;;  # shares with arm
  *) INITRD_ARG="-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz" ;;
esac

# arm-lpae uses -M virt (cortex-a15 + LPAE).  -M vexpress-a15 needs a DTB
# and the older platform code path doesn't reliably produce console output
# even with the right DTB; -M virt is far more forgiving and still exercises
# the LPAE long-descriptor page-table code paths in the kernel.
EXTRA_QEMU=""

# Per-arch QEMU timeout (slow emulated arches need larger budgets)
case "$ARCH" in
  microblaze)            TIMEOUT=1500 ;;
  hppa|hppa64|m68k)      TIMEOUT=900 ;;
  mips64)                TIMEOUT=1800 ;; # ~10x slower QEMU per MEMORY.md
  alpha)                 TIMEOUT=600 ;;
  s390x)                 TIMEOUT=2400 ;; # single-CPU emulation; boot alone ~6 min under PAR=2 load
  ppc64)                 TIMEOUT=1800 ;; # PGCL=6 LTP end-to-end needs ~1500s
  sparc64)               TIMEOUT=1200 ;;
  arm|arm-lpae)          TIMEOUT=600 ;;
  aarch64)               TIMEOUT=1800 ;; # PGCL=6 LTP end-to-end
  loongarch64)           TIMEOUT=1800 ;; # PGCL=6 LTP end-to-end
  riscv32|riscv64)       TIMEOUT=1800 ;; # PGCL=6 LTP end-to-end
  x86_64)                TIMEOUT=900 ;; # diag: longer + earlyprintk
  *)                     TIMEOUT=300 ;;
esac

echo "=== running QEMU (timeout=$TIMEOUT) ==="
date

if [ "$ARCH" = "loongarch64" ]; then
  # ESP-disk boot path (kernel embedded as BOOTLOONGARCH64.EFI on a FAT32 disk)
  ESPDIR=$(mktemp -d -p "$TMPDIR")
  DISKIMG=$(mktemp --suffix=.img -p "$TMPDIR")
  mkdir -p "$ESPDIR/EFI/BOOT"
  cp "$KBUILD/$KIMG" "$ESPDIR/EFI/BOOT/BOOTLOONGARCH64.EFI"
  dd if=/dev/zero of="$DISKIMG" bs=1M count=256 status=none
  mkfs.vfat -F 32 "$DISKIMG" 2>/dev/null
  mcopy -i "$DISKIMG" -s "$ESPDIR/EFI" ::/ 2>/dev/null
  timeout "$TIMEOUT" $QEMU \
      -drive file="$DISKIMG",format=raw,if=virtio \
      -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd \
      2>&1 | tail -3000
  RC=${PIPESTATUS[0]}
  rm -f "$DISKIMG"; rm -rf "$ESPDIR"
else
  timeout "$TIMEOUT" $QEMU \
    -kernel "$KBUILD/$KIMG" \
    $INITRD_ARG \
    $EXTRA_QEMU \
    -append "console=$CONSOLE panic=1 autotest=1 ${EXTRA_APPEND:-}" 2>&1 | tail -3000
  RC=${PIPESTATUS[0]}
fi

echo "=== QEMU exited rc=$RC ==="
date

# Cleanup: drop the build dir (~2GB) — log is preserved under $OUTDIR.
rm -rf "$KBUILD"
echo "=== cleanup done ==="
