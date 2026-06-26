#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== build bzImage (restore-all-16 swap fix) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanswap3-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"; [ "$rc" = 0 ] || { tail -20 "$P/vanswap3-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanswap"
run() {  # $1=smp $2=tag
  local L=$D/sf3-$2.log
  bash "$D/iso" timeout 300 qemu-system-x86_64 -enable-kvm -cpu host -smp "$1" -m 2G -kernel "$D/bzImage-vanswap" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local dn=$(grep -ac 'RRABL DONE' "$L"); local ki=$(grep -ac 'Attempted to kill init' "$L")
  local zj=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c' "$L")
  local sw=$(grep -acE 'swap_map|Bad swap|VM_BUG_ON|Bad page|list_del|refcount_t:' "$L")
  echo "sf3-$2(smp$1): DONE=$dn killinit=$ki zerojump=$zj swapwarn=$sw => $([ "$ki" -gt 0 -o "$zj" -gt 0 ] && echo CORRUPT || ([ "$dn" -gt 0 ] && echo CLEAN-DONE || echo timeout)) $(date +%H:%M:%S)"
}
echo "=== validate: want CLEAN-DONE (correct + fast) $(date +%H:%M:%S) ==="
run 4 a; run 4 b; run 8 c; run 8 d
echo "=== swap warnings (should be none) ==="
grep -haE 'swap_map|Bad swap|VM_BUG_ON|Bad page|list_del|refcount_t:' $D/sf3-*.log 2>/dev/null | grep -av 'Command line' | sed -E 's/^.*kernel: //' | sort | uniq -c | head
