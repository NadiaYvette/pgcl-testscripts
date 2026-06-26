#!/bin/bash
# build-run-hist.sh [N] [GiB] — N pgcl4 runs with the deep-history ring; keep the
# dump only from runs where the bug fires (kill init), so the offline analyzer
# can rewind the premature free to its causal op.  Cheap append => low perturb.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-6}"; GB="${2:-8}"
echo "=== rebuild qemu $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-hist-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "BUILD-FAIL"; tail -20 $P/qemu-hist-build.log; exit 1; fi
echo "built $(date +%T)"
kept=""
for i in $(seq 1 "$N"); do
    L=$D/rch-hist-p4$i.log
    HF=$D/pgcl-hist-p4$i.bin
    rm -f "$HF"
    PGCL_DANGLE=1 PGCL_RCHIST=1 PGCL_HISTGB="$GB" PGCL_HISTFILE="$HF" \
      bash "$D/iso" timeout 360 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1 pgcl143_setlog" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    ki=$(grep -ac 'kill init\|segfault at 0 ip 0000000000000000' "$L")
    ev=$(grep -a 'PGCL143hist: dumped' "$L" | grep -ao 'dumped [0-9]*' | head -1)
    echo "p4$i: killinit=$ki  $ev  dump=$(ls -la "$HF" 2>/dev/null | awk '{print $5}')"
    if [ "$ki" -gt 0 ]; then kept="$kept p4$i"; else rm -f "$HF"; fi
done
echo "=== runs with bug (kept dumps): ${kept:-NONE} ==="