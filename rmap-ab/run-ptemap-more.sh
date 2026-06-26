#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
for r in 3 4 5 6 7 8; do
  L=$D/pm-$r.log
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 500 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  echo "pm-$r: catches=$(grep -ac PGCL143tlbscan "$L") killinit=$(grep -ac 'kill init' "$L")"
done
echo "=== pte_maps_frame distribution (1=present-dangler / 0=stale-TLB) ==="
grep -hoE 'writable=[01] pte_maps_frame=[01]' $D/pm-*.log 2>/dev/null | sort | uniq -c
echo "=== samples ==="
grep -hE 'PGCL143tlbscan' $D/pm-*.log 2>/dev/null | head -10
