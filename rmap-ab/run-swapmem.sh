#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
run() {  # $1=mem $2=smp $3=tag
  local L=$D/sfmem-$3.log
  bash "$D/iso" timeout 300 qemu-system-x86_64 -enable-kvm -cpu host -smp "$2" -m "$1" -kernel "$D/bzImage-vanswap" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local dn=$(grep -ac 'RRABL DONE' "$L"); local ki=$(grep -ac 'Attempted to kill init' "$L")
  local zj=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c' "$L")
  echo "sfmem-$3(m$1 smp$2): DONE=$dn killinit=$ki zerojump=$zj => $([ "$ki" -gt 0 -o "$zj" -gt 0 ] && echo CORRUPT || ([ "$dn" -gt 0 ] && echo CLEAN-DONE || echo timeout)) $(date +%H:%M:%S)"
}
echo "=== swap fix at lower over-commit (confirm correct + completes) $(date +%H:%M:%S) ==="
run 4G 4 m4-a; run 4G 4 m4-b; run 6G 8 m6-c
