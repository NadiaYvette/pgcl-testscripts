#!/bin/bash
# #143 fork-tag: testbed @2G x N on bzImage-vanfork. The wp/badmap (manifestation A)
# dump now carries FORKTAG=1 iff the dangling PTE was fork-installed (_PAGE_SOFTW4).
# No panic=1 (let the non-fatal pr_err dumps land); many runs (A is QEMU-rare).
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-vanfork
MEM=${MEM:-2G}; N=${N:-16}
echo "=== [#143 fork-tag] bzImage-vanfork m$MEM smp8 x$N $(date +%H:%M:%S) ==="
for r in $(seq 1 "$N"); do
  L=$D/vf-$r.log
  bash "$D/iso" timeout 200 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr ignore_loglevel selinux=1 enforcing=0" \
    -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  fk=$(grep -ac 'PGCL143fork:' "$L"); ki=$(grep -ac 'Attempted to kill init' "$L"); bp=$(grep -ac 'Bad page map' "$L")
  echo "vf-$r: forkdump=$fk killinit=$ki badmap=$bp $(date +%H:%M:%S)"
done
echo "=== FORK-TAG VERDICT (did the dangling PTE come from fork?) ==="
grep -hoE 'PGCL143fork: dangling-remove[^ ]* FORKTAG=[01] anon=[01]' $D/vf-*.log 2>/dev/null \
  | sed -E 's/pgclblk//; s/dangling-remove\(\)/dangling-remove/' | sort | uniq -c | sort -rn
echo "--- raw fork dumps (first 20) ---"
grep -hE 'PGCL143fork:' $D/vf-*.log 2>/dev/null | sed -E 's/^.*kernel: //' | head -20
