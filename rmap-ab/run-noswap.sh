#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
echo "=== minimal repro, NO swap device (swap-quirk test) $(date +%H:%M:%S) ==="
for r in 1 2 3 4; do
  L=$D/noswap-$r.log
  bash "$D/iso" timeout 240 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 2G \
    -kernel "$D/bzImage-vanfix" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  boot=$(grep -ac 'INIT: ablation' "$L"); swon=$(grep -ac 'swapon.*continuing' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L"); oom=$(grep -ac 'Out of memory\|oom-kill\|Killed process' "$L")
  z=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c|segfault at 38c' "$L")
  echo "noswap-$r: boot=$boot swaponfail=$swon killinit=$ki oom=$oom zerojump=$z $(date +%H:%M:%S)"
done
echo "=== verdict: clean/OOM (no killinit zerojump) => SWAP-QUIRK confirmed $(date +%H:%M:%S) ==="
