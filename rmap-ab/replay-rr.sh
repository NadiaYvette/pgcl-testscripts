#!/bin/bash
# replay-rr.sh <rrfile> [gdbport] — replay a recorded #143 run under a frozen
# gdbstub for reverse-debugging.  Fresh clean overlays over the read-only base
# (must match the record's starting state — same base, empty overlay, no
# rrsnapshot).  Connect with:  gdb pgcl4-debug/vmlinux  -ex 'target remote :PORT'
# then reverse-continue / reverse-stepi / watch work (QEMU advertises
# ReverseStep+/ReverseContinue+).  -S freezes at vCPU start so gdb drives.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
BIN="${1:?usage: replay-rr.sh <rrfile> [port]}"; PORT="${2:-1234}"
rm -f "$D"/rrg-btrfs.qcow2 "$D"/rrg-swap.qcow2
qemu-img create -f qcow2 -b "$D/btrfs.img" -F raw "$D"/rrg-btrfs.qcow2 >/dev/null
qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/rrg-swap.qcow2 >/dev/null
exec "$QB/qemu-system-x86_64" -icount shift=auto,rr=replay,rrfile="$BIN" \
  -accel tcg -cpu max,la57=off -smp 1 -m 2G -kernel "$D/bzImage-vandangle" \
  -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
  -drive file="$D"/rrg-btrfs.qcow2,if=none,id=disk0 \
  -drive driver=blkreplay,if=none,image=disk0,id=disk0-rr -device virtio-blk-pci,drive=disk0-rr \
  -drive file="$D"/rrg-swap.qcow2,if=none,id=disk1 \
  -drive driver=blkreplay,if=none,image=disk1,id=disk1-rr -device virtio-blk-pci,drive=disk1-rr \
  -nographic -no-reboot -gdb tcp::"$PORT" -S
