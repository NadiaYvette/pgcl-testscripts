#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== rebuild bzImage (swap fix + prefetch disabled) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanswap2-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"; [ "$rc" = 0 ] || { tail -20 "$P/vanswap2-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanswap"
run() {  # $1=smp $2=tag
  local L=$D/sf2-$2.log
  bash "$D/iso" timeout 400 qemu-system-x86_64 -enable-kvm -cpu host -smp "$1" -m 2G -kernel "$D/bzImage-vanswap" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local dn=$(grep -ac 'RRABL DONE' "$L"); local ki=$(grep -ac 'Attempted to kill init' "$L")
  local zj=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c' "$L"); local cs=$(grep -ac 'clocksource: Watchdog' "$L")
  echo "sf2-$2(smp$1): DONE=$dn killinit=$ki zerojump=$zj clksrcwarn=$cs => $([ "$ki" -gt 0 ] && echo CRASH || ([ "$dn" -gt 0 ] && echo CLEAN-DONE || echo timeout)) $(date +%H:%M:%S)"
}
echo "=== validate (was: thrash-timeout; want CLEAN-DONE) $(date +%H:%M:%S) ==="
run 4 a; run 4 b; run 8 c; run 8 d
