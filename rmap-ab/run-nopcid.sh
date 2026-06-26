#!/bin/bash
# nopcid A/B: if nopcid kills the TLB-scan catches => PCID+lazy-TLB stale confirmed.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
run1() {
  local tag="$1"; local extra="$2"; local r="$3"
  local L="$D/npc-$tag-$r.log"
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 480 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1 $extra" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  echo "npc-$tag-$r: catches=$(grep -ac PGCL143tlbscan "$L") killinit=$(grep -ac 'kill init' "$L")"
}
echo "=== ARM A: nopcid ==="; for r in 1 2 3 4 5 6; do run1 A nopcid "$r"; done
echo "=== ARM B: baseline (pcid) ==="; for r in 1 2 3 4 5 6; do run1 B "" "$r"; done
ac=$(grep -lE 'PGCL143tlbscan' $D/npc-A-*.log 2>/dev/null | wc -l)
bc1=$(grep -lE 'PGCL143tlbscan' $D/npc-B-*.log 2>/dev/null | wc -l)
echo "=== VERDICT: nopcid catching-runs=$ac/6 ; pcid catching-runs=$bc1/6 (nopcid 0 + pcid >0 => PCID stale CONFIRMED) ==="
