#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; Q=/home/nyc/src/qemu/build/qemu-system-x86_64
echo "=== rebuild qemu (incremental, over-flush probe) $(date +%H:%M:%S) ==="
taskset -c 12-19 ninja -C /home/nyc/src/qemu/build qemu-system-x86_64 > "$P/qemu-rebuild.log" 2>&1
rc=$?; echo "rebuild rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { tail -20 "$P/qemu-rebuild.log"; exit 1; }
runset() {  # $1=tag ; $2.. = env assignment(s) (none => control)
  local tag=$1; shift
  for r in 1 2 3; do
    L=$D/of-$tag-$r.log
    bash "$D/iso" timeout 600 env "$@" "$Q" -accel tcg,thread=multi -cpu max -smp 8 -m 2G \
      -kernel "$D/bzImage-vanfix" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
      -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
      -drive file="$D/btrfs.img",format=raw,if=virtio \
      -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
      -nographic -no-reboot > "$L" 2>&1
    ki=$(grep -ac 'Attempted to kill init' "$L"); boot=$(grep -ac 'INIT: ablation' "$L"); ran=$(grep -ac 'RRABL start' "$L")
    echo "$tag-$r: boot=$boot ran=$ran killinit=$ki => $([ "$ki" -gt 0 ] && echo CRASH || echo clean) $(date +%H:%M:%S)"
  done
}
echo "=== CONTROL (over-flush OFF) -- expect CRASH ==="; runset control
echo "=== OVER-FLUSH (PGCL_OVERFLUSH=1) -- clean here == TLB-flush gap ==="; runset overflush PGCL_OVERFLUSH=1
echo "=== done $(date +%H:%M:%S) ==="
