#!/bin/bash
# matrix-driver-slow.sh: same as matrix-driver.sh but with longer QEMU timeouts
# for slow-emulated arches (s390x without KVM, sparc64, etc.). Used to redo cells
# that timed out under the standard driver.

set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
INITRAMFS="$D/userspace/initramfs"

LINUX_DIR=${1:?usage: matrix-driver-slow.sh LINUX_DIR ARCH CONFIG OUTDIR}
ARCH=${2:?}
CONFIG=${3:?}
OUTDIR=${4:?}

mkdir -p "$OUTDIR"
LOG="$OUTDIR/${ARCH}_${CONFIG}.log"
exec > "$LOG" 2>&1
echo "=== matrix-slow cell: ARCH=$ARCH CONFIG=$CONFIG LINUX_DIR=$LINUX_DIR ==="
date

case "$ARCH" in
  x86_64)      LA=x86;        CC="";                       DC=x86_64_defconfig;       QEMU="qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 4 -nographic -no-reboot";       KIMG=arch/x86/boot/bzImage;            CONSOLE=ttyS0 ;;
  aarch64)     LA=arm64;      CC=aarch64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 -nographic -no-reboot";    KIMG=arch/arm64/boot/Image;            CONSOLE=ttyAMA0 ;;
  riscv64)     LA=riscv;      CC=riscv64-linux-gnu-;       DC=defconfig;              QEMU="qemu-system-riscv64 -M virt -cpu rv64 -m 8G -smp 4 -nographic -no-reboot";          KIMG=arch/riscv/boot/Image;            CONSOLE=ttyS0 ;;
  ppc64)       LA=powerpc;    CC=powerpc64le-linux-gnu-;   DC=ppc64_defconfig;        QEMU="qemu-system-ppc64 -M powernv -m 8G -smp 4 -nographic -no-reboot";                   KIMG=vmlinux;                          CONSOLE=hvc0 ;;
  s390x)       LA=s390;       CC=s390x-linux-gnu-;         DC=defconfig;              QEMU="qemu-system-s390x -M s390-ccw-virtio -cpu max -m 8G -nographic -no-reboot";         KIMG=arch/s390/boot/bzImage;           CONSOLE=sclp0 ;;
  sparc64)     LA=sparc;      CC=sparc64-linux-gnu-;       DC=sparc64_defconfig;      QEMU="qemu-system-sparc64 -M sun4u -cpu TI-UltraSparc-IIi -m 4G -nographic -no-reboot";   KIMG=arch/sparc/boot/image;            CONSOLE=ttyS0 ;;
  loongarch64) LA=loongarch;  CC=loongarch64-linux-gnu-;   DC=defconfig;              QEMU="qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -nographic -no-reboot";     KIMG=arch/loongarch/boot/vmlinuz.efi;  CONSOLE=ttyS0,115200 ;;
  *) echo "ERROR: unknown arch $ARCH"; exit 2 ;;
esac

KBUILD="$D/kernel-build-matrix/$CONFIG/$ARCH"
# Reuse existing build if present
if [ -f "$KBUILD/$KIMG" ]; then
  echo "=== reusing existing build at $KBUILD ==="
else
  rm -rf "$KBUILD"; mkdir -p "$KBUILD"
  cd "$LINUX_DIR" || exit 3
  make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" "$DC" >/dev/null 2>&1 || { echo "DEFCONFIG FAIL"; exit 4; }
  if [ "$CONFIG" != "mainline" ]; then
    scripts/config --file "$KBUILD/.config" --set-val PAGE_MMUSHIFT "$CONFIG"
    # PGCL widens PAGE_SIZE by 2^PAGE_MMUSHIFT.  Two scaling cliffs:
    #   - mmzone.h: MAX_PAGE_ORDER + PAGE_SHIFT must stay under
    #     SECTION_SIZE_BITS.  Each arch's Kconfig has a PGCL-aware
    #     ARCH_FORCE_MAX_ORDER ladder (see linux commit 35b392dd4234)
    #     so olddefconfig auto-clamps.
    #   - fs/fat: bhs[MAX_BUF_PER_PAGE] stack arrays (commit
    #     3e7034d73aa6 heap-allocates them).
    # No driver-side workaround needed once those kernel patches land.
  fi
  case "$ARCH" in
    ppc64)       scripts/config --file "$KBUILD/.config" --enable PPC_4K_PAGES --disable PPC_64K_PAGES --disable PPC_16K_PAGES ;;
    loongarch64) scripts/config --file "$KBUILD/.config" --enable BLK_DEV_INITRD \
                     --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-loongarch64.cpio.gz" \
                     --set-str CMDLINE "console=ttyS0,115200 panic=1 autotest=1" \
                     --enable CMDLINE_BOOL --enable EFI_STUB ;;
  esac
  make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" olddefconfig >/dev/null 2>&1
  echo "=== building ==="
  date
  make ARCH="$LA" ${CC:+CROSS_COMPILE=$CC} O="$KBUILD" -j8 2>&1 | tail -3
  [ -f "$KBUILD/$KIMG" ] || { echo "BUILD FAIL: missing $KIMG"; exit 5; }
  echo "=== build OK ==="
  date
fi

INITRD_ARG="-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz"
[ "$ARCH" = "ppc64" ] && INITRD_ARG="-initrd $INITRAMFS/initramfs-powerpc64.cpio.gz"

# Slow-arch generous timeouts (no-KVM emulation paths)
TIMEOUT=900
case "$ARCH" in
  x86_64|aarch64|riscv64|ppc64|loongarch64) TIMEOUT=600 ;;
  s390x|sparc64) TIMEOUT=900 ;;
esac

echo "=== running QEMU (timeout=$TIMEOUT) ==="
date

if [ "$ARCH" = "loongarch64" ]; then
  # LoongArch: -kernel can't load zstd-compressed zboot images on
  # current EDK2 builds.  Stage vmlinuz.efi as BOOTLOONGARCH64.EFI on a
  # FAT32 ESP and boot via -bios EDK2 + -drive disk image.  initramfs
  # and cmdline are already embedded in the kernel via INITRAMFS_SOURCE
  # and CMDLINE in the .config tweaks above.
  ESPDIR=$(mktemp -d)
  DISKIMG=$(mktemp --suffix=.img)
  mkdir -p "$ESPDIR/EFI/BOOT"
  cp "$KBUILD/$KIMG" "$ESPDIR/EFI/BOOT/BOOTLOONGARCH64.EFI"
  dd if=/dev/zero of="$DISKIMG" bs=1M count=256 status=none
  mkfs.vfat -F 32 "$DISKIMG" >/dev/null 2>&1
  mcopy -i "$DISKIMG" -s "$ESPDIR/EFI" ::/
  timeout "$TIMEOUT" qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -nographic -no-reboot \
    -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd \
    -drive file="$DISKIMG",format=raw,if=virtio 2>&1 | tail -300
  RC=${PIPESTATUS[0]}
  rm -f "$DISKIMG"; rm -rf "$ESPDIR"
else
  timeout "$TIMEOUT" $QEMU \
    -kernel "$KBUILD/$KIMG" \
    $INITRD_ARG \
    -append "console=$CONSOLE panic=1 autotest=1" 2>&1 | tail -300
  RC=${PIPESTATUS[0]}
fi
# No pkill — timeout already reaps qemu, and pkill would kill sibling cells.
echo "=== QEMU exited rc=$RC ==="
date
