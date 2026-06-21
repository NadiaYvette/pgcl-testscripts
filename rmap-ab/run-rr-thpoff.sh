#!/bin/bash
# THP=never instrumented boot: does the order-0 rmap underflow survive with
# transparent hugepages off?  vda=rootfs.ext4 vdb=swap vdc=btrfs scratch.
set -u
D=/home/nyc/src/pgcl
timeout 220 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 3G \
  -kernel "$D/rmap-ab/bzImage-instr" \
  -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0 transparent_hugepage=never" \
  -drive file="$D/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
  -drive file="$D/pgcl4-testbed/swap.raw",format=raw,if=virtio \
  -drive file="$D/rmap-ab/btrfs.img",format=raw,if=virtio \
  -nographic -no-reboot > "$D/rmap-ab/rr-thpoff.log" 2>&1
echo "QEMU-EXIT rc=$?"
