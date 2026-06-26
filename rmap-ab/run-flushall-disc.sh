#!/bin/bash
# #143 DECISIVE discriminator: does forcing the reclaim batch TLB flush to cover
# ALL cpus (pgcl143_flushall) eliminate the kill-init corruption?
#   kill-init -> 0  => (a) flush-coverage gap (active cpu running mm not flushed)
#   kill-init persists => (b) rmap refcount/mapcount underflow (page freed while
#                          still mapped); TLB staleness is secondary.
# Same bzImage both arms (cmdline-gated). Reliable signal = "kill init" rate.
set -u
SRC=/home/nyc/src/linux
O4=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64
echo "=== build pgcl4 + flushall gate $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$O4" -j8 bzImage > /home/nyc/src/pgcl/pgcl4-flushall-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/pgcl4-flushall-build.log; exit 1; fi
cp "$O4/arch/x86/boot/bzImage" "$D/bzImage-flushall"; echo "built $(date +%T)"
BZ=$D/bzImage-flushall
runarm() {  # $1=tag  $2=extra-cmdline
    local tag=$1
    local extra=$2
    local r L
    for r in 1 2 3 4 5; do
        L=$D/fa-$tag-$r.log
        PGCL_TLBSCAN=1 bash "$D/iso" timeout 520 "$Q" -accel tcg,thread=multi \
            -cpu max -smp 8 -m 2G -kernel "$BZ" \
            -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
            -append "console=ttyS0 nokaslr ignore_loglevel panic=1 $extra" \
            -drive file="$D/btrfs.img",format=raw,if=virtio \
            -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
            -nographic -no-reboot > "$L" 2>&1
        echo "fa-$tag-$r: killinit=$(grep -ac 'kill init' "$L") FREE=$(grep -ac FREE-WHILE "$L") ALLOC=$(grep -ac INTO-STALE "$L") ip0=$(grep -ac 'ip 0000000000000000' "$L") done=$(grep -ac 'RRABL DONE' "$L")"
    done
}
echo "=== ARM OFF (baseline, no flushall) — expect kill-init reliably ==="
runarm off ""
echo "=== ARM ON (pgcl143_flushall) — does it eliminate kill-init? ==="
runarm on "pgcl143_flushall"
echo "=== VERDICT ==="
echo "off killinit-runs: $(grep -l 'kill init' $D/fa-off-*.log 2>/dev/null | wc -l)/5"
echo "on  killinit-runs: $(grep -l 'kill init' $D/fa-on-*.log 2>/dev/null | wc -l)/5"
echo "  on=0 => (a) FLUSH-COVERAGE gap confirmed (+ workaround). on>0 => (b) rmap accounting; TLB secondary."
