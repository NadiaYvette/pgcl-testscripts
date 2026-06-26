#!/bin/bash
set -u
echo "=== build qemu (TLB-scan + free-path stack dump) $(date +%T) ==="
cd /home/nyc/src/qemu
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-fp-build.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then echo "BUILD-FAIL rc=$rc"; tail -25 /home/nyc/src/pgcl/qemu-fp-build.log; exit 1; fi
echo "qemu OK $(date +%T)"
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
Q=/home/nyc/src/qemu/build/qemu-system-x86_64; BZ=$D/bzImage-vandangle
for r in 1 2; do
  L=$D/fp-$r.log
  PGCL_TLBSCAN=1 bash "$D/iso" timeout 500 "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  fp=$(grep -ac 'PGCL143freepath' "$L"); ts=$(grep -ac 'PGCL143tlbscan' "$L")
  echo "fp-$r: tlbscan=$ts freepath_dumps=$fp $(date +%T)"
done
echo "=== FREE PATH (kernel functions that freed the still-mapped folio) ==="
VM=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug/vmlinux
addrs=$(grep -hoE 'ffffffff[0-9a-f]{8,}' $D/fp-*.log 2>/dev/null | sort -u | head -60)
nm -n "$VM" > /tmp/nmsyms.txt 2>/dev/null
for a in $addrs; do
  sym=$(awk -v t="0x$a" 'BEGIN{ti=strtonum(t)} {ai=strtonum("0x"$1); if(ai<=ti){s=$3; sa=ai} else {exit}} END{printf "%s+0x%x", s, ti-sa}' /tmp/nmsyms.txt)
  echo "  $a  $sym"
done