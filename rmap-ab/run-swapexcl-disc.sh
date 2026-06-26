#!/bin/bash
# #143 CONFIRM+FIX: does NOT trusting SWP_EXCLUSIVE on a shared swap slot
# (pgcl143_swapexcl_fix) eliminate the kill-init corruption?
#   "dropped false SWP_EXCLUSIVE" appears => the inconsistency (exclusive bit on
#       shared swap) genuinely occurs.
#   kill-init on=0 => CONFIRMED: exclusive-on-shared was the corruption; real fix
#       belongs at swap-out/fork (clear SWP_EXCLUSIVE when sharing).
#   kill-init on>0 (despite dropped firing) => not the sole cause.
set -u
SRC=/home/nyc/src/linux
O4=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64
echo "=== build pgcl4 + swapexcl gate $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$O4" -j8 bzImage > /home/nyc/src/pgcl/pgcl4-swapexcl-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/pgcl4-swapexcl-build.log; exit 1; fi
cp "$O4/arch/x86/boot/bzImage" "$D/bzImage-swapexcl"; echo "built $(date +%T)"
BZ=$D/bzImage-swapexcl
runarm() {  # $1=tag  $2=extra-cmdline
    local tag=$1
    local extra=$2
    local r L
    for r in 1 2 3 4 5; do
        L=$D/se-$tag-$r.log
        bash "$D/iso" timeout 520 "$Q" -accel tcg,thread=multi \
            -cpu max -smp 8 -m 2G -kernel "$BZ" \
            -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
            -append "console=ttyS0 nokaslr ignore_loglevel panic=1 $extra" \
            -drive file="$D/btrfs.img",format=raw,if=virtio \
            -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
            -nographic -no-reboot > "$L" 2>&1
        echo "se-$tag-$r: killinit=$(grep -ac 'kill init' "$L") ip0=$(grep -ac 'ip 0000000000000000' "$L") dropped=$(grep -ac 'dropped false SWP_EXCLUSIVE' "$L") done=$(grep -ac 'RRABL DONE' "$L") swapWARN=$(grep -ac 'check_swap_exclusive\|memory.c:53' "$L")"
    done
}
echo "=== ARM OFF (baseline, no guard) — expect kill-init reliably ==="
runarm off ""
echo "=== ARM ON (pgcl143_swapexcl_fix) — does it eliminate kill-init? ==="
runarm on "pgcl143_swapexcl_fix"
echo "=== VERDICT ==="
echo "off killinit-runs: $(grep -l 'kill init' $D/se-off-*.log 2>/dev/null | wc -l)/5"
echo "on  killinit-runs: $(grep -l 'kill init' $D/se-on-*.log 2>/dev/null | wc -l)/5"
echo "on  dropped-runs:  $(grep -l 'dropped false SWP_EXCLUSIVE' $D/se-on-*.log 2>/dev/null | wc -l)/5"
echo "  on killinit=0 + dropped>0 => CONFIRMED: exclusive-on-shared swap = #143 corruption."
