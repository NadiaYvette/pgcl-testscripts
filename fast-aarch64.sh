#!/bin/bash
# Self-contained fast-iterate for the aarch64 PGCL=4 worktree kernel.
# First run: configure + full build (persistent dir).  Subsequent runs:
# incremental rebuild (only changed objects + relink) + short boot that runs
# far enough to clear the THP/cow stage and surface mapcount markers / PGCLDBG.
set -u
KB=/home/nyc/src/pgcl/kernel-build-fast/aarch64
WT=/home/nyc/src/linux-pgcl-mc
INITRD=${INITRD:-/home/nyc/src/pgcl/userspace/initramfs/initramfs-aarch64.cpio.gz}
LOG=${1:-/home/nyc/src/pgcl/ca-out/aarch64_fast.log}
case "$LOG" in /*) ;; *) LOG="$PWD/$LOG" ;; esac   # absolutise before cd
BOOT_TIMEOUT=${2:-360}
J=${J:-16}
cd "$WT" || exit 9
if [ ! -f "$KB/.config" ]; then
  echo "=== configure (first run) $(date +%H:%M:%S) ==="
  mkdir -p "$KB"
  make ARCH=arm64 O="$KB" defconfig >/dev/null 2>&1 || { echo DEFCONFIG-FAIL; exit 4; }
  scripts/config --file "$KB/.config" --set-val PAGE_MMUSHIFT 4 \
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
grep -E 'cow: (PASS|FAIL)|Run /init as init' "$LOG" 2>/dev/null | tail -2
