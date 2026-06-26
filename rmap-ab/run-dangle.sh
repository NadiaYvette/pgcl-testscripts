#!/bin/bash
# #143 QEMU dangling-PTE probe: full repro under TCG with the freed-frame shadow.
# A "PGCL143dangle" line = a present USER PTE walked to a kernel-freed frame =
# the dangling PTE, caught at USE-time with gva/rip/cr3 (which process + IP).
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
N=${N:-3}
echo "=== [#143 dangle-probe] tcg thread=multi smp8 m2G full-repro x$N $(date +%T) ==="
for r in $(seq 1 "$N"); do
  L=$D/dangle-$r.log
  PGCL_DANGLE=1 bash "$D/iso" timeout 900 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  dg=$(grep -ac 'PGCL143dangle' "$L"); ki=$(grep -ac 'Attempted to kill init' "$L"); act=$(grep -ac 'probe ACTIVE' "$L")
  echo "dangle-$r: dangle=$dg killinit=$ki probe_active=$act $(date +%T)"
done
echo "=== first dangling-PTE catches (gva/rip/cr3 -> the process+IP using a freed mapping) ==="
grep -hE 'PGCL143dangle' $D/dangle-*.log 2>/dev/null | sed -E 's/^.*(PGCL143dangle)/\1/' | head -24
