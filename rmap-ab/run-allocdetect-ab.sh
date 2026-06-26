#!/bin/bash
# #143 smoking-gun A/B: rebuild qemu with the on_alloc (ALLOC-INTO-STALE-MAPPED)
# detector, then run the repro+TLB-scan on pgcl4 (bzImage-vandangle) vs pgcl0
# (bzImage-pgcl0ctl).  ALLOC catches = a stale user-TLB entry survived
# free->realloc with no flush = the actual corruption window ("page-cache
# corruption").  FREE catches alone (esp. if also at pgcl0) = benign lazy-TLB.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64
echo "=== rebuild qemu (on_alloc detector) $(date +%T) ==="
taskset -c 12-19 ninja -C /home/nyc/src/qemu/build qemu-system-x86_64 \
    > /home/nyc/src/pgcl/qemu-alloc-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-alloc-build.log; exit 1; fi
echo "qemu built $(date +%T)"
run() {  # $1=tag  $2=bzImage
    local tag=$1
    local bz=$2
    local r L
    for r in 1 2 3 4; do
        L=$D/ad-$tag-$r.log
        PGCL_TLBSCAN=1 bash "$D/iso" timeout 520 "$Q" -accel tcg,thread=multi \
            -cpu max -smp 8 -m 2G -kernel "$bz" \
            -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
            -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
            -drive file="$D/btrfs.img",format=raw,if=virtio \
            -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
            -nographic -no-reboot > "$L" 2>&1
        echo "ad-$tag-$r: FREE=$(grep -ac 'FREE-WHILE-USER-MAPPED' "$L") ALLOC=$(grep -ac 'ALLOC-INTO-STALE-MAPPED' "$L") allocpath=$(grep -ac PGCL143allocpath "$L") done=$(grep -ac 'RRABL DONE' "$L") killinit=$(grep -ac 'kill init' "$L")"
    done
}
echo "=== PGCL=4 (bzImage-vandangle) ==="
run pgcl4 "$D/bzImage-vandangle"
echo "=== PGCL=0 (bzImage-pgcl0ctl) ==="
run pgcl0 "$D/bzImage-pgcl0ctl"
echo "=== SUMMARY ==="
p4a=$(grep -l 'ALLOC-INTO-STALE-MAPPED' $D/ad-pgcl4-*.log 2>/dev/null | wc -l)
p4f=$(grep -l 'FREE-WHILE-USER-MAPPED'  $D/ad-pgcl4-*.log 2>/dev/null | wc -l)
p0a=$(grep -l 'ALLOC-INTO-STALE-MAPPED' $D/ad-pgcl0-*.log 2>/dev/null | wc -l)
p0f=$(grep -l 'FREE-WHILE-USER-MAPPED'  $D/ad-pgcl0-*.log 2>/dev/null | wc -l)
echo "pgcl4: ALLOC-catching $p4a/4  FREE-catching $p4f/4"
echo "pgcl0: ALLOC-catching $p0a/4  FREE-catching $p0f/4"
echo "  ALLOC at pgcl4 only => #143 = REAL stale-TLB-reuse corruption (PGCL-specific)."
echo "  ALLOC at pgcl0 too  => mainline/TCG artifact; re-examine."
echo "  unique allocpath kernel addrs (who gets the corrupted page):"
grep -h -A40 PGCL143allocpath $D/ad-pgcl4-*.log 2>/dev/null | grep -oE 'ffffffff8[0-9a-f]+' | sort | uniq -c | sort -rn | head
