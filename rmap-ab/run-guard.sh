#!/bin/bash
# Folio-guard A/B + PLACEBO in ONE kernel, selected by core_param pgcl143_guard:
#   0 = off (baseline / sanity: must reproduce like the control)
#   1 = GUARD  : folio-hashed spinlock held across the file rmap count+PTE step
#                on BOTH install (set_pte_range) and teardown (zap) -> serializes
#                same-folio operations ACROSS mms (tests the cross-mm hypothesis)
#   2 = PLACEBO: a per-CPU spinlock around the SAME regions -> identical
#                lock/unlock cost, but NEVER serializes cross-mm (control for
#                perturbation-masquerade).
# Verdict: GUARD clean + PLACEBO still corrupt => REAL serialization fix.
#          Both clean => it was just added latency (perturbation), not a fix.
#          Neither clean => not a cross-mm count+PTE serialization issue.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
P=/home/nyc/src/pgcl
BZ=$D/bzImage-guard
N=${N:-8}
echo "=== [guard] BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -4
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"
names=(off guard placebo)
for MODE in 0 1 2; do
  tag="g${MODE}-${names[$MODE]}"
  echo "=== mode $MODE (${names[$MODE]}) x$N start $(date +%H:%M:%S) ==="
  corrupt=0
  for r in $(seq 1 "$N"); do
    L=$D/$tag-$r.log
    bash "$D/iso" timeout 220 qemu-system-x86_64 \
      -enable-kvm -cpu host -smp 8 -m 3G -kernel "$BZ" \
      -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0 pgcl143_guard=$MODE" \
      -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
      -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
      -drive file="$D/btrfs.img",format=raw,if=virtio \
      -nographic -no-reboot > "$L" 2>&1
    sig=$(grep -acE 'BUG: Bad page|Bad rss-counter|Attempted to kill init|kernel BUG at|VM_BUG_ON|refcount_t:' "$L")
    login=$(grep -acE 'login:|Welcome to' "$L")
    [ "$sig" -gt 0 ] && corrupt=$((corrupt+1))
    echo "$tag$r: sig=$sig login=$login => $([ "$sig" -gt 0 ] && echo CORRUPT || echo clean) $(date +%H:%M:%S)"
  done
  echo "=== mode $MODE (${names[$MODE]}): $corrupt/$N corrupt ==="
done
echo "=== guard A/B/placebo done $(date +%H:%M:%S) ==="
