#!/bin/bash
# GATE: does #143 (full repro, fork required) reproduce under TCG thread=multi?
# If yes -> the QEMU dangling-PTE probe is viable. If no -> TCG timing suppresses it.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vanswap
echo "=== [#143 TCG-repro gate] custom-qemu tcg,thread=multi smp8 m2G full-repro $(date +%H:%M:%S) ==="
for r in 1 2; do
  L=$D/tcgrepro-$r.log
  bash "$D/iso" timeout 700 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  ki=$(grep -ac 'Attempted to kill init' "$L"); rr=$(grep -ac 'RRABL start' "$L"); zj=$(grep -acE 'ip 0000000000000000|segfault at 0 ' "$L")
  echo "tcgrepro-$r: killinit=$ki ranrepro=$rr zerojump=$zj => $([ "$ki" -gt 0 ] && echo REPRODUCES-under-TCG || echo no-crash) $(date +%H:%M:%S)"
done
