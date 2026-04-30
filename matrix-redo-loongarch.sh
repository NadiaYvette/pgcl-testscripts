#!/bin/bash
# Redo loongarch64 cells using ESP-disk EDK2 boot (vmlinuz.efi → BOOTLOONGARCH64.EFI on FAT32 ESP).
set -u
export PATH="/usr/bin:$PATH"

D=/home/nyc/src/pgcl
INITRAMFS="$D/userspace/initramfs"
OUTDIR="$D/matrix-20260429-200347"

# (LINUX_DIR, CONFIG) pairs for loongarch64
PAIRS=(
  "/home/nyc/src/linux-mainline mainline"
  "/home/nyc/src/linux 4"
)

for pair in "${PAIRS[@]}"; do
  set -- $pair
  LINUX_DIR=$1
  CONFIG=$2
  KBUILD="$D/kernel-build-matrix/$CONFIG/loongarch64"
  KIMG="$KBUILD/arch/loongarch/boot/vmlinuz.efi"
  LOG="$OUTDIR/loongarch64_${CONFIG}.log"

  if [ ! -f "$KIMG" ]; then
    echo "SKIP $CONFIG: no kernel at $KIMG"
    continue
  fi

  echo "=== loongarch64 $CONFIG: building ESP and running QEMU → $LOG ==="
  ESPDIR=$(mktemp -d)
  DISKIMG=$(mktemp --suffix=.img)
  mkdir -p "$ESPDIR/EFI/BOOT"
  cp "$KIMG" "$ESPDIR/EFI/BOOT/BOOTLOONGARCH64.EFI"
  dd if=/dev/zero of="$DISKIMG" bs=1M count=256 status=none
  mkfs.vfat -F 32 "$DISKIMG" >/dev/null 2>&1
  mcopy -i "$DISKIMG" -s "$ESPDIR/EFI" ::/

  {
    echo "=== matrix cell (REDO): ARCH=loongarch64 CONFIG=$CONFIG LINUX_DIR=$LINUX_DIR ==="
    date
    echo "=== using existing build at $KBUILD ==="
    echo "=== build OK ==="
    echo "=== running QEMU (timeout=900, ESP boot) ==="
    date
    timeout 900 qemu-system-loongarch64 -M virt -cpu la464 -m 8G -smp 4 -nographic -no-reboot \
      -bios /usr/share/edk2/loongarch64/QEMU_EFI.fd \
      -drive file="$DISKIMG",format=raw,if=virtio 2>&1 | tail -300
    RC=${PIPESTATUS[0]}
    echo "=== QEMU exited rc=$RC ==="
    date
  } > "$LOG" 2>&1

  rm -f "$DISKIMG"; rm -rf "$ESPDIR"
done

echo "=== loongarch64 redo done ==="
