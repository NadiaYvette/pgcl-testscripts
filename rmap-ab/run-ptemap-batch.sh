#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
for r in $(seq 9 20); do
  L=$D/pm-$r.log
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 480 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  echo "pm-$r: catches=$(grep -ac PGCL143tlbscan "$L") killinit=$(grep -ac 'kill init' "$L")"
done
echo "=== ALL pte_maps_frame distribution ==="
grep -hoE 'writable=[01] pte_maps_frame=[01]' $D/pm-*.log 2>/dev/null | sort | uniq -c
echo "=== HIGH-mmap (0x7...) file catches specifically ==="
grep -hE 'PGCL143tlbscan.*va=0x7' $D/pm-*.log 2>/dev/null | sed -E 's/^.*(PGCL143tlbscan)/\1/' | head -12
