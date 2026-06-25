#!/bin/bash
# build-run-pm.sh [N] — pgcl4 runs; on a crash the guest dump_page() fires magic
# cpuid 0x51430004 -> QEMU pgcl_postmortem_walk prints every (cr3,va) still
# mapping the dumped/freed cluster = the dangling/stale PTE (the #143 bug).
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-6}"
for i in $(seq 1 "$N"); do
    L=$D/rch-pm-p4$i.log
    PGCL_DANGLE=1 bash "$D/iso" timeout 360 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    ki=$(grep -ac 'kill init\|segfault at 0 ip 0000000000000000' "$L")
    pm=$(grep -ac 'PGCL143PM ' "$L")
    pmw=$(grep -ac 'PGCL143PM-walk' "$L")
    echo "p4$i: killinit=$ki PM-walks=$pmw PM-dangling-PTEs=$pm"
done
echo "=== *** DANGLING PTEs found at crash (the bug, with cr3/va/sub) *** ==="
grep -ah 'PGCL143PM ' $D/rch-pm-p4*.log 2>/dev/null | sort | uniq -c | sort -rn | head -40
echo "=== PM-walk summaries (total present USER PTEs on the freed cluster) ==="
grep -ah 'PGCL143PM-walk cl=' $D/rch-pm-p4*.log 2>/dev/null | grep -av 'total_present_USER_PTEs=0 ' | head -20