#!/bin/bash
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
echo "=== rebuild qemu (underflow scanner) $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-uf-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 $P/qemu-uf-build.log; exit 1; fi
echo "qemu built $(date +%T)"
run() {
    local tag=$1
    local bz=$2
    local L=$D/uf-$tag.log
    PGCL_DANGLE=1 bash "$D/iso" timeout 420 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$bz" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    echo "$tag: underflow=$(grep -ac PGCL143underflow "$L") readerok=$(grep -ac READER-OK "$L") killinit=$(grep -ac 'kill init' "$L")"
}
echo "=== pgcl4 (expect underflow hits if refcount/mapcount goes negative) ==="
run p4a "$D/bzImage-vandangle"; run p4b "$D/bzImage-vandangle"; run p4c "$D/bzImage-vandangle"
echo "=== pgcl0 control (expect 0 underflow) ==="
run p0a "$D/bzImage-pgcl0ctl"
echo "=== underflow catches + trajectories ==="
grep -ah 'PGCL143underflow' uf-p4*.log 2>/dev/null | head -12
