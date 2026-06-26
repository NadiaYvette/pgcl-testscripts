#!/bin/bash
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
taskset -c 16-19 qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 2G \
  -kernel "$D/bzImage-vanswap" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
  -append "console=ttyS0 nokaslr ignore_loglevel rr_nofork rr_nocow" \
  -drive file="$D/btrfs.img",format=raw,if=virtio \
  -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
  -nographic -no-reboot -s > "$D/gdbhang.log" 2>&1 &
QPID=$!
sleep 35   # boot (~5s) + RRABL start + hang (~5-10s); attach to the frozen state
gdb -batch -nx "$P/kernel-rpm-build/pgcl4/vmlinux" \
  -ex 'set pagination off' \
  -ex 'target remote :1234' \
  -ex 'info threads' \
  -ex 'thread apply all bt' \
  -ex 'detach' -ex 'quit' 2>&1
kill -9 $QPID 2>/dev/null
