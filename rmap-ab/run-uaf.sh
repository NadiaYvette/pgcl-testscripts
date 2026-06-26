#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; SRC=/home/nyc/src/linux
cd "$P/kernel-rpm-build/pgcl4"
echo "=== enable DEBUG_KERNEL + DEBUG_PAGEALLOC + PAGE_POISONING (via source scripts/config) $(date +%H:%M:%S) ==="
"$SRC/scripts/config" --file .config -e DEBUG_KERNEL -e DEBUG_PAGEALLOC -e PAGE_POISONING
taskset -c 12-19 make -j8 olddefconfig >/dev/null 2>&1
echo "VERIFY:"; grep -E 'CONFIG_DEBUG_PAGEALLOC=|CONFIG_PAGE_POISONING=' .config || echo "  !! configs DID NOT stick"
echo "=== build bzImage-vanuaf $(date +%H:%M:%S) ==="
taskset -c 12-19 make -j8 bzImage > "$P/vanuaf-build.log" 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"; [ "$rc" = 0 ] || { tail -20 "$P/vanuaf-build.log"; exit 1; }
cp arch/x86/boot/bzImage "$D/bzImage-vanuaf"
echo "=== run minimal under KVM, detectors armed $(date +%H:%M:%S) ==="
for r in 1 2 3 4; do
  L=$D/uaf2-$r.log
  bash "$D/iso" timeout 240 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 2G \
    -kernel "$D/bzImage-vanuaf" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 debug_pagealloc=on page_poison=1 slub_debug=FZPU rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  boot=$(grep -ac 'INIT: ablation' "$L")
  uaf=$(grep -acE 'unable to handle (kernel )?(paging|page) (request|fault)|page_poison.*corrupt|Bad page state|Object .*free|Redzone overwritten|stack-out|use-after-free' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L")
  echo "uaf2-$r: boot=$boot uaf_sig=$uaf killinit=$ki $(date +%H:%M:%S)"
done
echo "=== first real kernel-fault/poison report (skip cmdline echoes) ==="
grep -haE 'unable to handle|page_poison|Bad page state|Object already|Redzone|general protection|BUG: unable|RIP: 0010' $D/uaf2-*.log 2>/dev/null | grep -av 'Command line\|command line' | sed -E 's/^.*kernel: //' | head -25
