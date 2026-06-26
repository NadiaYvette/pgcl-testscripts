#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
cd "$P/kernel-rpm-build/pgcl4"
echo "=== build bzImage (swap-quirk fix) $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanswap-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"; [ "$rc" = 0 ] || { tail -20 "$P/vanswap-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanswap"
echo "=== minimal repro WITH swap (was 6/6 crash); fix works iff clean+DONE $(date +%H:%M:%S) ==="
ok=0; crash=0
for r in 1 2 3 4 5 6; do
  L=$D/swapfix-$r.log
  bash "$D/iso" timeout 260 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 2G \
    -kernel "$D/bzImage-vanswap" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  done_=$(grep -ac 'RRABL DONE' "$L"); ki=$(grep -ac 'Attempted to kill init' "$L")
  zj=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c' "$L")
  swpwarn=$(grep -acE 'swap_map|Bad swap|VM_BUG_ON.*swap|Bad page|list_del corruption|refcount_t' "$L")
  [ "$done_" -gt 0 -a "$ki" = 0 ] && ok=$((ok+1)); [ "$ki" -gt 0 ] && crash=$((crash+1))
  echo "swapfix-$r: DONE=$done_ killinit=$ki zerojump=$zj swapwarn=$swpwarn => $([ "$ki" -gt 0 ] && echo CRASH || ([ "$done_" -gt 0 ] && echo CLEAN-DONE || echo timeout)) $(date +%H:%M:%S)"
done
echo "=== swapfix: clean=$ok crash=$crash /6 (FIX WORKS iff crash=0) $(date +%H:%M:%S) ==="
echo "=== any swap/accounting warnings? ==="
grep -haE 'swap_map|Bad swap|VM_BUG_ON|Bad page|list_del|refcount_t:' $D/swapfix-*.log 2>/dev/null | grep -av 'Command line' | sed -E 's/^.*kernel: //' | sort | uniq -c | head
