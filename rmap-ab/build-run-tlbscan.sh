#!/bin/bash
set -u
echo "=== build qemu (TLB-scan catcher) $(date +%T) ==="
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-ts-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-ts-build.log; exit 1; fi
echo "qemu TLB-scan OK $(date +%T)"
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
for r in 1 2 3 4; do
  L=$D/ts-$r.log
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 700 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  ts=$(grep -ac 'PGCL143tlbscan' "$L"); ki=$(grep -ac 'Attempted to kill init' "$L"); act=$(grep -ac 'TLB-scan catcher ACTIVE' "$L")
  echo "ts-$r: tlbscan_catches=$ts killinit=$ki active=$act $(date +%T)"
done
echo "=== CATCHES (frame freed while a live USER TLB entry maps it = the use-after-free) ==="
grep -hE 'PGCL143tlbscan' $D/ts-*.log 2>/dev/null | head -24
