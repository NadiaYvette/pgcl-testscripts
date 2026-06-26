#!/bin/bash
# Race-catcher: boot bzImage-mmva (saved (mm,va) + per-pfn tracker, #61) at
# 3G smp8 = MAX reclaim exposure (the pressure curve says B peaks here) x N,
# capturing the #143 dangling-PTE / underflow / freed-while-mapped catches
# WITH attribution.  Goal: name the creating path of the count-clean dangling PTE.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-mmva
N=${N:-16}
echo "=== [mmva] race-catcher x$N @ -m 3G smp8 start $(date +%H:%M:%S) ==="
caught=0
for r in $(seq 1 "$N"); do
  L=$D/mmva-$r.log
  bash "$D/iso" timeout 240 qemu-system-x86_64 \
    -enable-kvm -cpu host -smp 8 -m 3G -kernel "$BZ" \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0" \
    -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  c=$(grep -acE '#143|DANGLING|OVER-REMOVE|UNDER-REMOVE|VERDICT|pgcl_ev2|pgcl143|freed.*mapped|Bad page map|bad_page' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L")
  [ "$c" -gt 0 ] && caught=$((caught+1))
  echo "mmva$r: catches=$c killinit=$ki => $([ "$c" -gt 0 ] && echo CAUGHT || echo -) $(date +%H:%M:%S)"
done
echo "=== [mmva] done: $caught/$N caught $(date +%H:%M:%S) ==="
