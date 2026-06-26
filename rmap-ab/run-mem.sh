#!/bin/bash
# NO-BUILD memory-pressure A/B: boot the existing bzImage-guard at mode 0
# (pgcl143_guard=0 = clean/no-op) under varying -m to test whether #143's
# freed-while-mapped is RECLAIM-PRESSURE-driven (rate drops at high -m) or
# ZAP/exit/truncate-driven (rate unchanged).  Non-perturbing (RAM knob only).
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-guard
MEM=${MEM:-8G}; N=${N:-8}; tag=mem${MEM}
echo "=== [$tag] x$N smp8 start $(date +%H:%M:%S) ==="
corrupt=0
for r in $(seq 1 "$N"); do
  L=$D/$tag-$r.log
  bash "$D/iso" timeout 240 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0 pgcl143_guard=0" \
    -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  sig=$(grep -acE 'BUG: Bad page|Bad rss-counter|Attempted to kill init|kernel BUG at|VM_BUG_ON|refcount_t:' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L"); login=$(grep -acE 'login:|Welcome to' "$L")
  [ "$sig" -gt 0 ] && corrupt=$((corrupt+1))
  echo "$tag$r: sig=$sig killinit=$ki login=$login => $([ "$sig" -gt 0 ] && echo CORRUPT || echo clean) $(date +%H:%M:%S)"
done
echo "=== [$tag]: $corrupt/$N corrupt $(date +%H:%M:%S) ==="
