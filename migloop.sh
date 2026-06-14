#!/bin/bash
# Reuse the already-built probe kernel; boot the standard initramfs N times,
# capturing per-run marker count + which PGCLDBG probe fires. No rebuild.
set -u
KB=/home/nyc/src/pgcl/kernel-build-fast/aarch64
IMG=$KB/arch/arm64/boot/Image
STD=${INITRD:-/home/nyc/src/pgcl/userspace/initramfs/initramfs-aarch64.cpio.gz}
OUT=/home/nyc/src/pgcl/ca-out
N=${1:-5}
TMO=${2:-200}
for i in $(seq 1 "$N"); do
  L="$OUT/migloop_$i.log"
  timeout "$TMO" qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 4 \
    -nographic -no-reboot -kernel "$IMG" -initrd "$STD" \
    -append "console=ttyAMA0 panic=1 autotest=1 page_owner=on" >"$L" 2>&1
  mk=$(grep -ciE 'Bad page state|bad_page|nonzero (map|ref)count|VM_BUG|still mapped|kernel BUG' "$L")
  readd=$(grep -c 'migration re-add same kpage' "$L")
  rmun=$(grep -c 'remove-on-unmapped' "$L")
  cow=$(grep -oE 'cow: (PASS|FAIL)' "$L" | tail -1)
  echo "run $i: markers=$mk  mig-readd=$readd  remove-on-unmapped=$rmun  $cow"
done
echo "=== loop done ==="
