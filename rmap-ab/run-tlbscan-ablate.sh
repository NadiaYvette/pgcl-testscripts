#!/bin/bash
# Narrow #143 free-while-mapped: which op is required? TLB-scan catches deterministically.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
run1() {
  local arm="$1"; local tok="$2"; local r="$3"; local L="$D/tsa-$arm-$r.log"
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 500 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1 $tok" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local ts; ts=$(grep -ac 'PGCL143tlbscan' "$L"); local ki; ki=$(grep -ac 'Attempted to kill init' "$L")
  local rw; rw=$(grep -hoE 'writable=[01]' "$L" | sort | uniq -c | tr '\n' ' ')
  echo "tsa-$arm-$r: catches=$ts killinit=$ki [$rw] $(date +%T)"
}
for a in "full:" "nofork:rr_nofork" "nocow:rr_nocow" "nohog:rr_nohog" "nofadv:rr_nofadv"; do
  arm=${a%%:*}; tok=${a#*:}
  echo "### ARM $arm (tok='$tok')"
  run1 "$arm" "$tok" 1; run1 "$arm" "$tok" 2
done
echo "=== which arm ELIMINATES catches => that op is required for the free-while-mapped ==="
