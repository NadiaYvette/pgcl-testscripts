#!/bin/bash
# run-rr.sh BZIMAGE LOG [TIMEOUT] [SMP] — boot the pgcl4-debug testbed isolated in
# pgcl.slice on cores 16-19.  vda=rootfs.ext4 vdb=swap.raw vdc=btrfs.img.
set -u
D=/home/nyc/src/pgcl
BZ="${1:?bzImage}"; LOG="${2:?log}"; T="${3:-240}"; SMP="${4:-8}"
bash "$D/rmap-ab/iso" timeout "$T" qemu-system-x86_64 \
  -enable-kvm -cpu host -smp "$SMP" -m 3G \
  -kernel "$BZ" \
  -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0" \
  -drive file="$D/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
  -drive file="$D/pgcl4-testbed/swap.raw",format=raw,if=virtio \
  -drive file="$D/rmap-ab/btrfs.img",format=raw,if=virtio \
  -nographic -no-reboot > "$LOG" 2>&1
echo "QEMU-EXIT rc=$? $(date +%H:%M:%S)"
