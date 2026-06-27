#!/bin/bash
# rr-gdb-launch.sh <rrfile> [port] — frozen replay under gdbstub, sleep=off so the
# replay runs at full emulation speed (no real-time throttle; still deterministic)
# and the whole reach-WARN + reverse-debug fits in one gdb session.  taskset to
# idle cores so single-threaded icount isn't starved.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
BIN="${1:?usage: rr-gdb-launch.sh <rrfile> [port]}"; PORT="${2:-1234}"
rm -f "$D"/rrg-btrfs.qcow2 "$D"/rrg-swap.qcow2
qemu-img create -f qcow2 -b "$D/btrfs.img"            -F raw "$D"/rrg-btrfs.qcow2 >/dev/null
qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/rrg-swap.qcow2 >/dev/null
exec taskset -c 8-11 "$QB/qemu-system-x86_64" \
  -icount shift=auto,sleep=off,rr=replay,rrfile="$BIN" \
  -accel tcg -cpu max,la57=off -smp 1 -m 2G -kernel "$D/bzImage-vandangle" \
  -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
  -drive file="$D"/rrg-btrfs.qcow2,if=none,id=disk0 \
  -drive driver=blkreplay,if=none,image=disk0,id=disk0-rr -device virtio-blk-pci,drive=disk0-rr \
  -drive file="$D"/rrg-swap.qcow2,if=none,id=disk1 \
  -drive driver=blkreplay,if=none,image=disk1,id=disk1-rr -device virtio-blk-pci,drive=disk1-rr \
  -nographic -no-reboot -gdb tcp::"$PORT" -S
