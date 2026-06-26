#!/bin/bash
# Build bzImage with the #143 TTU_SYNC fix (+ VMA-namer still in) and re-run the
# proven mem2G/smp8 repro.  Fix works iff PGCL143wp=0 AND no native signals.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== build bzImage (TTU_SYNC fix) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanfix-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { tail -25 "$P/vanfix-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanfix"
BZ="$D/bzImage-vanfix"; MEM=2G; N=10; tag=vanfix${MEM}
echo "=== [$tag] x$N smp8 (baseline van2G was 2/6 corrupt) $(date +%H:%M:%S) ==="
corrupt=0
for r in $(seq 1 "$N"); do
  L=$D/$tag-$r.log
  bash "$D/iso" timeout 240 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr ignore_loglevel selinux=1 enforcing=0" \
    -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  wp=$(grep -ac 'PGCL143wp #' "$L")
  sig=$(grep -acE 'BUG: Bad page|Bad rss-counter|Attempted to kill init|kernel BUG at|VM_BUG_ON' "$L")
  ok=$(grep -acE 'login:|RR DONE|Reached target' "$L")
  bad=$([ "$wp" -gt 0 -o "$sig" -gt 0 ] && echo 1 || echo 0)
  [ "$bad" = 1 ] && corrupt=$((corrupt+1))
  echo "$tag-$r: PGCL143wp=$wp native_sig=$sig workload_ran=$ok => $([ "$bad" = 1 ] && echo CORRUPT || echo CLEAN) $(date +%H:%M:%S)"
done
echo "=== [$tag]: $corrupt/$N corrupt (FIX WORKS iff 0) $(date +%H:%M:%S) ==="
