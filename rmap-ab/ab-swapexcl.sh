#!/bin/bash
# A/B: does suppressing the PGCL swap-in exclusive grant (pgcl143_swapexcl_fix)
# eliminate the #143 kill-init?  smp8 thread=multi (the original oracle), fresh
# qcow2 overlays per run so disk state can't confound.  baseline should crash,
# the fix should go 0/N -> confirms the exclusive grant is the corruption.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-4}"
for fix in base swapexclfix; do
  ap="console=ttyS0 nokaslr ignore_loglevel panic=1"
  [ "$fix" = swapexclfix ] && ap="$ap pgcl143_swapexcl_fix"
  ki=0
  for i in $(seq 1 "$N"); do
    rm -f "$D"/ab-b.qcow2 "$D"/ab-s.qcow2
    qemu-img create -f qcow2 -b "$D/btrfs.img"            -F raw "$D"/ab-b.qcow2 >/dev/null
    qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/ab-s.qcow2 >/dev/null
    L=$P/ab-$fix-$i.log
    taskset -c 8-15 timeout 360 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
      -cpu max,la57=off -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
      -initrd "$A/initramfs.cpio.gz" -append "$ap" \
      -drive file="$D"/ab-b.qcow2,if=virtio -drive file="$D"/ab-s.qcow2,if=virtio \
      -nographic -no-reboot > "$L" 2>&1
    k=$(grep -ac 'kill init\|segfault at 0 ip 0000000000000000' "$L")
    [ "$k" -gt 0 ] && ki=$((ki+1))
    echo "  $fix-$i: killinit=$k  reached=$(grep -aoE '^\[[ 0-9.]+\]' "$L" | tail -1)"
  done
  echo "=== $fix: $ki/$N runs crashed ==="
done
