#!/bin/bash
# #143 QEMU repro WITH diagnostics: boot the instrumented pgcl4van kernel
# (catch-time VMA-namer) under the proven mem2G/smp8 reclaim-pressure repro
# (Fedora+systemd+SELinux boot under tight RAM = 8/8 corrupt on the guard
# kernel).  Captures the PGCL143wp catch + the `file=` mapping that accumulated
# each dangling PTE -- the same data the laptop would give, runnable here.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-van
MEM=${MEM:-2G}; N=${N:-6}; tag=van${MEM}
echo "=== [$tag] bzImage-van x$N smp8 (2x oversub on 16-19) start $(date +%H:%M:%S) ==="
hit=0
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
  [ "$wp" -gt 0 ] && hit=$((hit+1))
  echo "$tag-$r: PGCL143wp=$wp native_sig=$sig => $([ "$wp" -gt 0 ] && echo CAUGHT || echo none) $(date +%H:%M:%S)"
done
echo "=== [$tag]: $hit/$N runs caught a VMA-namer hit $(date +%H:%M:%S) ==="
echo "=== the prize: file= mappings across all runs (which mapping leaks danglers) ==="
grep -hoE 'file=\S+' $D/$tag-*.log 2>/dev/null | sort | uniq -c | sort -rn | head -30
echo "=== remover comm + flags ==="
grep -hoE 'remover comm=\S+ pid=[0-9]+ \S+-mm .* flags=0x[0-9a-f]+' $D/$tag-*.log 2>/dev/null \
  | sed -E 's/pid=[0-9]+/pid=N/; s/vma=0x[0-9a-f]+/vma=X/; s/pgoff=0x[0-9a-f]+//' | sort | uniq -c | sort -rn | head -20
