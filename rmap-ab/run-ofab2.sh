#!/bin/bash
# #143 over-flush A/B (CLEAN): A=over-flush OFF (env unset), B=ON. Same script/conds.
# If B crashes ~same as A => over-flush no effect => incomplete-flush stale-TLB REFUTED.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vanswap
run1() {
  local tag="$1"; local mode="$2"; local r="$3"; local L="$D/ofab2-$tag-$r.log"
  if [ "$mode" = on ]; then
    PGCL_OVERFLUSH=1 bash "$D/iso" timeout 700 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
      -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
      -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
      -nographic -no-reboot > "$L" 2>&1
  else
    env -u PGCL_OVERFLUSH bash "$D/iso" timeout 700 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
      -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
      -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
      -nographic -no-reboot > "$L" 2>&1
  fi
  local ki; ki=$(grep -ac 'Attempted to kill init' "$L"); local act; act=$(grep -ac 'over-flush ACTIVE' "$L")
  local gt; gt=$(grep -aoE '^\[ *[0-9]+\.' "$L" | tail -1 | tr -dc '0-9.')
  echo "ofab2-$tag-$r: killinit=$ki overflush=$act last_guest_t=${gt:-?} $(date +%T)"
}
echo "=== ARM A: over-flush OFF (true baseline) ==="
for r in 1 2 3 4; do run1 A off "$r"; done
echo "=== ARM B: over-flush ON ==="
for r in 1 2 3 4; do run1 B on "$r"; done
ac=$(grep -lae 'Attempted to kill init' $D/ofab2-A-*.log 2>/dev/null | wc -l)
bcr=$(grep -lae 'Attempted to kill init' $D/ofab2-B-*.log 2>/dev/null | wc -l)
echo "=== VERDICT: OFF crashes=$ac/4 ; ON crashes=$bcr/4  (ON<<OFF => stale-TLB; ON~=OFF => refuted) ==="
