#!/bin/bash
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
echo "=== rebuild qemu (PTE-vs-structpage cross-check) $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-xcheck-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 $P/qemu-xcheck-build.log; exit 1; fi
echo "qemu built $(date +%T)"
run() {
    local tag=$1
    local bz=$2
    local L=$D/xck-$tag.log
    PGCL_DANGLE=1 bash "$D/iso" timeout 420 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$bz" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    echo "$tag: freed_mapped=$(grep -ac 'FREED-WHILE-MAPPED' "$L") undercount=$(grep -ac MAPCOUNT-UNDERCOUNT "$L") overcount=$(grep -ac MAPCOUNT-OVERCOUNT "$L")"; echo "   last-summary: $(grep -a PGCL143xck-summary "$L" | tail -1) readerok=$(grep -ac READER-OK "$L") killinit=$(grep -ac 'kill init' "$L")"
}
echo "=== pgcl4 (shift=4 valid) ==="; run p4a "$D/bzImage-vandangle"; run p4b "$D/bzImage-vandangle"
echo "(pgcl0 skipped: QEMU PGCL_MMUSHIFT hardcoded 4, invalid for the shift-0 kernel)"
echo "=== xcheck catches (pgcl4) ==="; grep -ahE 'UNDERCOUNT|FREED-WHILE' xck-p4*.log 2>/dev/null | head -16; echo '--- overcount sample ---'; grep -ah OVERCOUNT xck-p4*.log 2>/dev/null | head -4
echo "=== pgcl0 catches (should be ~0; any = churn FP baseline) ==="; grep -ah 'PGCL143xcheck' xck-p0*.log 2>/dev/null | head -6
