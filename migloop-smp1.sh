#!/bin/bash
# SMP=1 + ignore_loglevel: capture the RTRC pr_info trace (KERN_INFO is otherwise
# filtered) for the large-folio mapcount misdistribution. Reuses the built Image.
set -u
KB=/home/nyc/src/pgcl/kernel-build-fast/aarch64
IMG=$KB/arch/arm64/boot/Image
STD=${INITRD:-/home/nyc/src/pgcl/userspace/initramfs/initramfs-aarch64.cpio.gz}
OUT=/home/nyc/src/pgcl/ca-out
N=${1:-8}
TMO=${2:-200}
for i in $(seq 1 "$N"); do
  L="$OUT/smp1ll_$i.log"
  timeout "$TMO" qemu-system-aarch64 -M virt -cpu cortex-a53 -m 8G -smp 1 \
    -nographic -no-reboot -kernel "$IMG" -initrd "$STD" \
    -append "console=ttyAMA0 panic=1 autotest=1 page_owner=on ignore_loglevel" >"$L" 2>&1
  mk=$(grep -ciE 'Bad page state|bad_page|nonzero (map|ref)count|VM_BUG|still mapped|kernel BUG' "$L")
  rmun=$(grep -c 'remove-on-unmapped' "$L")
  rtrc=$(grep -c RTRC "$L")
  cow=$(grep -oE 'cow: (PASS|FAIL)' "$L" | tail -1)
  echo "smp1ll run $i: markers=$mk  remove-on-unmapped=$rmun  RTRC=$rtrc  $cow"
done
echo "=== smp1ll loop done ==="
