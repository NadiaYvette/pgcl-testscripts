#!/bin/bash
# rr-revdebug.sh <rrfile> <gdbscript> — bundle a frozen replay + a batch gdb
# reverse-debug session into one (background-able) run.  Guest console goes to a
# pollable file (rr-console.log) so replay progress can be watched while gdb is
# blocked in `continue`.  Internal timeout caps the (slow) replay/reverse so the
# high-value static dump + backtrace (printed before the reverse loop) are not
# lost to a hang.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
O=$P/kernel-rpm-build/pgcl4-debug
BIN="${1:?usage: rr-revdebug.sh <rrfile> <gdbscript>}"; GDBF="${2:?gdbscript}"
TMO="${RRTMO:-2400}"
pkill -9 -f 'qemu-system-x86_64.*rr=replay' 2>/dev/null; sleep 1
rm -f "$D"/rrg-btrfs.qcow2 "$D"/rrg-swap.qcow2 "$D"/rr-console.log
qemu-img create -f qcow2 -b "$D/btrfs.img"            -F raw "$D"/rrg-btrfs.qcow2 >/dev/null
qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/rrg-swap.qcow2 >/dev/null
taskset -c 8-11 "$QB/qemu-system-x86_64" -icount shift=auto,sleep=off,rr=replay,rrfile="$BIN" \
  -accel tcg -cpu max,la57=off -smp 1 -m 2G -kernel "$D/bzImage-vandangle" \
  -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
  -drive file="$D"/rrg-btrfs.qcow2,if=none,id=disk0 \
  -drive driver=blkreplay,if=none,image=disk0,id=disk0-rr -device virtio-blk-pci,drive=disk0-rr \
  -drive file="$D"/rrg-swap.qcow2,if=none,id=disk1 \
  -drive driver=blkreplay,if=none,image=disk1,id=disk1-rr -device virtio-blk-pci,drive=disk1-rr \
  -serial file:"$D"/rr-console.log -display none -monitor none -no-reboot -gdb tcp::1234 -S &
QPID=$!
for t in $(seq 1 20); do ss -ltn 2>/dev/null | grep -q ':1234' && break; sleep 1; done
echo "qemu pid=$QPID, gdbstub ready; gdb starting (watch rr-console.log for replay progress)"
timeout "$TMO" gdb -nx -batch -x "$GDBF" "$O/vmlinux" 2>&1
echo "gdb finished rc=$?  (last guest console: $(grep -aoE '^\[[ 0-9.]+\]' "$D"/rr-console.log 2>/dev/null | tail -1))"
kill -9 $QPID 2>/dev/null; true
