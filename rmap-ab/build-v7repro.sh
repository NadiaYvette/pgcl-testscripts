#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
ST=$D/abl-initramfs/stage; A=$D/abl-initramfs
Q=/home/nyc/src/qemu/build/qemu-system-x86_64
echo "=== compile v3 repro (read-verify shared clean file pages) $(date +%T) ==="
gcc -O2 -static -o "$ST/repro" "$P/userspace/file_reclaim_race_repro_v7.c"
rc=$?; if [ "$rc" != 0 ]; then echo "COMPILE-FAIL rc=$rc"; exit 1; fi
cp "$ST/repro" "$A/repro"
( cd "$ST" && find . | cpio -o -H newc 2>/dev/null | gzip > "$A/initramfs.cpio.gz" )
echo "initramfs $(du -h "$A/initramfs.cpio.gz" | cut -f1)"
runone() {  # $1=tag $2=bzImage
    local tag=$1 bz=$2 L=$D/v7val-$1.log
    bash "$D/iso" timeout 360 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$bz" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    echo "$tag: DONE=$(grep -aoE 'RRABL DONE corruption=[0-9]+' "$L" | tail -1) killinit=$(grep -ac 'kill init' "$L") anon_corrupt=$(grep -aoE 'anon_corrupt=[0-9]+' "$L" | awk -F= '{s+=$2}END{print s+0}') workers=$(grep -ac 'RRABL worker' "$L")"
}
echo "=== pgcl4 (expect anon_corrupt>0) ==="
runone p4a "$D/bzImage-vandangle"; runone p4b "$D/bzImage-vandangle"
echo "=== pgcl0 (expect 0) ==="
runone p0a "$D/bzImage-pgcl0ctl"; runone p0b "$D/bzImage-pgcl0ctl"
