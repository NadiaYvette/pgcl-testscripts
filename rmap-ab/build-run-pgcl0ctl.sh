#!/bin/bash
set -u
SRC=/home/nyc/src/linux
O4=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
O0=/home/nyc/src/pgcl/kernel-rpm-build/pgcl0-debug
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
echo "=== configure PGCL=0 control $(date +%T) ==="
mkdir -p "$O0"
cp "$O4/.config" "$O0/.config"
"$SRC/scripts/config" --file "$O0/.config" --set-val CONFIG_PAGE_MMUSHIFT 0
make -C "$SRC" O="$O0" olddefconfig > /home/nyc/src/pgcl/pgcl0-cfg.log 2>&1
grep -E 'CONFIG_PAGE_MMUSHIFT' "$O0/.config"
echo "=== build PGCL=0 bzImage $(date +%T) ==="
taskset -c 12-19 make -C "$SRC" O="$O0" -j8 bzImage > /home/nyc/src/pgcl/pgcl0-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -20 /home/nyc/src/pgcl/pgcl0-build.log; exit 1; fi
cp "$O0/arch/x86/boot/bzImage" "$D/bzImage-pgcl0ctl"; echo "PGCL=0 built $(date +%T)"
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-pgcl0ctl
echo "=== CONTROL: same repro + TLB-scan on PGCL=0 ==="
for r in 1 2 3 4 5 6; do
  L=$D/p0-$r.log
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 480 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  echo "p0-$r: catches=$(grep -ac PGCL143tlbscan "$L") killinit=$(grep -ac 'kill init' "$L") active=$(grep -ac 'TLB-scan catcher ACTIVE' "$L")"
done
echo "=== VERDICT: PGCL=0 catching-runs=$(grep -lE 'PGCL143tlbscan' $D/p0-*.log 2>/dev/null | wc -l)/6 ==="
echo "  (0 => stale-TLB is PGCL-SPECIFIC = REAL bug ; >0 => QEMU TCG SMP-flush artifact)"
