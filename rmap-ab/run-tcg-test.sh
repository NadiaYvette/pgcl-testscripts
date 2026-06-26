#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; A=$D/abl-initramfs
BZ=$D/bzImage-vanfix
echo "=== TCG-repro test (MTTCG smp8 m2G, minimal repro) $(date +%H:%M:%S) ==="
for r in 1 2 3; do
  L=$D/tcg-min-$r.log
  bash "$D/iso" timeout 600 qemu-system-x86_64 -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$A/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  ki=$(grep -ac 'Attempted to kill init' "$L")
  ran=$(grep -ac 'RRABL start' "$L"); done_=$(grep -ac 'RRABL DONE' "$L")
  boot=$(grep -ac 'INIT: ablation initramfs up' "$L")
  echo "tcg-min-$r: boot=$boot ran=$ran killinit=$ki done=$done_ => $([ "$ki" -gt 0 ] && echo CRASH || echo clean/timeout) $(date +%H:%M:%S)"
done
echo "=== TCG verdict $(date +%H:%M:%S) ==="
