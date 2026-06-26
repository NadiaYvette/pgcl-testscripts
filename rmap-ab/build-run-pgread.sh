#!/bin/bash
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
echo "=== rebuild qemu (struct-page reader) $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-pgread-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 $P/qemu-pgread-build.log; exit 1; fi
echo "qemu built $(date +%T)"
L=$D/pgread-p4.log
PGCL_DANGLE=1 bash "$D/iso" timeout 200 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
    -cpu max,la57=off -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
    -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
echo "=== struct-page reader self-test results ==="
grep -a 'PGCL143pgread' "$L" | head -14
echo "=== verdict ==="
echo "READER-OK lines: $(grep -ac 'READER-OK' "$L")  READ-FAIL: $(grep -ac 'READ-FAIL' "$L")  UNEXPECTED: $(grep -ac 'UNEXPECTED' "$L")"
