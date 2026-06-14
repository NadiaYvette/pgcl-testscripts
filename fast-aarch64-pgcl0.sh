#!/bin/bash
# Newton-limit regression: build the SAME worktree at PAGE_MMUSHIFT=0 and boot.
# PGCL=0 must reproduce exact mainline behaviour (the #if PAGE_MMUSHIFT blocks
# in memory.c/rmap.c/migrate.c compile out, so all rmap edits must be inert).
set -u
KB=/home/nyc/src/pgcl/kernel-build-fast/aarch64-pgcl0
WT=/home/nyc/src/linux-pgcl-mc
INITRD=${INITRD:-/home/nyc/src/pgcl/userspace/initramfs/initramfs-aarch64.cpio.gz}
LOG=${1:-/home/nyc/src/pgcl/ca-out/aarch64_pgcl0.log}
case "$LOG" in /*) ;; *) LOG="$PWD/$LOG" ;; esac
BOOT_TIMEOUT=${2:-200}
J=${J:-16}
cd "$WT" || exit 9
if [ ! -f "$KB/.config" ]; then
  echo "=== configure (first run) $(date +%H:%M:%S) ==="
  mkdir -p "$KB"
  make ARCH=arm64 O="$KB" defconfig >/dev/null 2>&1 || { echo DEFCONFIG-FAIL; exit 4; }
  scripts/config --file "$KB/.config" --set-val PAGE_MMUSHIFT 0 \
      --enable DEBUG_VM --enable DEBUG_VM_PGFLAGS --enable PAGE_OWNER \
      --enable BLK_DEV_INITRD
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$KB" olddefconfig >/dev/null 2>&1
fi
echo "=== build (j=$J) $(date +%H:%M:%S) ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$KB" -j"$J" Image 2>&1 | tail -4
[ -f "$KB/arch/arm64/boot/Image" ] || { echo "BUILD-FAIL"; exit 1; }
echo "=== boot (timeout ${BOOT_TIMEOUT}s) $(date +%H:%M:%S) ==="
timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 \
  -nographic -no-reboot \
  -kernel "$KB/arch/arm64/boot/Image" \
  -initrd "$INITRD" \
  -append "console=ttyAMA0 panic=1 autotest=1 page_owner=on" >"$LOG" 2>&1
echo "=== done $(date +%H:%M:%S) ==="
echo "markers=$(grep -ciE 'Bad page state|bad_page|nonzero (map|ref)count|VM_BUG|still mapped|kernel BUG' "$LOG" 2>/dev/null)  PGCLDBG=$(grep -c PGCLDBG "$LOG" 2>/dev/null)"
grep -E 'cow: (PASS|FAIL)|Results: [0-9]+ passed|Run /init as init' "$LOG" 2>/dev/null | tail -3
