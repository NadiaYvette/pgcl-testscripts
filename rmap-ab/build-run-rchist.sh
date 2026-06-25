#!/bin/bash
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
echo "=== rebuild qemu (refcount/mapcount write-history) $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-rchist-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 $P/qemu-rchist-build.log; exit 1; fi
echo "qemu built $(date +%T)"
run() {
    local tag=$1
    local L=$D/rch-$tag.log
    PGCL_DANGLE=1 PGCL_RCHIST=1 bash "$D/iso" timeout 420 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    echo "$tag: rchist=$(grep -ac PGCL143rchist "$L") persunder=$(grep -ac PGCL143PERSUNDER "$L") readerok=$(grep -ac READER-OK "$L") killinit=$(grep -ac 'kill init' "$L")"
}
N="${1:-4}"
for i in $(seq 1 "$N"); do run "p4$i"; done
echo "=== *** PERSUNDER CLASSIFICATION (BUG vs Contract-A-anon FP) *** ==="
grep -ah 'PGCL143PERSUNDER' $D/rch-p4*.log 2>/dev/null | sort | uniq -c | sort -rn | head -40
echo "--- tallies of the two verdicts across all runs ---"
echo "  BUG?  : $(grep -ach 'PER-SUBPTE-UNDERCOUNT' $D/rch-p4*.log | paste -sd+ | bc 2>/dev/null)"
echo "  FP    : $(grep -ach 'contract-A-anon' $D/rch-p4*.log | paste -sd+ | bc 2>/dev/null)"
echo "=== INVARIANT VIOLATIONS (rc<=mc while mapped = freed/lost ref) across runs ==="
grep -aho '\[[^]]*![^]]*\]' $D/rch-p4*.log 2>/dev/null | sort | uniq -c | sort -rn | head -40
echo "=== histories CONTAINING a violation (full context) ==="
grep -a 'PGCL143rchist' $D/rch-p4*.log 2>/dev/null | grep -a '!' | head -20
echo "=== sample normal write-histories ==="
grep -a 'PGCL143rchist' $D/rch-p41.log 2>/dev/null | head -6
