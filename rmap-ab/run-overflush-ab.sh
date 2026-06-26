#!/bin/bash
# #143 Angle D: does forcing full TLB flushes (PGCL_OVERFLUSH) stop the crash?
# A=baseline B=overflush. If A crashes + B runs clean/DONE => stale-TLB confirmed.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vanswap
run1() {
  local tag="$1"; local of="$2"; local r="$3"; local to="$4"
  local L="$D/ofab-$tag-$r.log"
  PGCL_OVERFLUSH="$of" bash "$D/iso" timeout "$to" "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local ki; ki=$(grep -ac 'Attempted to kill init' "$L")
  local done_; done_=$(grep -ac 'RRABL DONE' "$L")
  local act; act=$(grep -ac 'over-flush ACTIVE' "$L")
  local gt; gt=$(grep -aoE '^\[ *[0-9]+\.' "$L" | tail -1 | tr -dc '0-9.')
  echo "ofab-$tag-$r: killinit=$ki rrabl_done=$done_ overflush=$act last_guest_t=${gt:-?} $(date +%T)"
}
echo "=== ARM A: baseline (no overflush), timeout 700 ==="
for r in 1 2 3 4; do run1 A "" "$r" 700; done
echo "=== ARM B: PGCL_OVERFLUSH=1 (force full flushes), timeout 1400 ==="
for r in 1 2 3 4; do run1 B 1 "$r" 1400; done
echo "=== VERDICT ==="
ac=$(grep -lae 'Attempted to kill init' $D/ofab-A-*.log 2>/dev/null | wc -l)
bcr=$(grep -lae 'Attempted to kill init' $D/ofab-B-*.log 2>/dev/null | wc -l)
bd=$(grep -lae 'RRABL DONE' $D/ofab-B-*.log 2>/dev/null | wc -l)
echo "baseline(A) crashes=$ac/4 ; overflush(B) crashes=$bcr/4 done=$bd/4"
echo "=> if A>0 and B==0 (esp. B done>0): STALE-TLB CONFIRMED"
